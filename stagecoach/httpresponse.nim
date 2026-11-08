import std/strutils
import stagelane/core
import stagelane/transform
import httpservercore
import socketio
from posix import MSG_NOSIGNAL
import httpcore

const lastSendFlags = MSG_NOSIGNAL + MSG_DONTWAIT
const moreSendFlags = MSG_NOSIGNAL + MSG_DONTWAIT + MSG_MORE

const
  version = "HTTP/1.1 "
  http200nocontent = "HTTP/1.1 200 OK\c\LContent-Length: 0\c\L\c\L"
  http204string = "HTTP/1.1 204 No Content\c\L\c\L"
  keepAliveHeader = "Connection: keep-alive"
  shortdivider = "\c\L"
  longdivider = "\c\L\c\L"
  contentlen = "Content-Length: "
  zerocontent = "Content-Length: 0\c\L"

proc writeToSocket*(ctx: HttpContext, text: string, flags: cint): SocketState {.flow.} =
  if text.len == 0:
    return Complete
  ctx.sendSome(unsafeAddr text[0], text.len, flags)

proc advertiseKeepAlive(ctx: HttpContext): bool {.inline.} =
  ## HTTP/1.0 clients only keep the connection if the reply says so.
  ctx.http10 and ctx.keepAlive

proc reply*(ctx: HttpContext, code: HttpCode): SocketState {.flow.} =
  if ctx.advertiseKeepAlive:
    return ctx.writeToSocket(version & $code & "\c\L" & keepAliveHeader & shortdivider &
      zerocontent & shortdivider, lastSendFlags)
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
  if ctx.advertiseKeepAlive:
    buf.add keepAliveHeader
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
  ## HTTP/1.0 has no chunked encoding: the body is streamed raw and delimited
  ## by closing the connection.
  var buf = version & $code & "\c\L"
  for h in headers:
    buf.add(h & "\c\L")
  if ctx.http10:
    ctx.keepAlive = false
    buf.add("Connection: close\c\L\c\L")
  else:
    buf.add("Transfer-Encoding: chunked\c\L\c\L")
  ctx.writeToSocket(buf, moreSendFlags) != Fail

proc replyContinueChunked*(ctx: HttpContext, chunk: string): bool {.flow.} =
  if chunk.len == 0:      # a zero-length chunk would terminate the stream
    return true
  if ctx.http10:
    return ctx.writeToSocket(chunk, moreSendFlags) != Fail
  var buf = chunk.len.toHex.strip(trailing = false, chars = {'0'})
  buf.add shortdivider
  buf.add chunk
  buf.add shortdivider
  ctx.writeToSocket(buf, moreSendFlags) != Fail

proc replyFinishChunked*(ctx: HttpContext): bool {.flow.} =
  if ctx.http10:
    return true            # the close ends the body
  ctx.writeToSocket("0" & longdivider, lastSendFlags) != Fail

proc closeSocket*(ctx: HttpContext, cause = CloseCalled, msg = "") {.deprecated: "use closeHttpSocket".} =
  closeHttpSocket(ctx, cause, msg)
