## Single home for non-blocking socket IO: one recv retry loop, one send
## retry loop, one errno -> close-cause map, and the per-op socket-timeout
## wrapper. `httprequest` and `httpresponse` drive this module; they keep no
## retry logic of their own.

import std/[os, posix]
import stagelane/core
import stagelane/sched
import stagelane/transform
import httpservercore
from coachserver import SocketCloseCause, isShuttingDown, logClose
when defined(linux):
  from stagelane/sched import PollFd, pioOpen, pioClose, pioWaitRead, pioWaitWrite
from posix import MSG_NOSIGNAL

const flushSendFlags = MSG_NOSIGNAL + MSG_DONTWAIT

proc closeHttpSocket*(ctx: HttpContext, cause = CloseCalled, msg = "")

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

proc checkRecv*(ctx: HttpContext, ret: int): SocketState =
  ## `classifyRecv`, closing the socket on failure.
  if ret == 0 and ctx.idleExpired:
    closeHttpSocket(ctx, TimedOut, "idle")
    return Fail
  var cause = CloseCalled
  var msg = ""
  result = classifyRecv(ret, cause, msg)
  if result == Fail:
    closeHttpSocket(ctx, cause, msg)

template withSocketTimeout(ctx: HttpContext, waitCall: untyped) =
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
  when defined(linux):
    if ctx.pf != nil:
      pioWaitRead(cast[PollFd](ctx.pf))
    else:
      waitReadable(int(ctx.socket))
  else:
    waitReadable(int(ctx.socket))

template parkWrite(ctx: HttpContext) =
  when defined(linux):
    if ctx.pf != nil:
      pioWaitWrite(cast[PollFd](ctx.pf))
    else:
      waitWritable(int(ctx.socket))
  else:
    waitWritable(int(ctx.socket))

proc waitSocketReadable*(ctx: HttpContext) {.flow.} =
  let idleWait = ctx.requestlen == 0 and not ctx.bodyClockSet
  if idleWait and ctx.server.idleTimeoutms > 0:
    let ms = ctx.server.idleTimeoutms
    var timer = addTimer(ms, proc () {.closure.} =
      {.cast(gcsafe).}:
        ctx.idleExpired = true
        if ctx.socket != INVALID_SOCKET:
          discard shutdown(ctx.socket, SHUT_RDWR))
    try:
      ctx.parkRead()
    finally:
      cancel(timer)
  else:
    ctx.withSocketTimeout(ctx.parkRead())

proc waitSocketWritable*(ctx: HttpContext) {.flow.} =
  ctx.withSocketTimeout(ctx.parkWrite())

proc sendSome*(ctx: HttpContext, data: pointer, length: int, flags: cint): SocketState {.flow.} =
  ## Sends exactly `length` bytes (waiting for writability as needed).
  ## Closes the socket and returns Fail on error.
  var sent = 0
  while sent < length:
    let ret = send(ctx.socket, cast[pointer](cast[int](data) + sent), (length - sent).cint, flags)
    if ret > 0:
      sent += ret
      when defined(linux):
        if ctx.pf != nil and sent < length:
          cast[PollFd](ctx.pf).wrReady = false
      continue
    if ret < 0:
      let e = osLastError()
      if e.int == EINTR.int:
        continue
      if e.int in [EAGAIN.int, EWOULDBLOCK.int]:
        when defined(linux):
          if ctx.pf != nil: cast[PollFd](ctx.pf).wrReady = false
        ctx.waitSocketWritable()
        continue
      closeHttpSocket(ctx, NetErrored, osErrorMsg(e))
      return Fail
    ctx.waitSocketWritable()   # send() returned 0: treat as would-block
  Complete

proc flushSendBuf*(ctx: HttpContext): SocketState {.flow.} =
  ## Never park on the socket while a held reply is still in sendBuf.
  if ctx.sendBuf.len == 0:
    return Complete
  var buf = move ctx.sendBuf
  result = ctx.sendSome(unsafeAddr buf[0], buf.len, flushSendFlags)
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
  while true:
    let r = recv(ctx.socket, buf, n.cint, MSG_DONTWAIT)
    if r >= 0:
      when defined(linux):
        if ctx.pf != nil and (r < n or r == 0):
          cast[PollFd](ctx.pf).rdReady = false
      return r
    let e = osLastError().int
    if e == EINTR.int:
      continue
    if e in [EAGAIN.int, EWOULDBLOCK.int]:
      when defined(linux):
        if ctx.pf != nil: cast[PollFd](ctx.pf).rdReady = false
      ctx.waitSocketReadable()
    else:
      return r

proc closeHttpSocket*(ctx: HttpContext, cause = CloseCalled, msg = "") =
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
    ctx.sendBuf.setLen(0)
  # Pipelined bytes must not be parsed after the handler closed the connection.
  ctx.requestlen = 0
  ctx.carryLen = 0
  ctx.carryStart = 0
  ctx.socket = INVALID_SOCKET
  when defined(linux):
    if ctx.pf != nil:
      let p = cast[PollFd](ctx.pf)
      ctx.pf = nil
      logClose(ctx.server, fd, cause, msg)
      if not isNil(ctx.server.onCloseSocketCallback):
        ctx.server.onCloseSocketCallback(ctx.server, fd, cause, msg)
      pioClose(p)
      return
  closeSocket(ctx.server, fd, cause, msg)
