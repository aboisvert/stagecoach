import std/[unittest, posix, net]
import helpers/fixture
import stagecoach/httpserver

suite "process shutdown":
  test "/stop exits quickly with idle keep-alive and slow in-flight connections":
    let fx = startFixture(@["--socketTimeout=5000"], second = true)
    defer: stopFixture(fx)
    let idle = connectRaw(fx.port)
    check idle.get("/").status == 200
    let slow = connectRaw(fx.port)
    slow.sendRaw "GET /sleep?ms=3000 HTTP/1.1\r\nHost: t\r\n\r\n"
    let stopper = connectRaw(fx.port)
    discard stopper.get("/stop")
    check fx.waitExit(3000)
    check not portOpen(fx.port)
    check not portOpen(fx.port2)       # second server in the same process stopped too
    idle.close(); slow.close(); stopper.close()

  test "SIGTERM exits cleanly":
    let fx = startFixture(@[])
    defer: stopFixture(fx)
    let idle = connectRaw(fx.port)
    check idle.get("/").status == 200
    fx.signal(SIGTERM)
    check fx.waitExit(3000)
    check not portOpen(fx.port)
    idle.close()

  test "SIGINT exits cleanly":
    let fx = startFixture(@[])
    defer: stopFixture(fx)
    fx.signal(SIGINT)
    check fx.waitExit(3000)
    check not portOpen(fx.port)

  test "serve rejects maxheaderlength > bufferlength":
    let s = newHttpServer(loglevel = lvlError)
    s.maxheaderlength = 200_000
    expect ValueError:
      discard setupRuntime(s, freePort(), 1, 8, 4)
