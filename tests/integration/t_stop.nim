import std/[unittest, net, os, posix, strutils, times]
import stagecoach/[flow, httpserver]

const testPort = 18091

proc handle(ctx: HttpContext) {.flow.} =
  ctx.reply("hit")

# The server object lives in a module-level var: `{.thread.}` procs are
# nimcall and the serve template's flow machinery cannot capture locals from
# them, but globals are fine.
var gsrv: HttpServer

proc serveForever {.thread.} =
  {.cast(gcsafe).}:
    serve(gsrv, testPort, handle, osThreads = 1)
    wait(gsrv)

proc waitForPort(pollMs = 5000) =
  let deadline = epochTime() + pollMs.float / 1000.0
  while epochTime() < deadline:
    try:
      var s = newSocket()
      s.connect("127.0.0.1", Port(testPort))
      s.close()
      return
    except OSError:
      sleep(25)
  doAssert false, "server did not come up on port " & $testPort

proc portIsRefused(): bool =
  var s = newSocket()
  try:
    s.connect("127.0.0.1", Port(testPort))
    s.close()
    false
  except OSError:
    true

proc roundTrip(marker: string = "200"): bool =
  var c = newSocket()
  try:
    c.connect("127.0.0.1", Port(testPort))
    c.send("GET / HTTP/1.1\c\LHost: t\c\L\c\L")
    result = marker in c.recvLine(timeout = 2000)
  except OSError:
    result = false
  finally:
    c.close()

suite "per-server stop":
  teardown:
    discard

  test "stop joins threads, frees the port, and the server restarts":
    gsrv = newHttpServer(loglevel = lvlError)
    gsrv.sockettimeoutms = 250          # idle connections notice quickly
    var th, th2: Thread[void]
    createThread(th, serveForever)
    waitForPort()
    check roundTrip()

    # Keep an idle keep-alive connection so the drain window has work to do.
    var idle = newSocket()
    idle.connect("127.0.0.1", Port(testPort))
    idle.send("GET / HTTP/1.1\c\LHost: t\c\L\c\L")
    discard idle.recvLine(timeout = 2000)

    stop(gsrv, drainms = 1500)
    joinThread(th)
    check portIsRefused()

    # The same server object must be reusable.
    createThread(th2, serveForever)
    waitForPort()
    check roundTrip()
    stop(gsrv, drainms = 1500)
    joinThread(th2)
    check portIsRefused()

when isMainModule:
  echo "Stop tests finished"
