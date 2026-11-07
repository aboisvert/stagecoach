import unittest
from std/posix import INVALID_SOCKET
import stagecoach/httpserver

var server: HttpServer
var ctx: HttpContext

suite "HTTP parsing":
  setup:
    server = newHttpServer(loglevel = lvlError, parserequestline = true)
    ctx = server.newHttpContext(INVALID_SOCKET)

  test "parseRequestLine":
    ctx.request = "GET /hello HTTP/1.1\c\L\c\L"
    ctx.requestlen = ctx.request.len
    check ctx.parseRequestLine(server)
    check ctx.getMethod() == "GET"
    check ctx.getUri() == "/hello"

  test "isBody index":
    ctx.request = newString(32)
    ctx.request[10 .. 14] = "hello"
    ctx.bodystart = 10
    ctx.requestlen = 15
    check ctx.isBody("hello")
    check not ctx.isBody("hellp")

  test "content-length case insensitive":
    ctx.request = "POST /x HTTP/1.1\c\LCONTENT-LENGTH: 3\c\L\c\L"
    ctx.requestlen = ctx.request.len
    check ctx.isHeaderreceived(0, ctx.request.len)
    check ctx.getContentLength(server)
    check ctx.contentlength == 3

  test "carry pipelined second request":
    let r1 = "GET /a HTTP/1.1\c\LHost: t\c\L\c\L"
    let r2 = "GET /b HTTP/1.1\c\LHost: t\c\L\c\L"
    ctx.request = r1 & r2
    ctx.requestlen = ctx.request.len
    check ctx.isHeaderreceived(0, ctx.request.len)
    ctx.recordCarry(server)
    check ctx.carryLen == r2.len
    ctx.prepareHttpContext(server)
    check ctx.isHeaderreceived(0, ctx.requestlen.int)
    check ctx.parseRequestLine(server)
    check ctx.getUri() == "/b"

  test "content-length buffer bound":
    server.bufferlength = 100
    ctx.request = "POST /x HTTP/1.1\c\LContent-Length: 70\c\L\c\L"
    ctx.requestlen = ctx.request.len
    check ctx.isHeaderreceived(0, ctx.request.len)
    check not ctx.getContentLength(server)

when isMainModule:
  echo "All parser tests passed"
