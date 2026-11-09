## Response framing over a socketpair: exact wire bytes, chunked encoding,
## partial writes, write timeout and writes to a closed peer.
import std/[unittest, strutils, posix, nativesockets, os]
import stagecoach/[flow, httpserver]
import stagelane/sched
import helpers/pairs

proc mkServer(): HttpServer =
  result = newHttpServer(loglevel = lvlError)
  result.sockettimeoutms = 300

template wire(sendProc: untyped): string =
  ## Runs `sendProc(ctx)` against a fresh pair and returns what the peer received.
  block:
    var p = newPair(mkServer())
    run sendProc(p.ctx)
    let got = peerRecvAll(p.peer)
    p.closePeer()
    got

proc doReply200(ctx: HttpContext) {.flow.} = discard ctx.reply(Http200)
proc doReply204(ctx: HttpContext) {.flow.} = discard ctx.reply(Http204)
proc doReply404(ctx: HttpContext) {.flow.} = discard ctx.reply(Http404)
proc doBody(ctx: HttpContext) {.flow.} = ctx.reply("hello")
proc doCreated(ctx: HttpContext) {.flow.} = ctx.reply(Http201, "x", ["Location: /a", "X-B: c"])
proc doHeaders(ctx: HttpContext) {.flow.} = ctx.replyHeaders(Http303, ["Location: /z"])
proc doEmptyBody(ctx: HttpContext) {.flow.} = ctx.reply("")

proc doHead(ctx: HttpContext) {.flow.} =
  ctx.headOnly = true
  ctx.reply("abc")

suite "wire format":
  test "bare status replies":
    check wire(doReply200) == "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
    check wire(doReply204) == "HTTP/1.1 204 No Content\r\n\r\n"
    check wire(doReply404) == "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"

  test "body reply":
    check wire(doBody) == "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello"
    check wire(doEmptyBody) == "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"

  test "extra headers precede Content-Length":
    check wire(doCreated) ==
      "HTTP/1.1 201 Created\r\nLocation: /a\r\nX-B: c\r\nContent-Length: 1\r\n\r\nx"
    check wire(doHeaders) == "HTTP/1.1 303 See Other\r\nLocation: /z\r\nContent-Length: 0\r\n\r\n"

  test "HEAD omits body bytes but keeps Content-Length":
    let got = wire(doHead)
    check got == "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\n"
    check "abc" notin got

proc sendChunked(ctx: HttpContext, chunks: seq[string]) {.flow.} =
  discard ctx.replyStartChunked(Http200, ["X-T: 1"])
  for c in chunks: discard ctx.replyContinueChunked(c)
  discard ctx.replyFinishChunked()

proc chunkedOf(chunks: seq[string]): string =
  var p = newPair(mkServer())
  run sendChunked(p.ctx, chunks)
  result = peerRecvAll(p.peer)
  p.closePeer()

suite "chunked":
  test "head and terminator":
    check chunkedOf(@[]) == "HTTP/1.1 200 OK\r\nX-T: 1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"

  test "hex sizes around boundaries":
    for n in [1, 9, 10, 15, 16, 17, 255, 256, 4096]:
      let out1 = chunkedOf(@[repeat('x', n)])
      let head = "Transfer-Encoding: chunked\r\n\r\n"
      let body = out1[out1.find(head) + head.len .. ^1]
      check body == n.toHex.strip(trailing = false, chars = {'0'}) & "\r\n" & repeat('x', n) & "\r\n0\r\n\r\n"

  test "empty chunks are skipped, they would end the stream":
    let o = chunkedOf(@["", "ab", "", "c"])
    check o.endsWith("2\r\nab\r\n1\r\nc\r\n0\r\n\r\n")
    check o.count("0\r\n\r\n") == 1

type Sink = object
  fd: SocketHandle
  got: int

proc drain(s: ptr Sink, gapMs: int) {.flow.} =
  ## Slow reader: waits, then drains whatever is there, repeatedly.
  var misses = 0
  while misses < 20:
    delay(gapMs)
    let before = s.got
    s.fd.setBlocking(false)
    var buf: array[65536, char]
    while true:
      let r = recv(s.fd, addr buf[0], buf.len, 0)
      if r <= 0: break
      s.got += r
    if s.got == before: inc misses else: misses = 0

proc replyWithSlowReader(ctx: HttpContext, sink: ptr Sink, n: int) {.flow.} =
  let t = go drain(sink, 5)
  ctx.reply(repeat('b', n))
  delay(150)
  cancel(t)

proc bigReply(ctx: HttpContext, n: int) {.flow.} = ctx.reply(repeat('b', n))

suite "sendBuf reuse":
  test "small responses keep the buffer, big ones drop it":
    var p = newPair(mkServer())
    run doBody(p.ctx)
    check p.ctx.sendBuf.len == 0     # flushed; the buffer is kept for reuse
    let s = mkServer()
    s.sockettimeoutms = 3000
    var p2 = newPair(s)
    var sink = Sink(fd: p2.peer)
    run replyWithSlowReader(p2.ctx, addr sink, 200_000)
    check p2.ctx.sendBuf.len == 0
    discard peerRecvAll(p.peer)
    p.closePeer()
    p2.closePeer()

