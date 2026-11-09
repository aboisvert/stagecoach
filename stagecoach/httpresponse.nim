import std/[strutils, posix, os, times]
import stagelane/core
import stagelane/transform
import httpservercore
import socketio
import httpcore
from coachserver import SocketCloseCause, isShuttingDown
when defined(linux):
  from stagelane/sched import PollFd

const lastSendFlags = httpservercore.MSG_NOSIGNAL or MSG_DONTWAIT
const moreSendFlags = lastSendFlags or MSG_MORE

const
  version = "HTTP/1.1 "
  # canned replies for the hot paths: no Date (sendDate is opt-in) and no
  # keep-alive advertising - for HTTP/1.1 persistence is implicit, and
  # HTTP/1.0 get the explicit Connection: keep-alive line from the general path
  http200nocontent = "HTTP/1.1 200 OK\c\LContent-Length: 0\c\L\c\L"
  http204string = "HTTP/1.1 204 No Content\c\L\c\L"
  keepAliveHeader = "Connection: keep-alive"
  shortdivider = "\c\L"
  longdivider = "\c\L\c\L"
  contentlen = "Content-Length: "
  zerocontent = "Content-Length: 0\c\L"

proc writeToSocket*(ctx: HttpContext, text: string, flags: cint): SocketState {.flow.} =
  ## Despite the name, this sends the WHOLE `text` (sendSome parks until sent)
  ## and returns Fail on any error. Empty text is a Complete no-op.
  if text.len == 0:
    return Complete
  ctx.sendSome(unsafeAddr text[0], text.len, flags)

var dateCacheSec {.threadvar.}: int64
var dateCacheLine {.threadvar.}: string

proc appendDateLine(ctx: HttpContext, buf: var string) =
  ## Per-thread cache refreshed at most once per second; no shared state.
  if not ctx.server.sendDate:
    return
  let sec = getTime().toUnix
  if sec != dateCacheSec or dateCacheLine.len == 0:
    dateCacheSec = sec
    dateCacheLine = "Date: " & fromUnix(sec).utc.format("ddd, dd MMM yyyy HH:mm:ss") & " GMT\c\L"
  buf.add dateCacheLine

proc advertiseKeepAlive(ctx: HttpContext): bool {.inline.} =
  ## HTTP/1.0 clients only keep the connection if the reply says so.
  ctx.http10 and ctx.keepAlive

const lingerDrainMax = 64 * 1024

proc lingeringClose(ctx: HttpContext, cause: SocketCloseCause, msg: string) =
  ## Closing with unread request bytes makes the kernel send RST, which can
  ## destroy the error response in flight. Half-close, discard what has
  ## already arrived (bounded, never parks), then close.
  let fd = ctx.socket
  if fd != INVALID_SOCKET:
    discard shutdown(fd, SHUT_WR)
    var scratch: array[4096, char]
    var drained = 0
    while drained < lingerDrainMax:
      let r = recv(fd, addr scratch[0], scratch.len.cint, MSG_DONTWAIT)
      if r <= 0: break
      drained += r
  closeHttpSocket(ctx, cause, msg)

proc reject*(ctx: HttpContext, code: HttpCode, cause: SocketCloseCause, msg: string) {.flow.} =
  ## Send an error status with `Connection: close`, then close and log `cause`.
  ## Once `responded` is set, another status line would corrupt the stream.
  ## Process shutdown stays a silent close (no status).
  ctx.holdWrites = false
  if ctx.sendBuf.len > 0 and not ctx.responded:
    ctx.sendBuf.setLen(0)
  if ctx.socket == INVALID_SOCKET:
    return
  if isShuttingDown() or not serverIsOpen(ctx.server):
    closeHttpSocket(ctx, cause, msg)
    return
  if ctx.responded:
    closeHttpSocket(ctx, cause, msg)
    return
  let bodyLen = msg.len + 1
  var buf = version
  buf.add $code
  buf.add shortdivider
  appendDateLine(ctx, buf)
  buf.add "Content-Type: text/plain; charset=utf-8"
  buf.add shortdivider
  buf.add "Connection: close"
  buf.add shortdivider
  buf.add contentlen
  buf.addInt bodyLen
  buf.add longdivider
  if not ctx.headOnly:
    buf.add msg
    buf.add '\n'
  ctx.responded = true
  ctx.keepAlive = false
  discard ctx.writeToSocket(buf, lastSendFlags)
  lingeringClose(ctx, cause, msg)

