## Single home for non-blocking socket IO: one recv retry loop, one send
## retry loop, one errno -> close-cause map, and the per-op socket-timeout
## wrapper. `httprequest` and `httpresponse` drive this module; they keep no
## retry logic of their own.

import std/[os, posix]
import stagelane/core
import stagelane/sched
import stagelane/transform
import httpservercore
from coachserver import SocketCloseCause, isShuttingDown

proc closeHttpSocket*(ctx: HttpContext, cause = CloseCalled, msg = "") =
  let fd = ctx.socket
  if fd == INVALID_SOCKET:
    return
  ctx.socket = INVALID_SOCKET
  closeSocket(ctx.server, fd, cause, msg)

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

proc waitSocketReadable*(ctx: HttpContext) {.flow.} =
  ctx.withSocketTimeout(waitReadable(int(ctx.socket)))

proc waitSocketWritable*(ctx: HttpContext) {.flow.} =
  ctx.withSocketTimeout(waitWritable(int(ctx.socket)))

proc recvSome*(ctx: HttpContext, buf: pointer, n: int): int {.flow.} =
  ## Reads up to `n` bytes, waiting while the socket would block.
  ## Returns 0 on EOF and < 0 on a real error.
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

proc sendSome*(ctx: HttpContext, data: pointer, length: int, flags: cint): SocketState {.flow.} =
  ## Sends exactly `length` bytes (waiting for writability as needed).
  ## Closes the socket and returns Fail on error.
  var sent = 0
  while sent < length:
    if isShuttingDown():
      return Fail
    let ret = send(ctx.socket, cast[pointer](cast[int](data) + sent), (length - sent).cint, flags)
    if ret > 0:
      sent += ret
      continue
    if ret < 0:
      let e = osLastError()
      if e.int == EINTR.int:
        continue
      if e.int in [EAGAIN.int, EWOULDBLOCK.int]:
        ctx.waitSocketWritable()
        continue
      closeHttpSocket(ctx, NetErrored, osErrorMsg(e))
      return Fail
    ctx.waitSocketWritable()   # send() returned 0: treat as would-block
  Complete
