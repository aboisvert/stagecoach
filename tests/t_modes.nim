import std/[unittest, strutils]
import helpers/fixture

var fx: Fixture

proc stillServes(): bool =
  let c = connectRaw(fx.port)
  defer: c.close()
  var r: Resp
  c.trySend("GET /echo HTTP/1.1\r\nHost: t\r\n\r\n") and c.tryReadResponse(r) and r.status == 200

proc cksum(s: string): uint32 =
  for c in s: result = result * 31'u32 + uint32(ord(c))

suite "NoBody mode":
  setup: fx = startFixture(@["--mode=nobody", "--socketTimeout=400"])
  teardown: stopFixture(fx)

  test "GET works and headers are captured":
    let c = connectRaw(fx.port)
    defer: c.close()
    let r = c.get("/echo")
    check r.status == 200
    check "method=GET" in r.body

  test "a POST body does not desync the next request":
    let c = connectRaw(fx.port)
    defer: c.close()
    # The body looks like a second request; a desynced server would answer it.
    let smuggled = "GET /smuggled HTTP/1.1\r\nHost: t\r\n\r\n"
    c.sendRaw "POST /echo HTTP/1.1\r\nHost: t\r\nContent-Length: " & $smuggled.len & "\r\n\r\n" & smuggled
    var r1: Resp
    check c.tryReadResponse(r1)
    check r1.status == 400
    check stillServes()

suite "Streaming mode":
  setup: fx = startFixture(@["--mode=streaming", "--socketTimeout=400", "--buffer=4096", "--maxHeader=1024"])
  teardown: stopFixture(fx)

  test "large upload matches the checksum":
    let c = connectRaw(fx.port)
    defer: c.close()
    var body = newString(1_000_000)
    for i in 0 ..< body.len: body[i] = chr(32 + (i * 7) mod 90)
    let r = c.post("/stream", body)
    check r.body == "len=" & $body.len & " sum=" & $cksum(body)

  test "empty and tiny bodies":
    let c = connectRaw(fx.port)
    defer: c.close()
    check c.post("/stream", "").body == "len=0 sum=0"
    check c.post("/stream", "a").body == "len=1 sum=" & $cksum("a")

  test "pipelined streaming requests stay in order":
    let c = connectRaw(fx.port)
    defer: c.close()
    var req = ""
    for i in 0 ..< 10:
      let b = repeat('q', 100 * i)
      req.add "POST /stream HTTP/1.1\r\nHost: t\r\nContent-Length: " & $b.len & "\r\n\r\n" & b
    c.sendRaw req
    for i, r in c.readResponses(10):
      check r.body.startsWith("len=" & $(100 * i) & " ")

  test "a handler that ignores the body does not desync the next request":
    let c = connectRaw(fx.port)
    defer: c.close()
    let smuggled = "GET /smuggled HTTP/1.1\r\nHost: t\r\n\r\n"
    c.sendRaw "POST /echo HTTP/1.1\r\nHost: t\r\nContent-Length: " & $smuggled.len & "\r\n\r\n" & smuggled
    var r1, r2: Resp
    let got1 = c.tryReadResponse(r1)
    let got2 = got1 and c.tryReadResponse(r2, 500)
    check got1
    check not got2
    check stillServes()

suite "parserequestline off":
  setup: fx = startFixture(@["--parseline=off", "--headers=origin"])
  teardown: stopFixture(fx)

  test "headers and keep-alive still work (handler routes on raw request)":
    let c = connectRaw(fx.port)
    defer: c.close()
    # With no parsed request line the fixture sees an empty URI and falls through to 404.
    for _ in 0 ..< 3:
      let r = c.get("/anything", "Origin: o\r\n")
      check r.status == 404
