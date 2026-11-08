import unittest, std/strutils
import stagelane/sched
import stagelane/core
from std/posix import INVALID_SOCKET
import stagecoach/httpserver

var server: HttpServer
var ctx: HttpContext

proc load(c: HttpContext, raw: string) =
  c.request = raw
  c.requestlen = raw.len

proc parseAll(c: HttpContext, s: HttpServer): bool =
  ## header scan + framing headers + request line, as the connection loop does
  c.contentreceived = 0
  if not c.isHeaderreceived(0, c.requestlen.int): return false
  c.contentreceived = c.requestlen - c.bodystart
  c.processHeaders(s) and c.parseRequestLine(s)

suite "HTTP parsing":
  setup:
    server = newHttpServer(loglevel = lvlError, parserequestline = true)
    ctx = server.newHttpContext(INVALID_SOCKET)

  test "parseRequestLine":
    ctx.load "GET /hello HTTP/1.1\c\L\c\L"
    check ctx.parseRequestLine(server)
    check ctx.getMethod() == "GET"
    check ctx.getUri() == "/hello"

  test "isBody index":
    ctx.request = newString(32)
    ctx.request[10 .. 14] = "hello"
    ctx.bodystart = 10
    ctx.requestlen = 15
    ctx.contentlength = 5
    ctx.contentreceived = 5
    check ctx.isBody("hello")
    check not ctx.isBody("hellp")

  test "content-length case insensitive":
    ctx.load "POST /x HTTP/1.1\c\LCONTENT-LENGTH: 3\c\L\c\L"
    check ctx.parseAll(server)
    check ctx.contentlength == 3

  test "content-length only matches a header line":
    ctx.load "GET /content-length:9 HTTP/1.1\c\Lx-content-length: 7\c\L\c\L"
    check ctx.parseAll(server)
    check ctx.contentlength == 0

  test "carry pipelined second request":
    let r1 = "GET /a HTTP/1.1\c\LHost: t\c\L\c\L"
    let r2 = "GET /b HTTP/1.1\c\LHost: t\c\L\c\L"
    ctx.load r1 & r2
    check ctx.isHeaderreceived(0, ctx.request.len)
    ctx.contentreceived = ctx.requestlen - ctx.bodystart
    ctx.recordCarry(server)
    check ctx.carryLen == r2.len
    ctx.prepareHttpContext(server)
    check ctx.isHeaderreceived(0, ctx.requestlen.int)
    check ctx.parseRequestLine(server)
    check ctx.getUri() == "/b"

  test "body does not include pipelined next request":
    let r1 = "POST /a HTTP/1.1\c\LContent-Length: 3\c\L\c\L" & "abc"
    let r2 = "GET /b HTTP/1.1\c\L\c\L"
    ctx.load r1 & r2
    check ctx.parseAll(server)
    check ctx.getBody() == "abc"
    check ctx.isBody("abc")
    ctx.recordCarry(server)
    check ctx.carryLen == r2.len

  test "content-length buffer bound":
    server.bufferlength = 100
    ctx.load "POST /x HTTP/1.1\c\LContent-Length: 70\c\L\c\L"
    check not ctx.parseAll(server)

  test "huge content-length rejected without crashing":
    ctx.load "POST /x HTTP/1.1\c\LContent-Length: 9223372036854775807\c\L\c\L"
    check not ctx.parseAll(server)

  test "negative and garbage content-length rejected":
    ctx.load "POST /x HTTP/1.1\c\LContent-Length: -5\c\L\c\L"
    check not ctx.parseAll(server)
    ctx = server.newHttpContext(INVALID_SOCKET)
    ctx.load "POST /x HTTP/1.1\c\LContent-Length: 1x\c\L\c\L"
    check not ctx.parseAll(server)

  test "transfer-encoding rejected":
    ctx.load "POST /x HTTP/1.1\c\LTransfer-Encoding: chunked\c\L\c\L"
    check not ctx.parseAll(server)

  test "content-length does not leak into next request":
    let s = newHttpServer(loglevel = lvlError, headerfields = ["origin"])
    let c = s.newHttpContext(INVALID_SOCKET)
    c.load "POST /x HTTP/1.1\c\LContent-Length: 5\c\L\c\L"
    check c.parseAll(s)
    check c.contentlength == 5
    c.prepareHttpContext(s)
    c.load "GET /y HTTP/1.1\c\L\c\L"
    check c.parseAll(s)
    check c.contentlength == 0

  test "keep-alive semantics":
    ctx.load "GET / HTTP/1.1\c\LConnection: close\c\L\c\L"
    check ctx.parseAll(server)
    check not ctx.keepAlive
    ctx.prepareHttpContext(server)
    ctx.load "GET / HTTP/1.0\c\L\c\L"
    check ctx.parseAll(server)
    check not ctx.keepAlive
    ctx.prepareHttpContext(server)
    ctx.load "GET / HTTP/1.0\c\LConnection: keep-alive\c\L\c\L"
    check ctx.parseAll(server)
    check ctx.keepAlive
    ctx.prepareHttpContext(server)
    ctx.load "GET / HTTP/1.1\c\L\c\L"
    check ctx.parseAll(server)
    check ctx.keepAlive

  test "requested headers captured":
    let s = newHttpServer(loglevel = lvlError, headerfields = ["origin"])
    let c = s.newHttpContext(INVALID_SOCKET)
    c.load "GET / HTTP/1.1\c\LHost: t\c\LOrigin:   http://x  \c\L\c\L"
    check c.parseAll(s)
    check c.headers["origin"] == "http://x"

  test "extension and non-prefixed methods are valid tokens":
    for m in ["REPORT", "LOCK", "QUERY", "PAPAYA", "GHOST"]:
      ctx.prepareHttpContext(server)
      ctx.load m & " /x HTTP/1.1\c\L\c\L"
      check ctx.parseAll(server)
      check ctx.getMethod() == m

  test "methods with non-token bytes are rejected":
    ctx.load "PA{ /x HTTP/1.1\c\L\c\L"
    check not ctx.parseAll(server)

  test "duplicate content-length rejected":
    ctx.load "POST /x HTTP/1.1\c\LContent-Length: 3\c\LContent-Length: 4\c\L\c\L"
    check not ctx.parseAll(server)

  test "duplicate wanted header rejected":
    ctx.load "GET / HTTP/1.1\c\LConnection: close\c\LConnection: keep-alive\c\L\c\L"
    check not ctx.parseAll(server)

  test "duplicate unwanted headers are harmless":
    ctx.load "GET / HTTP/1.1\c\LHost: a\c\LHost: b\c\L\c\L"
    check ctx.parseAll(server)
    check ctx.contentlength == 0

  test "bare LF header line rejected":
    ctx.load "GET / HTTP/1.1\c\LHost: t\n\c\L\c\L"
    check not ctx.parseAll(server)

  test "junk after version rejected":
    ctx.load "GET / HTTP/1.1x\c\L\c\L"
    check not ctx.parseAll(server)

  test "close token wins over keep-alive":
    ctx.load "GET / HTTP/1.1\c\LConnection: keep-alive, close\c\L\c\L"
    check ctx.parseAll(server)
    check not ctx.keepAlive
    ctx.prepareHttpContext(server)
    ctx.load "GET / HTTP/1.1\c\LConnection: close, keep-alive\c\L\c\L"
    check ctx.parseAll(server)
    check not ctx.keepAlive
    ctx.prepareHttpContext(server)
    ctx.load "GET / HTTP/1.0\c\LConnection: keep-alive, close\c\L\c\L"
    check ctx.parseAll(server)
    check not ctx.keepAlive

  test "endRequest requires a fully consumed streaming body":
    let s = newHttpServer(loglevel = lvlError, contenttype = ContentType.Streaming)
    let c = s.newHttpContext(INVALID_SOCKET)
    c.load "POST /x HTTP/1.1\c\LContent-Length: 5\c\L\c\Labc"
    check c.parseAll(s)
    check c.bodystart >= 0 and c.contentlength == 5
    c.socket = SocketHandle(1)        # pretend the connection is open
    c.keepAlive = true
    c.bodyDelivered = 3
    check not c.endRequest()          # tail would corrupt the next request
    c.bodyDelivered = 5
    check c.endRequest()              # fully consumed: keep-alive is fine

  test "endRequest keeps compact connections without readBodyChunk":
    ctx.socket = SocketHandle(1)
    ctx.keepAlive = true
    ctx.load "POST /x HTTP/1.1\c\LContent-Length: 5\c\L\c\Lhello"
    check ctx.parseAll(server)
    check ctx.bodyDelivered == 0      # getBody() never advances it
    check ctx.endRequest()

  test "serve rejects maxheaderlength > bufferlength":
    server.maxheaderlength = 200_000
    expect ValueError:
      discard setupRuntime(server, 18999, 1, 8, 4)

