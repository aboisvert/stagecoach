import std/[unittest, strutils, os, times, tables]
import helpers/fixture

var fx: Fixture

proc stillServes(): bool =
  let c = connectRaw(fx.port)
  defer: c.close()
  var r: Resp
  c.trySend("GET /echo HTTP/1.1\r\nHost: t\r\n\r\n") and c.tryReadResponse(r) and r.status == 200

suite "maxheaderlength":
  setup: fx = startFixture(@["--maxHeader=300", "--buffer=10000", "--socketTimeout=500"])
  teardown: stopFixture(fx)

  test "header exactly at the limit is served, one byte over is dropped":
    let base = "GET /echo HTTP/1.1\r\nX-Pad: "
    let tail = "\r\n\r\n"
    let padFit = 300 - base.len - tail.len
    let c = connectRaw(fx.port)
    defer: c.close()
    c.sendRaw base & repeat('a', padFit) & tail
    check c.readResponse().status == 200
    let c2 = connectRaw(fx.port)
    defer: c2.close()
    discard c2.trySend(base & repeat('a', padFit + 1) & tail)
    check c2.expectClosed()
    check fx.waitStat("close.ProtocolViolated", 1)
    check stillServes()

suite "connection and inflight limits":
  teardown: stopFixture(fx)

  test "connLimit=2: a third connection waits for a free slot":
    fx = startFixture(@["--threads=1", "--connLimit=2", "--socketTimeout=5000"])
    let a = connectRaw(fx.port)
    let b = connectRaw(fx.port)
    defer: a.close(); b.close()
    check a.get("/").status == 200
    check b.get("/").status == 200
    let third = connectRaw(fx.port)
    defer: third.close()
    var r: Resp
    check third.trySend("GET / HTTP/1.1\r\nHost: t\r\n\r\n")
    check not third.tryReadResponse(r, 400)       # parked in the accept backlog
    a.close()
    check third.tryReadResponse(r, 3000)
    check r.status == 200

  test "inflight=2: six concurrent sleeps never exceed two handlers":
    fx = startFixture(@["--threads=1", "--inflight=2"])
    var cs: seq[RawClient]
    for i in 0 ..< 6:
      let c = connectRaw(fx.port)
      cs.add c
      c.sendRaw "GET /sleep?ms=200 HTTP/1.1\r\nHost: t\r\n\r\n"
    for c in cs:
      check c.readResponse(5000).body == "slept"
      c.close()
    check fx.stats()["inflightMax"] == 2

suite "timeouts":
  teardown: stopFixture(fx)

  test "idle keep-alive closes after sockettimeoutms":
    fx = startFixture(@["--socketTimeout=60000", "--idleTimeout=300"])
    let c = connectRaw(fx.port)
    defer: c.close()
    check c.get("/").status == 200
    let t0 = epochTime()
    check c.expectClosed(3000)
    check epochTime() - t0 >= 0.2

  test "slowloris header is cut at requestTimeoutms":
    fx = startFixture(@["--socketTimeout=2000", "--requestTimeout=500"])
    let c = connectRaw(fx.port)
    defer: c.close()
    let t0 = epochTime()
    var alive = true
    for ch in "GET / HTTP/1.1\r\nX-A: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa":
      if not c.trySend($ch):
        alive = false
        break
      sleep(60)
    check (not alive) or c.expectClosed(1500)
    check epochTime() - t0 < 3.5
    check fx.waitStat("close.TimedOut", 1)

  test "slow body is cut at requestTimeoutms":
    fx = startFixture(@["--socketTimeout=2000", "--requestTimeout=500"])
    let c = connectRaw(fx.port)
    defer: c.close()
    check c.trySend("POST /echo HTTP/1.1\r\nHost: t\r\nContent-Length: 100\r\n\r\n")
    for i in 0 ..< 40:
      if not c.trySend("x"): break
      sleep(50)
    check c.expectClosed(1500)
    check fx.waitStat("close.TimedOut", 1)