proc replyContinue100*(ctx: HttpContext): bool {.flow.} =
  ## Flush `100 Continue` before the client sends a body not yet buffered.
  if ctx.writeToSocket("HTTP/1.1 100 Continue\c\L\c\L", lastSendFlags) == Fail:
    return false
  true

proc reply*(ctx: HttpContext, code: HttpCode): SocketState {.flow.} =
  ctx.responded = true
  if code == Http200 and not ctx.advertiseKeepAlive and not ctx.server.sendDate:
    ctx.sendBuf.add http200nocontent
  elif code == Http204 and not ctx.advertiseKeepAlive and not ctx.server.sendDate:
    ctx.sendBuf.add http204string
  else:
    ctx.sendBuf.add version
    ctx.sendBuf.add $code
    ctx.sendBuf.add shortdivider
    appendDateLine(ctx, ctx.sendBuf)
    if ctx.advertiseKeepAlive:
      ctx.sendBuf.add keepAliveHeader
      ctx.sendBuf.add shortdivider
    if code == Http204:
      ctx.sendBuf.add shortdivider
    else:
      ctx.sendBuf.add zerocontent
      ctx.sendBuf.add shortdivider
  if ctx.holdWrites:
    return Complete
  ctx.flushSendBuf()

proc reply*(ctx: HttpContext, code: HttpCode, body: string, extraHeaders: openArray[string] = []) {.flow.} =
  ## Builds the response into the connection's reusable buffer and sends it in one write.
  ## Bytes already held are flushed in order with it.
  ctx.responded = true
  template b: untyped = ctx.sendBuf
  b.add version
  b.add $code
  b.add shortdivider
  appendDateLine(ctx, b)
  for h in extraHeaders:
    b.add h
    b.add shortdivider
  if ctx.advertiseKeepAlive:
    b.add keepAliveHeader
    b.add shortdivider
  b.add contentlen
  b.addInt body.len
  b.add longdivider
  # HEAD keeps Content-Length of the representation; body bytes are omitted.
  if not ctx.headOnly:
    b.add body
  if ctx.holdWrites:
    return
  discard ctx.flushSendBuf()

template reply*(ctx: HttpContext, body: string) =
  ctx.reply(Http200, body)

template replyHeaders*(ctx: HttpContext, code: HttpCode, headers: openArray[string]) =
  ctx.reply(code, "", headers)

proc replyStartChunked*(ctx: HttpContext, code: HttpCode = Http200, headers: openArray[string] = []): bool {.flow.} =
  ## HTTP/1.0 has no chunked encoding: the body is streamed raw and delimited
  ## by closing the connection.
  if ctx.holdWrites and ctx.sendBuf.len > 0:
    discard ctx.flushSendBuf()
  ctx.responded = true
  var buf = version & $code & "\c\L"
  appendDateLine(ctx, buf)
  for h in headers:
    buf.add h
    buf.add shortdivider
  if ctx.http10:
    ctx.keepAlive = false
    buf.add("Connection: close\c\L\c\L")
  else:
    buf.add("Transfer-Encoding: chunked\c\L\c\L")
  ctx.writeToSocket(buf, moreSendFlags) != Fail

proc replyContinueChunked*(ctx: HttpContext, chunk: string): bool {.flow.} =
  if chunk.len == 0:      # a zero-length chunk would terminate the stream
    return true
  if ctx.headOnly:        # chunked HEAD sends header block only
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