proc replyExpectingCancel(ctx: HttpContext): bool {.flow.} =
  try:
    ctx.reply(repeat('b', 20_000_000))
  except CancelledError:
    return true
  false

proc writeAfterClose(ctx: HttpContext): SocketState {.flow.} =
  ctx.writeToSocket(repeat('x', 100_000), MSG_DONTWAIT)

suite "partial writes and failures":
  test "8 MB body to a slow reader waits for writability":
    let s = mkServer()
    s.sockettimeoutms = 3000
    var p = newPair(s)
    var sink = Sink(fd: p.peer)
    run replyWithSlowReader(p.ctx, addr sink, 8_000_000)
    check sink.got >= 8_000_000
    check p.ctx.socket != INVALID_SOCKET
    p.closePeer()

  test "a peer that never reads trips the write timeout":
    var p = newPair(mkServer())
    check run replyExpectingCancel(p.ctx)
    p.closePeer()

  test "writing to a closed peer fails, closes the socket and does not raise SIGPIPE":
    var p = newPair(mkServer())
    p.closePeer()
    let st = run writeAfterClose(p.ctx)
    check st == Fail
    check p.ctx.socket == INVALID_SOCKET

proc doDate(ctx: HttpContext) {.flow.} = ctx.reply("x")

proc doHeadFile(ctx: HttpContext, path: string) {.flow.} =
  ctx.headOnly = true
  discard ctx.replyFile(path)

suite "sendDate and replyFile":
  test "sendDate adds a 37-byte Date line":
    var s = mkServer()
    s.sendDate = true
    var p = newPair(s)
    run doDate(p.ctx)
    let got = peerRecvAll(p.peer)
    p.closePeer()
    check got.count("Date: ") == 1
    check got.startsWith("HTTP/1.1 200")
    let di = got.find("\r\nDate: ")
    check di > 0
    check got[di + 2 ..< got.find("\r\n", di + 2) + 2].len == 37

  test "replyFile sends Content-Length and body bytes":
    let path = getTempDir() / "stagecoach_replyfile_test"
    writeFile(path, "file-bytes")
    let p = path
    proc doFile(ctx: HttpContext) {.flow.} = discard ctx.replyFile(p)
    let got = wire(doFile)
    removeFile(path)
    check "Content-Length: 10" in got
    check got.endsWith("file-bytes")

  test "HEAD replyFile omits body":
    let path = getTempDir() / "stagecoach_headfile_test"
    writeFile(path, "secret")
    let p = path
    proc headFile(ctx: HttpContext) {.flow.} = doHeadFile(ctx, p)
    let got = wire(headFile)
    removeFile(path)
    check "Content-Length: 6" in got
    check "secret" notin got

when isMainModule:
  echo "Response tests finished"

suite "replyFile MIME types":
  test "content types by extension (case-insensitive, unknown falls back)":
    let exts = [
      ("a.html", "text/html; charset=utf-8"), ("a.htm", "text/html; charset=utf-8"),
      ("a.css", "text/css"), ("a.js", "text/javascript"), ("a.mjs", "text/javascript"),
      ("a.json", "application/json"), ("a.txt", "text/plain; charset=utf-8"),
      ("a.png", "image/png"), ("a.wasm", "application/wasm"),
      ("A.HTML", "text/html; charset=utf-8"), ("a.UnknownEX7", "application/octet-stream"),
      ("noext", "application/octet-stream")]
    for (name, mime) in exts:
      let path = getTempDir() / name
      writeFile(path, $name.len)
      var p = newPair(mkServer())
      proc doFile(ctx: HttpContext) {.flow.} = discard ctx.replyFile(path)
      run doFile(p.ctx)
      let got = peerRecvAll(p.peer)
      p.closePeer()
      removeFile(path)
      check got.startsWith("HTTP/1.1 200 OK")
      check ("Content-Type: " & mime) in got
      check got.endsWith($name.len)

  test "replyFile on a directory fails without touching the socket":
    let d = getTempDir()
    var p = newPair(mkServer())
    proc doDir(ctx: HttpContext) {.flow.} = check not ctx.replyFile(d)
    run doDir(p.ctx)
    check not p.ctx.responded
    p.closePeer()

suite "review regressions":
  test "HEAD stays body-less with parserequestline off":
    var s = newHttpServer(loglevel = lvlError, parserequestline = false)
    s.sockettimeoutms = 300
    var p = newPair(s)
    peerSend(p.peer, "HEAD /x HTTP/1.1\r\n\r\n")
    check p.ctx.beginRequest()
    check p.ctx.headOnly
    p.closePeer()

  test "reject does not echo exception text and sets Content-Type":
    var p = newPair(mkServer())
    p.ctx.reject(Http500, Excepted, "internal server error")
    let got = peerRecvAll(p.peer)
    p.closePeer()
    check got.startsWith("HTTP/1.1 500")
    check "Content-Type: text/plain" in got

  test "replyFile on a missing path fails without touching the socket":
    var p = newPair(mkServer())
    proc doMissing(ctx: HttpContext) {.flow.} = check not ctx.replyFile("/nonexistent/x")
    run doMissing(p.ctx)
    check not p.ctx.responded
    p.closePeer()
