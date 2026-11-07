import unittest
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

when isMainModule:
  echo "All parser tests passed"
