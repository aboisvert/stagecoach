import std/[strutils, strformat, os]
import stagelane/sched
import stagelane/core
import stagelane/transform
import httpservercore
from coachserver import SocketCloseCause, shuttingdown
from httprequest import closeHttpSocket
from posix import send, MSG_NOSIGNAL, EAGAIN, EWOULDBLOCK, EPIPE, ECONNRESET
import httpcore

const lastSendFlags = MSG_NOSIGNAL + MSG_DONTWAIT
const moreSendFlags = MSG_NOSIGNAL + MSG_DONTWAIT + MSG_MORE

let
  version = "HTTP/1.1 "
  http200nocontent = "HTTP/1.1 200 OK\c\LContent-Length: 0\c\L\c\L"
  http200nocontentlen = 38
  http204string = "HTTP/1.1 204 No Content\c\L\c\L"
  http204stringlen = 27
  shortdivider = "\c\L"
  longdivider = "\c\L\c\L"
  contentlen = "Content-Length: "
  zerocontent = "Content-Length: 0\c\L"

proc classifySend(ret: int, ctx: HttpContext): SocketState =
  if unlikely(shuttingdown):
    return Fail
  if likely(ret > 0):
    return Progress
  let lastError = osLastError()
  if lastError.int in [EAGAIN.int, EWOULDBLOCK.int]:
    return TryAgain
  closeHttpSocket(ctx, NetErrored, osErrorMsg(lastError))
  Fail

proc waitSocketWritable*(ctx: HttpContext) {.flow.} =
  let server = ctx.server
  if server.sockettimeoutms <= 0:
    waitWritable(int(ctx.socket))
    return
  let self = curTask()
  let timer = addTimer(server.sockettimeoutms, proc () = cancel(self))
  try:
    waitWritable(int(ctx.socket))
  finally:
    cancel(timer)

proc sendSome*(ctx: HttpContext, data: pointer, length: int, flags: cint): SocketState {.flow.} =
  if length == 0:
    return Complete
  var sent = 0
  while sent < length:
    let ret = send(ctx.socket, cast[pointer](cast[int](data) + sent), (length - sent).cint, flags)
    if ret > 0:
      sent += ret
      continue
    let state = classifySend(ret, ctx)
    if state == TryAgain:
      ctx.waitSocketWritable()
    else:
      return state
  Complete

proc writeToSocket*(ctx: HttpContext, text: string, length: int, flags: cint): SocketState {.flow.} =
  if length == 0:
    return Complete
  result = ctx.sendSome(unsafeAddr text[0], length, flags)
  if result == Complete:
    ctx.server.log(lvlDebug, "writeToSocket " & $ctx.socket & ": " & text[0 ..< length])

proc replyFinish*(ctx: HttpContext): SocketState {.flow.} =
  ctx.sendSome(nil, 0, lastSendFlags)

proc reply*(ctx: HttpContext, code: HttpCode): SocketState {.flow.} =
  if code == Http200:
    return ctx.writeToSocket(http200nocontent, http200nocontentlen, lastSendFlags)
  if code == Http204:
    return ctx.writeToSocket(http204string, http204stringlen, lastSendFlags)
  var head = version & $code & "\c\L" & zerocontent & shortdivider
  ctx.writeToSocket(head, head.len, lastSendFlags)

proc reply*(ctx: HttpContext, code: HttpCode, body: string, extraHeaders: openArray[string] = []) {.flow.} =
  let hdrs = extraHeaders.join("\c\L")
  var buf = version & $code & "\c\L"
  if hdrs.len > 0:
    buf.add(hdrs & "\c\L")
  buf.add(contentlen & $body.len & longdivider)
  buf.add(body)
  discard ctx.writeToSocket(buf, buf.len, lastSendFlags)
  ctx.server.log(lvlAll, "reply ok")

template reply*(ctx: HttpContext, body: string) =
  ctx.reply(Http200, body)

template replyHeaders*(ctx: HttpContext, code: HttpCode, headers: openArray[string]) =
  ctx.reply(code, "", headers)

proc replyStartChunked*(ctx: HttpContext, code: HttpCode = Http200, headers: openArray[string] = []): bool {.flow.} =
  var buf = version & $code & "\c\L"
  for h in headers:
    buf.add(h & "\c\L")
  buf.add("Transfer-Encoding: chunked\c\L\c\L")
  ctx.writeToSocket(buf, buf.len, moreSendFlags) != Fail

proc replyContinueChunked*(ctx: HttpContext, chunk: string): bool {.flow.} =
  let delimiter = fmt"{chunk.len:X}" & shortdivider
  if ctx.writeToSocket(delimiter, delimiter.len, moreSendFlags) == Fail:
    return false
  if ctx.writeToSocket(chunk, chunk.len, moreSendFlags) == Fail:
    return false
  ctx.writeToSocket(shortdivider, shortdivider.len, moreSendFlags) != Fail

proc replyFinishChunked*(ctx: HttpContext): bool {.flow.} =
  let delimiter = "0" & longdivider
  if ctx.writeToSocket(delimiter, delimiter.len, lastSendFlags) == Fail:
    return false
  ctx.replyFinish() != Fail

proc closeSocket*(ctx: HttpContext, cause = CloseCalled, msg = "") =
  closeHttpSocket(ctx, cause, msg)