suite "HTTP parsing: extended":
  setup:
    server = newHttpServer(loglevel = lvlError, parserequestline = true)
    ctx = server.newHttpContext(INVALID_SOCKET)

  test "request line table":
    const cases = [
      # raw, ok, method, uri
      ("GET /hello HTTP/1.1\c\L\c\L", true, "GET", "/hello"),
      ("POST /a?b=1&c=2 HTTP/1.1\c\L\c\L", true, "POST", "/a?b=1&c=2"),
      ("GET /x#frag HTTP/1.1\c\L\c\L", true, "GET", "/x#frag"),
      ("OPTIONS * HTTP/1.1\c\L\c\L", true, "OPTIONS", "*"),
      ("DELETE /d HTTP/1.0\c\L\c\L", true, "DELETE", "/d"),
      ("PATCH /p HTTP/1.1\c\L\c\L", true, "PATCH", "/p"),
      ("GET /x HTTP/2.0\c\L\c\L", false, "", ""),
      ("GET /x HTTP/1.2\c\L\c\L", false, "", ""),
      ("GET /x HTTP/1.10\c\L\c\L", false, "", ""),
      ("GET /x HTTP/1.1x\c\L\c\L", false, "", ""),
      ("GET /x http/1.1\c\L\c\L", false, "", ""),
      ("GET\c\L\c\Lxxxxxxxxxxxx", false, "", ""),
      ("G\tT /x HTTP/1.1\c\L\c\L", false, "", ""),
      ("GET /x\c\L\c\Lxxxxxxxxxxx", false, "", ""),
      ("GET /x", false, "", "")]
    for (raw, ok, m, u) in cases:
      let s = newHttpServer(loglevel = lvlError)
      let c = s.newHttpContext(INVALID_SOCKET)
      c.load raw
      check c.parseRequestLine(s) == ok
      if ok:
        check c.getMethod() == m
        check c.getUri() == u

  test "http10 flag follows the version":
    ctx.load "GET / HTTP/1.0\c\L\c\L"
    check ctx.parseRequestLine(server)
    check ctx.http10
    ctx.prepareHttpContext(server)
    ctx.load "GET / HTTP/1.1\c\L\c\L"
    check ctx.parseRequestLine(server)
    check not ctx.http10

  test "very long uri":
    let uri = "/" & repeat('a', 5000)
    ctx.load "GET " & uri & " HTTP/1.1\c\L\c\L"
    check ctx.parseRequestLine(server)
    check ctx.getUri() == uri
    check ctx.startsUri("/aaa")
    check not ctx.startsUri("/b")

  test "isHeaderreceived finds the terminator whatever the split":
    let raw = "GET /x HTTP/1.1\c\LHost: t\c\L\c\L"
    for cut in 1 ..< raw.len:
      let c = server.newHttpContext(INVALID_SOCKET)
      c.request = raw
      check not c.isHeaderreceived(0, cut) or cut == raw.len
      check c.isHeaderreceived(cut, raw.len)
      check c.bodystart == raw.len

  test "isHeaderreceived: incomplete or LF-only input is not a header":
    ctx.load "GET / HTTP/1.1\c\LHost: t\c\L"
    check not ctx.isHeaderreceived(0, ctx.requestlen.int)
    ctx.load "GET / HTTP/1.1\LHost: t\L\L"
    check not ctx.isHeaderreceived(0, ctx.requestlen.int)
    ctx.load "abc"
    check not ctx.isHeaderreceived(0, 3)

  test "header value whitespace, empty values, mixed case, unknown headers":
    let s = newHttpServer(loglevel = lvlError, headerfields = ["x-a", "x-b", "x-c"])
    let c = s.newHttpContext(INVALID_SOCKET)
    c.load "GET / HTTP/1.1\c\LX-A:nospace\c\Lx-B:\t tab \t\c\LX-C:\c\LX-Other: 1\c\L\c\L"
    check c.parseAll(s)
    check c.headers["x-a"] == "nospace"
    check c.headers["x-b"] == "tab"
    check c.headers["x-c"] == ""

  test "whitespace between header name and colon is rejected (RFC 7230 3.2.4)":
    for raw in ["GET / HTTP/1.1\c\LContent-Length : 5\c\L\c\L",
                "GET / HTTP/1.1\c\LX-A\t: v\c\L\c\L"]:
      let s = newHttpServer(loglevel = lvlError, headerfields = ["x-a"])
      let c = s.newHttpContext(INVALID_SOCKET)
      c.load raw
      check not c.parseAll(s)

  test "empty uri is rejected":
    let s = newHttpServer(loglevel = lvlError)
    let c = s.newHttpContext(INVALID_SOCKET)
    c.load "GET  HTTP/1.1\c\L\c\L"
    check not c.parseRequestLine(s)

  test "header line without a colon is ignored":
    ctx.load "GET / HTTP/1.1\c\Lgarbage line\c\L\c\L"
    check ctx.parseAll(server)

  test "content-length table":
    const cases = [
      ("0", true, 0), ("5", true, 5), ("007", true, 7), ("  12  ", true, 12),
      ("+5", false, 0), ("-1", false, 0), ("5.0", false, 0), ("0x10", false, 0),
      ("1 2", false, 0), ("99999999999999999999", false, 0)]
    for (v, ok, n) in cases:
      let s = newHttpServer(loglevel = lvlError)
      let c = s.newHttpContext(INVALID_SOCKET)
      c.load "POST /x HTTP/1.1\c\LContent-Length: " & v & "\c\L\c\L"
      check c.parseAll(s) == ok
      if ok: check c.contentlength == n

  test "empty content-length value means no body":
    ctx.load "POST /x HTTP/1.1\c\LContent-Length:\c\L\c\L"
    check ctx.parseAll(server)
    check ctx.contentlength == 0

  test "content-length at the exact buffer bound":
    server.bufferlength = 100
    let head = "POST /x HTTP/1.1\c\LContent-Length: "
    let tail = "\c\L\c\L"
    let bodystart = head.len + 2 + tail.len           # two-digit length
    let fits = 100 + 1 - bodystart
    ctx.load head & $fits & tail
    check ctx.parseAll(server)
    let c2 = server.newHttpContext(INVALID_SOCKET)
    c2.load head & $(fits + 1) & tail
    check not c2.parseAll(server)

  test "content-length is not bounded by bufferlength when streaming":
    let s = newHttpServer(loglevel = lvlError, contenttype = Streaming)
    s.bufferlength = 100
    let c = s.newHttpContext(INVALID_SOCKET)
    c.load "POST /x HTTP/1.1\c\LContent-Length: 5000000\c\L\c\L"
    check c.parseAll(s)
    check c.contentlength == 5_000_000

  test "NoBody servers reject a non-zero content-length, accept zero":
    let s = newHttpServer(loglevel = lvlError, contenttype = NoBody)
    let c = s.newHttpContext(INVALID_SOCKET)
    c.load "POST /x HTTP/1.1\c\LContent-Length: 4\c\L\c\L"
    check not c.parseAll(s)
    let c2 = s.newHttpContext(INVALID_SOCKET)
    c2.load "GET /x HTTP/1.1\c\LContent-Length: 0\c\L\c\L"
    check c2.parseAll(s)

  test "keep-alive matrix":
    const cases = [
      ("1.1", "", true), ("1.1", "close", false), ("1.1", "Close", false),
      ("1.1", "keep-alive", true), ("1.1", "Keep-Alive", true),
      ("1.1", "keep-alive, Upgrade", true), ("1.1", "upgrade, close", false),
      ("1.0", "", false), ("1.0", "close", false), ("1.0", "keep-alive", true),
      ("1.0", "Keep-Alive", true), ("1.0", "Upgrade, keep-alive", true),
      ("1.0", "keep-alive, close", false)]
    for (ver, conn, expected) in cases:
      let c = server.newHttpContext(INVALID_SOCKET)
      let hdr = if conn.len > 0: "Connection: " & conn & "\c\L" else: ""
      c.load "GET / HTTP/" & ver & "\c\L" & hdr & "\c\L"
      check c.parseAll(server)
      check c.keepAlive == expected

  test "accessors on an untouched context":
    check ctx.getUri() == ""
    check ctx.getMethod() == ""
    check ctx.getBody() == ""
    check not ctx.isUri("/")
    check not ctx.isMethod("GET")
    check not ctx.isBody("x")
    check ctx.getRequest() == ""

  test "accessors: isUri / startsUri / isMethod":
    ctx.load "POST /abc/def HTTP/1.1\c\L\c\L"
    check ctx.parseRequestLine(server)
    check ctx.isUri("/abc/def")
    check not ctx.isUri("/abc")
    check not ctx.isUri("/abc/defg")
    check ctx.startsUri("/abc")
    check ctx.startsUri("")
    check not ctx.startsUri("/abc/def/ghi")
    check ctx.isMethod("POST")
    check not ctx.isMethod("PO")
    check not ctx.isMethod("POSTS")

  test "three pipelined requests, with and without bodies":
    let reqs = ["GET /a HTTP/1.1\c\L\c\L",
                "POST /b HTTP/1.1\c\LContent-Length: 4\c\L\c\Lwxyz",
                "POST /c HTTP/1.1\c\LContent-Length: 0\c\L\c\L"]
    ctx.load reqs[0] & reqs[1] & reqs[2]
    let bodies = ["", "wxyz", ""]
    for i in 0 ..< 3:
      check ctx.parseAll(server)
      check ctx.getUri() == ["/a", "/b", "/c"][i]
      check ctx.getBody() == bodies[i]
      ctx.recordCarry(server)
      if i < 2:
        check ctx.carryLen > 0
        let carried = ctx.carryLen
        ctx.prepareHttpContext(server)
        check ctx.requestlen == carried
      else:
        check ctx.carryLen == 0

  test "readBodyChunk without socket IO":
    # Fully buffered body: delivered in one chunk and marked complete.
    ctx.load "POST /x HTTP/1.1\c\LContent-Length: 4\c\L\c\Lwxyz"
    check ctx.parseAll(server)
    var (st, chunk) = run ctx.readBodyChunk(server)
    check st == Complete
    check chunk == "wxyz"
    (st, chunk) = run ctx.readBodyChunk(server)
    check st == Complete
    check chunk == ""
    # No body at all.
    ctx.prepareHttpContext(server)
    ctx.load "GET /x HTTP/1.1\c\L\c\L"
    check ctx.parseAll(server)
    (st, chunk) = run ctx.readBodyChunk(server)
    check st == Complete
    check chunk == ""

when isMainModule:
  echo "All parser tests passed"
