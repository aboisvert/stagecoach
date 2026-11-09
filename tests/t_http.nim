import std/[unittest, strutils, random, tables]
import helpers/fixture

var fx: Fixture

proc ok(c: RawClient, uri = "/"): bool =
  var r: Resp
  c.trySend("GET " & uri & " HTTP/1.1\r\nHost: t\r\n\r\n") and c.tryReadResponse(r) and r.status == 200

proc stillServes(): bool =
  let c = connectRaw(fx.port)
  defer: c.close()
  c.ok("/echo")

suite "http basics (compact)":
  setup:
    fx = startFixture(@["--socketTimeout=400"])
  teardown:
    stopFixture(fx)

  test "method, uri, body and captured headers round-trip":
    fx.stopFixture()
    fx = startFixture(@["--headers=origin,x-token"])
    let c = connectRaw(fx.port)
    defer: c.close()
    let r = c.post("/echo?a=1&b=2", "hello body", "Origin: http://x\r\nX-Token:  abc \r\n")
    check r.status == 200
    check "method=POST" in r.body
    check "uri=/echo?a=1&b=2" in r.body
    check "bodylen=10" in r.body
    check "body=hello body" in r.body
    check "h:origin=http://x" in r.body
    check "h:x-token=abc" in r.body

  test "peer close does not wedge server":
    let c = connectRaw(fx.port)
    c.close()
    check stillServes()

  test "Connection: close closes the socket":
    let c = connectRaw(fx.port)
    defer: c.close()
    c.sendRaw "GET / HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n"
    check c.readResponse().status == 200
    check c.expectClosed()

  test "HTTP/1.0 closes by default, honours keep-alive":
    let c = connectRaw(fx.port)
    defer: c.close()
    c.sendRaw "GET / HTTP/1.0\r\n\r\n"
    check c.readResponse().status == 200
    check c.expectClosed()
    let k = connectRaw(fx.port)
    defer: k.close()
    k.sendRaw "GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n"
    check k.readResponse().status == 200
    check k.ok()

  test "HTTP/1.0 keep-alive replies advertise Connection: keep-alive":
    let k = connectRaw(fx.port)
    defer: k.close()
    k.sendRaw "GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n"
    let r = k.readResponse()
    check r.header("connection").toLowerAscii == "keep-alive"
    k.sendRaw "GET / HTTP/1.0\r\n\r\n"            # plain 1.0: closes, no keep-alive claim
    check k.readResponse().header("connection").toLowerAscii != "keep-alive"

  test "HTTP/1.0 clients never receive chunked framing":
    let c = connectRaw(fx.port)
    defer: c.close()
    c.sendRaw "GET /chunked?n=3&size=10 HTTP/1.0\r\nConnection: keep-alive\r\n\r\n"
    var all = ""
    var r: Resp
    check c.tryReadResponse(r)
    check not r.chunked
    check r.header("transfer-encoding") == ""
    check c.expectClosed()                          # body is delimited by close

  test "empty uri and spaced header names are rejected":
    for bad in ["GET  HTTP/1.1\r\nHost: t\r\n\r\n", "GET / HTTP/1.1\r\nContent-Length : 0\r\n\r\n"]:
      let c = connectRaw(fx.port)
      discard c.trySend(bad)
      check c.expectClosed()
      c.close()

  test "client vanishing mid-response does not kill the server (SIGPIPE)":
    for _ in 0 ..< 5:
      let c = connectRaw(fx.port)
      c.sendRaw "GET /big?n=20000000 HTTP/1.1\r\nHost: t\r\n\r\n"
      var r: Resp
      discard c.tryReadResponse(r, 50)               # let the server start writing
      c.close()
    check stillServes()
    check fx.running

  test "keep-alive: 1000 sequential requests on one connection":
    let c = connectRaw(fx.port)
    defer: c.close()
    for i in 0 ..< 1000:
      check c.get("/echo?i=" & $i).body.contains("uri=/echo?i=" & $i & "\n")

  test "pipelining: 50 requests in one write answer in order":
    let c = connectRaw(fx.port)
    defer: c.close()
    var req = ""
    for i in 0 ..< 50: req.add "GET /echo?i=" & $i & " HTTP/1.1\r\nHost: t\r\n\r\n"
    c.sendRaw req
    let rs = c.readResponses(50)
    for i, r in rs: check ("uri=/echo?i=" & $i & "\n") in r.body

  test "pipelining with bodies, split at random points":
    var rng = initRand(42)
    let c = connectRaw(fx.port)
    defer: c.close()
    var req = ""
    var lens: seq[int]
    for i in 0 ..< 30:
      let n = rng.rand(0 .. 300)
      lens.add n
      let body = repeat(chr(ord('a') + i mod 26), n)
      req.add "POST /echo?i=" & $i & " HTTP/1.1\r\nHost: t\r\nContent-Length: " & $n & "\r\n\r\n" & body
    check c.sendSplit(req, [1, 7, 64, 1000, 3], delayMs = 0)
    let rs = c.readResponses(30)
    for i, r in rs:
      check ("uri=/echo?i=" & $i & "\n") in r.body
      check ("bodylen=" & $lens[i] & "\n") in r.body
      check ("body=" & repeat(chr(ord('a') + i mod 26), lens[i]) & "\n") in r.body

  test "header split across tiny writes":
    let c = connectRaw(fx.port)
    defer: c.close()
    check c.sendSplit("GET /echo HTTP/1.1\r\nHost: t\r\n\r\n", [1], delayMs = 2)
    check c.readResponse().status == 200

  test "malformed requests are dropped and counted, server survives":
    let bad = [
      "GET / HTTP/2.0\r\n\r\n",
      "GET / HTTP/1.2\r\n\r\n",
      "G@T / HTTP/1.1\r\n\r\n",
      "POST / HTTP/1.1\r\nContent-Length: -5\r\n\r\n",
      "POST / HTTP/1.1\r\nContent-Length: 1x\r\n\r\n",
      "POST / HTTP/1.1\r\nContent-Length: 9223372036854775807\r\n\r\n",
      "POST / HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\nx",
      "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
      "GET / HTTP/1.1\nHost: t\r\n\r\n"]
    for b in bad:
      let c = connectRaw(fx.port)
      discard c.trySend(b)
      check c.expectClosed()
      c.close()
    check fx.waitStat("close.ProtocolViolated", bad.len)
    check stillServes()

  test "handler exception is counted, closes the connection, server survives":
    let c = connectRaw(fx.port)
    defer: c.close()
    c.sendRaw "GET /raise HTTP/1.1\r\nHost: t\r\n\r\n"
    check c.expectClosed()
    check fx.waitStat("close.Excepted", 1)
    check stillServes()

  test "handler that closes the socket does not run again on pipelined bytes":
    fx.resetStats()
    let c = connectRaw(fx.port)
    defer: c.close()
    c.sendRaw "GET /closenoreply HTTP/1.1\r\nHost: t\r\n\r\nGET / HTTP/1.1\r\nHost: t\r\n\r\n"
    check c.expectClosed()
    check stillServes()
    check fx.stats()["hits"] == 0

  test "/close replies then closes":
    let c = connectRaw(fx.port)
    defer: c.close()
    check c.get("/close").body == "bye"
    check c.expectClosed()

  test "status codes: reply(code) frames with Content-Length: 0":
    let c = connectRaw(fx.port)
    defer: c.close()
    for code in [200, 204, 404, 500]:
      c.sendRaw "GET /code?c=" & $code & " HTTP/1.1\r\nHost: t\r\n\r\n"
      let r = c.readResponse()
      check r.status == code
    check c.ok()

  test "large and chunked responses":
    let c = connectRaw(fx.port)
    defer: c.close()
    check c.get("/big?n=3000000").body.len == 3000000
    let r = c.get("/chunked?n=40&size=1500")
    check r.chunked
    check r.body.len == 60000
    check r.body[0 ..< 3] == "aaa"
    check c.ok()

  test "oversized content-length is rejected, server survives":
    let c = connectRaw(fx.port)
    defer: c.close()
    c.sendRaw "POST / HTTP/1.1\r\nContent-Length: 9223372036854775807\r\n\r\n"
    check c.expectClosed()
    check stillServes()

  test "idle connection times out":
    fx.stopFixture()
    fx = startFixture(@["--socketTimeout=60000", "--idleTimeout=400"])
    let c = connectRaw(fx.port)
    defer: c.close()
    check c.expectClosed(3000)
    check fx.waitStat("close.TimedOut", 1)

  test "compact body at the bufferlength bound":
    fx.stopFixture()
    fx = startFixture(@["--buffer=5000", "--maxHeader=1000"])
    let c = connectRaw(fx.port)
    defer: c.close()
    let hdrLen = len("POST /echo HTTP/1.1\r\nHost: t\r\nContent-Length: 4900\r\n\r\n")
    let fits = 5000 + 1 - hdrLen
    let r = c.post("/echo", repeat('x', fits))
    check r.status == 200
    check ("bodylen=" & $fits) in r.body
    let c2 = connectRaw(fx.port)
    defer: c2.close()
    discard c2.trySend("POST /echo HTTP/1.1\r\nHost: t\r\nContent-Length: " & $(fits + 1) & "\r\n\r\n")
    check c2.expectClosed()

when isMainModule:
  echo "HTTP tests finished"
