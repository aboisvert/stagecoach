## Single home for non-blocking socket IO: one recv retry loop, one send
## retry loop, one errno -> close-cause map, and the per-op socket-timeout
## wrapper. `httprequest` and `httpresponse` drive this module; they keep no
## retry logic of their own.
##
## Epoll waits follow a would-block result. Newer stagelane versions register
## accepted sockets for persistent epoll monitoring and consume their own
## epoll latches when the wait is made.

import std/[os, posix]
import stagelane/core
import stagelane/sched
import stagelane/transform
when defined(linux):
  import stagelane/uring
import httpservercore
from coachserver import SocketCloseCause, isShuttingDown
const flushSendFlags = httpservercore.MSG_NOSIGNAL or MSG_DONTWAIT

when defined(linux) and defined(stagecoachRingTest):
  var ringTestReads*, ringTestWrites* {.threadvar.}: int

proc classifyRecv*(ret: int, cause: var SocketCloseCause, msg: var string): SocketState =
  ## Pure classification of a `recv` result; the caller decides whether to close.
  if unlikely(isShuttingDown()):
    cause = CloseCalled
    msg = "shutting down"
    return Fail
  if likely(ret > 0):
    return Progress
  if unlikely(ret == 0):
    cause = ClosedbyClient
    msg = "peer closed"
    return Fail
  let lastError = osLastError().int
  if lastError in [EAGAIN.int, EWOULDBLOCK.int, EINTR.int]:
    return TryAgain
  cause = NetErrored
  if lastError == posix.EBADF.int: cause = AlreadyClosed
  elif lastError == posix.EFAULT.int: cause = EFault
  elif lastError == posix.EPIPE.int: cause = ConnectionLost
  elif lastError == posix.ECONNRESET.int: cause = ClosedbyClient
  msg = osErrorMsg(OSErrorCode(lastError))
  Fail

proc closeImmediately(ctx: HttpContext, cause: SocketCloseCause, msg: string) =
  let fd = ctx.socket
  if fd == INVALID_SOCKET:
    return
  ctx.sendBuf.setLen(0)
  ctx.requestlen = 0
  ctx.carryLen = 0
  ctx.carryStart = 0
  ctx.socket = INVALID_SOCKET
  when declared(forgetFd):
    forgetFd(int(fd))
  closeSocket(ctx.server, fd, cause, msg)

template withSocketTimeout(ctx: HttpContext, waitCall: untyped) =
  ## Bound one parked wait by `sockettimeoutms`: a lazily-armed timer cancels
  ## the CURRENT task `ms` after arming, which interrupts the parked
  ## `waitCall`; the `finally` disarms it when the wait returns first.
  ## An expired timer leaves the socket untouched - the caller classifies.
  let ms = ctx.server.sockettimeoutms
  if ms <= 0:
    waitCall
  else:
    let self = curTask()
    let timer = addTimer(ms, proc () = cancel(self))
    try:
      waitCall
    finally:
      cancel(timer)

template parkRead(ctx: HttpContext) =
  waitReadable(int(ctx.socket))

template parkWrite(ctx: HttpContext) =
  waitWritable(int(ctx.socket))

template withReadTimeout(ctx: HttpContext, waitCall: untyped) =
  let idleWait = ctx.requestlen == 0 and not ctx.bodyClockSet
  if idleWait and ctx.server.idleTimeoutms > 0:
    let ms = ctx.server.idleTimeoutms
    var timer = addTimer(ms, proc () {.closure.} =
      {.cast(gcsafe).}:
        ctx.idleExpired = true
        if ctx.socket != INVALID_SOCKET:
          discard shutdown(ctx.socket, SHUT_RDWR))
    try:
      waitCall
    finally:
      cancel(timer)
  else:
    ctx.withSocketTimeout(waitCall)

proc waitSocketReadable*(ctx: HttpContext) {.flow.} =
  ctx.withReadTimeout(ctx.parkRead())

proc waitSocketWritable*(ctx: HttpContext) {.flow.} =
  ctx.withSocketTimeout(ctx.parkWrite())

