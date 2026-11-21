## Socket readiness behavior independent of the scheduler's internal latches.
import std/unittest
import stagelane/sched
import stagecoach/[flow, httpserver, socketio]
import ../helpers/pairs

proc watchPair(p: Pair) =
  # Accepted sockets are watched by recent stagelane; socketpairs are not.
  when declared(watchFd):
    watchFd(int(p.ctx.socket))

proc readByte(ctx: HttpContext): string {.flow.} =
  var ch: char
  let n = ctx.recvSome(addr ch, 1)
  if n == 1: result.add ch

proc sendLater(fd: SocketHandle, data: string) {.flow.} =
  yieldNow()
  peerSend(fd, data)

proc readAfterDrain(p: Pair): string {.flow.} =
  peerSend(p.peer, "a")
  result = p.ctx.readByte()
  let writer = go sendLater(p.peer, "b")
  result.add p.ctx.readByte()
  waitDone(writer)

proc cancelRead(p: Pair): bool {.flow.} =
  let reader = go p.ctx.readByte()
  yieldNow()
  cancel(reader)
  waitDone(reader)
  cancelled(reader)

proc exerciseReusedSockets(): bool {.flow.} =
  for i in 0 ..< 20:
    var p = newPair(newHttpServer(loglevel = lvlError))
    watchPair(p)
    let writer = go sendLater(p.peer, "x")
    let got = p.ctx.readByte()
    waitDone(writer)
    p.ctx.closeHttpSocket()
    p.closePeer()
    if got != "x": return false
  true

proc boundedRead(p: Pair): string {.flow.} =
  withTimeout(1000, readAfterDrain(p))

proc boundedCancel(p: Pair): bool {.flow.} =
  withTimeout(1000, cancelRead(p))

proc boundedReuse(): bool {.flow.} =
  withTimeout(3000, exerciseReusedSockets())

suite "socket readiness":
  test "a drained socket wakes for later data":
    var p = newPair(newHttpServer(loglevel = lvlError))
    watchPair(p)
    check (run boundedRead(p)) == "ab"
    p.ctx.closeHttpSocket()
    p.closePeer()

  test "a parked read can be cancelled":
    var p = newPair(newHttpServer(loglevel = lvlError))
    watchPair(p)
    check (run boundedCancel(p))
    p.ctx.closeHttpSocket()
    p.closePeer()

  test "closed descriptors can be reused":
    check (run boundedReuse())

when isMainModule:
  echo "Readiness tests finished"
