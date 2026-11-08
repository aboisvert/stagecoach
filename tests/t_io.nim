## beginRequest / endRequest driven over a socketpair by a scripted peer task.
import std/[unittest, strutils, atomics]
import stagecoach/[flow, httpserver]
import stagelane/sched
import helpers/pairs

var closeCauses: seq[SocketCloseCause]

proc onClose(server: StagecoachServer, socket: SocketHandle, cause: SocketCloseCause, msg: string) {.gcsafe, nimcall, raises: [].} =
  {.cast(gcsafe).}: closeCauses.add cause

proc mkServer(ct = Compact): HttpServer =
  closeCauses.setLen(0)
  result = newHttpServer(loglevel = lvlError, contenttype = ct)
  result.onCloseSocketCallback = onClose
  result.sockettimeoutms = 300
  result.requestTimeoutms = 0

proc readAllBody(ctx: HttpContext): string {.flow.} =
  while true:
    let (st, chunk) = ctx.readBodyChunk(ctx.server)
    result.add chunk
    if st != Progress: break

proc streamBody(ctx: HttpContext, peer: SocketHandle, chunks: seq[string]): string {.flow.} =
  let t = go peerScript(peer, chunks, 5)
  if not ctx.beginRequest(): return "<begin failed>"
  result = ctx.readAllBody()
  cancel(t)

suite "beginRequest":
  test "whole request in one read":
    var p = newPair(mkServer())
    let ok = run driveBegin(p.ctx, p.peer, @["GET /a HTTP/1.1\r\nHost: t\r\n\r\n"], 0)
    check ok == brTrue
    check p.ctx.getUri() == "/a"
    p.closePeer()

  test "one byte at a time":
    var p = newPair(mkServer())
    var chunks: seq[string]
    for ch in "POST /b HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello": chunks.add $ch
    check (run driveBegin(p.ctx, p.peer, chunks, 1)) == brTrue
    check p.ctx.getUri() == "/b"
    check p.ctx.getBody() == "hello"
    p.closePeer()

  test "header split at every offset":
    let raw = "GET /split HTTP/1.1\r\nHost: t\r\nX-A: b\r\n\r\n"
    for cut in 1 ..< raw.len:
      var p = newPair(mkServer())
      check (run driveBegin(p.ctx, p.peer, @[raw[0 ..< cut], raw[cut .. ^1]], 2)) == brTrue
      check p.ctx.getUri() == "/split"
      p.closePeer()

  test "compact body over many reads":
    var p = newPair(mkServer())
    let body = repeat("0123456789", 500)
    var chunks = @["POST /c HTTP/1.1\r\nContent-Length: " & $body.len & "\r\n\r\n"]
    for i in countup(0, body.len - 1, 97): chunks.add body[i ..< min(i + 97, body.len)]
    check (run driveBegin(p.ctx, p.peer, chunks, 0)) == brTrue
    check p.ctx.getBody() == body
    p.closePeer()

  test "body and next request in one read are carried":
    var p = newPair(mkServer())
    let r1 = "POST /one HTTP/1.1\r\nContent-Length: 3\r\n\r\nabc"
    let r2 = "GET /two HTTP/1.1\r\n\r\n"
    check (run driveBegin(p.ctx, p.peer, @[r1 & r2], 0)) == brTrue
    check p.ctx.getBody() == "abc"
    check p.ctx.endRequest()
    check p.ctx.carryLen == r2.len
    check (run driveBegin(p.ctx, p.peer, @[], 0)) == brTrue
    check p.ctx.getUri() == "/two"
    p.closePeer()

  test "EOF in the middle of the header":
    var p = newPair(mkServer())
    peerSend(p.peer, "GET /x HTT")
    p.closePeer()
    check (run driveBegin(p.ctx, p.peer, @[], 0)) == brFalse
    check closeCauses == @[ClosedbyClient]

  test "EOF in the middle of a compact body":
    var p = newPair(mkServer())
    peerSend(p.peer, "POST /x HTTP/1.1\r\nContent-Length: 10\r\n\r\nabc")
    p.closePeer()
    check (run driveBegin(p.ctx, p.peer, @[], 0)) == brFalse
    check closeCauses == @[ClosedbyClient]

  test "oversized header is a protocol violation":
    let s = mkServer()
    s.maxheaderlength = 64
    s.bufferlength = 1000
    var p = newPair(s)
    peerSend(p.peer, "GET /x HTTP/1.1\r\nX: " & repeat('a', 200))
    check (run driveBegin(p.ctx, p.peer, @[], 0)) == brFalse
    check closeCauses == @[ProtocolViolated]
    p.closePeer()

  test "bad request line is a protocol violation":
    var p = newPair(mkServer())
    check (run driveBegin(p.ctx, p.peer, @["GET /x HTTP/9.9\r\n\r\n"], 0)) == brFalse
    check closeCauses == @[ProtocolViolated]
    p.closePeer()

  test "idle peer is cancelled by sockettimeoutms":
    var p = newPair(mkServer())
    check (run driveBegin(p.ctx, p.peer, @[], 0)) == brCancelled
    p.closePeer()

  test "dribbling header hits requestTimeoutms":
    let s = mkServer()
    s.requestTimeoutms = 150
    s.sockettimeoutms = 1000
    var p = newPair(s)
    var chunks: seq[string]
    for ch in "GET /slow HTTP/1.1\r\nX-A: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa": chunks.add $ch
    check (run driveBegin(p.ctx, p.peer, chunks, 20)) == brFalse
    check closeCauses == @[TimedOut]
    p.closePeer()

suite "streaming":
  test "tiny buffer reassembles the exact body":
    let s = mkServer(Streaming)
    s.bufferlength = 64
    s.maxheaderlength = 64
    var p = newPair(s)
    let body = repeat("abcdefghij", 100)
    var chunks = @["POST /s HTTP/1.1\r\nContent-Length: " & $body.len & "\r\n\r\n"]
    for i in countup(0, body.len - 1, 50): chunks.add body[i ..< min(i + 50, body.len)]
    check (run streamBody(p.ctx, p.peer, chunks)) == body
    check p.ctx.endRequest()
    p.closePeer()

suite "endRequest":
  test "false when the socket is closed":
    var p = newPair(mkServer())
    discard run driveBegin(p.ctx, p.peer, @["GET / HTTP/1.1\r\n\r\n"], 0)
    p.ctx.closeHttpSocket()
    check not p.ctx.endRequest()
    p.closePeer()

  test "false when keep-alive is off":
    var p = newPair(mkServer())
    discard run driveBegin(p.ctx, p.peer, @["GET / HTTP/1.1\r\nConnection: close\r\n\r\n"], 0)
    check not p.ctx.endRequest()
    p.closePeer()

  test "true and no carry for a lone request":
    var p = newPair(mkServer())
    discard run driveBegin(p.ctx, p.peer, @["GET / HTTP/1.1\r\n\r\n"], 0)
    check p.ctx.endRequest()
    check p.ctx.carryLen == 0
    p.closePeer()

  test "beginRequest refuses work once the process is shutting down":
    var p = newPair(mkServer())
    shutdown()
    check (run driveBegin(p.ctx, p.peer, @[], 0)) == brFalse
    shuttingdown.store(false)
    p.closePeer()

when isMainModule:
  echo "IO tests finished"