proc sendSome*(ctx: HttpContext, data: pointer, length: int, flags: cint): SocketState {.flow.} =
  ## Sends exactly `length` bytes (waiting for writability as needed).
  ## Closes the socket and returns Fail on error.
  var sent = 0
  while sent < length:
    let buf = cast[pointer](cast[int](data) + sent)
    var ret: int
    var e: OSErrorCode
    when defined(linux):
      if ctx.ringIo:
        when defined(stagecoachRingTest): inc ringTestWrites
        ctx.withSocketTimeout:
          ret = ringSend(int(ctx.socket), buf, length - sent)
        if ret < 0: e = OSErrorCode(-ret)
      else:
        ret = send(ctx.socket, buf, (length - sent).cint, flags)
        if ret < 0: e = osLastError()
    else:
      ret = send(ctx.socket, buf, (length - sent).cint, flags)
      if ret < 0: e = osLastError()
    if ret > 0:
      sent += ret
      continue
    if ret < 0:
      if e.int == EINTR.int:
        continue
      if e.int in [EAGAIN.int, EWOULDBLOCK.int]:
        ctx.waitSocketWritable()
        continue
      closeImmediately(ctx, NetErrored, osErrorMsg(e))
      return Fail
    ctx.waitSocketWritable()   # send() returned 0: treat as would-block
  Complete

proc flushSendBuf*(ctx: HttpContext): SocketState {.flow.} =
  ## Never park on the socket while a held reply is still in sendBuf.
  if ctx.sendBuf.len == 0:
    return Complete
  var buf = move ctx.sendBuf
  result = ctx.sendSome(unsafeAddr buf[0], buf.len, flushSendFlags)
  # hand small buffers back for the next reply, drop big ones so pooled
  # contexts do not retain multi-hundred-KB response buffers (both are
  # re-grown on demand)
  if result != Fail and buf.len < 65536:
    ctx.sendBuf = buf
    ctx.sendBuf.setLen(0)

proc recvSome*(ctx: HttpContext, buf: pointer, n: int): int {.flow.} =
  ## Reads up to `n` bytes, waiting while the socket would block.
  ## Returns 0 on EOF and < 0 on a real error.
  if ctx.socket == INVALID_SOCKET:
    return -1
  if ctx.holdWrites and ctx.sendBuf.len > 0:
    if ctx.flushSendBuf() == Fail:
      return -1
  when defined(linux):
    if ctx.ringIo:
      while true:
        var r: int
        when defined(stagecoachRingTest): inc ringTestReads
        ctx.withReadTimeout:
          r = ringRecv(int(ctx.socket), buf, n)
        if r == -EINTR.int: continue
        if r == -EAGAIN.int or r == -EWOULDBLOCK.int:
          ctx.waitSocketReadable()
          continue
        if r < 0:
          posix.errno = (-r).cint
          return -1
        return r
  while true:
    let r = recv(ctx.socket, buf, n.cint, MSG_DONTWAIT)
    if r >= 0:
      return r
    let e = osLastError().int
    if e == EINTR.int:
      continue
    if e in [EAGAIN.int, EWOULDBLOCK.int]:
      ctx.waitSocketReadable()
    else:
      return r

proc closeHttpSocket*(ctx: HttpContext, cause = CloseCalled, msg = "") {.flow.} =
  let fd = ctx.socket
  if fd == INVALID_SOCKET:
    return
  # Held replies must leave before the fd is closed (/close and similar), but
  # only for a benign close: a dead or slow peer must not park the closer.
  if ctx.sendBuf.len > 0:
    if cause == CloseCalled:
      let held = ctx.holdWrites
      ctx.holdWrites = false
      discard ctx.flushSendBuf()
      ctx.holdWrites = held
      # A failed flush closes the socket re-entrantly; do not close it twice.
      if ctx.socket != fd:
        return
  # Pipelined bytes must not be parsed after the handler closed the connection.
  ctx.closeImmediately(cause, msg)

proc checkRecv*(ctx: HttpContext, ret: int): SocketState {.flow.} =
  ## `classifyRecv`, closing the socket on failure.
  # A zero-byte read after the idle timer shut the socket down (see
  # waitSocketReadable) is the idle timeout, not a normal peer close.
  if ret == 0 and ctx.idleExpired:
    closeHttpSocket(ctx, TimedOut, "idle")
    return Fail
  var cause = CloseCalled
  var msg = ""
  result = classifyRecv(ret, cause, msg)
  if result == Fail:
    closeHttpSocket(ctx, cause, msg)