proc mimeOf(path: string): string =
  let ext = splitFile(path).ext
  if ext.len < 2: return "application/octet-stream"   # no extension (or a bare ".")
  case ext[1 .. ^1].toLowerAscii()
  of "html", "htm": "text/html; charset=utf-8"
  of "css": "text/css"
  of "js", "mjs": "text/javascript"
  of "json": "application/json"
  of "txt": "text/plain; charset=utf-8"
  of "png": "image/png"
  of "jpg", "jpeg": "image/jpeg"
  of "gif": "image/gif"
  of "svg": "image/svg+xml"
  of "wasm": "application/wasm"
  of "pdf": "application/pdf"
  else: "application/octet-stream"

when defined(linux):
  proc sendFileSyscall(outFd, inFd: cint, off: ptr Off, count: csize_t): int
    {.importc: "sendfile", header: "<sys/sendfile.h>".}

const fileReadSize = 64 * 1024

proc abortFile(ctx: HttpContext, msg: string): bool =
  ## Headers promised a Content-Length that cannot be met: the framing is
  ## broken, so the connection must not be reused.
  ctx.keepAlive = false
  ctx.closeHttpSocket(NetErrored, msg)
  false

proc replyFile*(ctx: HttpContext, path: string): bool {.flow.} =
  ## Stream a regular file as `200` with `Content-Type` from the extension.
  ## Held pipeline bytes are flushed first so the file cannot overtake an earlier response.
  if ctx.responded: return false
  let fd = posix.open(path.cstring, O_RDONLY or O_CLOEXEC)
  if fd < 0: return false
  var st: Stat
  if fstat(fd, st) != 0 or not S_ISREG(st.st_mode):
    discard posix.close(fd)
    return false
  ctx.responded = true
  # Header joins any held bytes; MSG_MORE lets it coalesce with the body.
  ctx.sendBuf.add version
  ctx.sendBuf.add "200 OK"
  ctx.sendBuf.add shortdivider
  appendDateLine(ctx, ctx.sendBuf)
  ctx.sendBuf.add "Content-Type: "
  ctx.sendBuf.add mimeOf(path)
  ctx.sendBuf.add shortdivider
  ctx.sendBuf.add contentlen
  ctx.sendBuf.addInt st.st_size
  ctx.sendBuf.add longdivider
  let noBody = ctx.headOnly or st.st_size == 0
  try:
    var head = move ctx.sendBuf
    let ok = ctx.writeToSocket(head, if noBody: lastSendFlags else: moreSendFlags) != Fail
    head.setLen(0)
    if head.len < 65536: ctx.sendBuf = head
    if not ok: return false
    if noBody:
      return true
    when defined(linux):
      var off: Off = 0
      var left = st.st_size
      while left > 0:
        let r = sendFileSyscall(ctx.socket.cint, fd, addr off, left.csize_t)
        if r > 0:
          left -= r
          continue
        if r == 0:
          return ctx.abortFile("file truncated while sending")
        let e = osLastError().int
        if e == EINTR.int: continue
        if e in [EAGAIN.int, EWOULDBLOCK.int]:
          if ctx.pf != nil: cast[PollFd](ctx.pf).wrReady = false
          ctx.waitSocketWritable()
          continue
        return ctx.abortFile(osErrorMsg(OSErrorCode(e)))
    else:
      var buf = newString(fileReadSize)
      var left = st.st_size
      while left > 0:
        let n = min(left, fileReadSize.int64).int
        let got = posix.read(fd, addr buf[0], n)
        if got < 0:
          if osLastError().int == EINTR.int: continue    # interrupted, the file is unchanged
          return ctx.abortFile("file read error")
        if got == 0: return ctx.abortFile("file truncated while sending")
        if ctx.sendSome(addr buf[0], got, lastSendFlags) == Fail:
          return false
        left -= got
  finally:
    discard posix.close(fd)
  true

proc closeSocket*(ctx: HttpContext, cause = CloseCalled, msg = "") {.deprecated: "use closeHttpSocket".} =
  closeHttpSocket(ctx, cause, msg)
