import std/[strutils, os]
import stagelane/core
import stagelane/transform
import httpservercore
from coachserver import SocketCloseCause, isShuttingDown
from httprequest import closeHttpSocket, waitSocketWritableImpl
from posix import send, MSG_NOSIGNAL, EAGAIN, EWOULDBLOCK, EINTR
import httpcore

const lastSendFlags = MSG_NOSIGNAL + MSG_DONTWAIT
const moreSendFlags = MSG_NOSIGNAL + MSG_DONTWAIT + MSG_MORE

const
  version = "HTTP/1.1 "
  http200nocontent = "HTTP/1.1 200 OK\c\LContent-Length: 0\c\L\c\L"
  http204string = "HTTP/1.1 204 No Content\c\L\c\L"
  shortdivider = "\c\L"
  longdivider = "\c\L\c\L"
  contentlen = "Content-Length: "
  zerocontent = "Content-Length: 0\c\L"

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
        ctx.waitSocketWritableImpl()
        continue
      closeHttpSocket(ctx, NetErrored, osErrorMsg(e))
      return Fail
    ctx.waitSocketWritableImpl()   # send() returned 0: treat as would-block
  Complete

proc writeToSocket*(ctx: HttpContext, text: string, flags: cint): SocketState {.flow.} =
  if text.len == 0:
    return Complete
  ctx.sendSome(unsafeAddr text[0], text.len, flags)

proc reply*(ctx: HttpContext, code: HttpCode): SocketState {.flow.} =
  if code == Http200:
    return ctx.writeToSocket(http200nocontent, lastSendFlags)
  if code == Http204:
    return ctx.writeToSocket(http204string, lastSendFlags)
  ctx.writeToSocket(version & $code & "\c\L" & zerocontent & shortdivider, lastSendFlags)

proc reply*(ctx: HttpContext, code: HttpCode, body: string, extraHeaders: openArray[string] = []) {.flow.} =
  ## Builds the response into the connection's reusable buffer and sends it in one write.
  var buf = move ctx.sendBuf
  buf.setLen(0)
  buf.add version
  buf.add $code
  buf.add shortdivider
  for h in extraHeaders:
    buf.add h
    buf.add shortdivider
  buf.add contentlen
  buf.addInt body.len
  buf.add longdivider
  buf.add body
  discard ctx.writeToSocket(buf, lastSendFlags)
  if buf.len < 65536:           # don't pin big responses to the connection
    ctx.sendBuf = move buf

template reply*(ctx: HttpContext, body: string) =
  ctx.reply(Http200, body)

template replyHeaders*(ctx: HttpContext, code: HttpCode, headers: openArray[string]) =
  ctx.reply(code, "", headers)

proc replyStartChunked*(ctx: HttpContext, code: HttpCode = Http200, headers: openArray[string] = []): bool {.flow.} =
  var buf = version & $code & "\c\L"
  for h in headers:
    buf.add(h & "\c\L")
  buf.add("Transfer-Encoding: chunked\c\L\c\L")
  ctx.writeToSocket(buf, moreSendFlags) != Fail

proc replyContinueChunked*(ctx: HttpContext, chunk: string): bool {.flow.} =
  if chunk.len == 0:      # a zero-length chunk would terminate the stream
    return true
  var buf = chunk.len.toHex.strip(trailing = false, chars = {'0'})
  buf.add shortdivider
  buf.add chunk
  buf.add shortdivider
  ctx.writeToSocket(buf, moreSendFlags) != Fail

proc replyFinishChunked*(ctx: HttpContext): bool {.flow.} =
  ctx.writeToSocket("0" & longdivider, lastSendFlags) != Fail

proc closeSocket*(ctx: HttpContext, cause = CloseCalled, msg = "") =
  closeHttpSocket(ctx, cause, msg)
