when defined(linux):
  import std/[unittest, posix, nativesockets]
  import stagecoach/flow
  import stagelane/sched
  proc waitReadFlow(p: PollFd) {.flow.} =
    pioWaitRead(p)

  proc parkOnRead(p: PollFd, parked: ptr bool) {.flow.} =
    waitReadFlow(p)
    parked[] = true

  suite "PollFd latch":
    test "read readiness clears after a short recv":
      var fds: array[2, cint]
      check socketpair(AF_UNIX, SOCK_STREAM, 0, fds) == 0
      let a = fds[0]
      let b = fds[1]
      var pf = pioOpen(b)
      pioWaitRead(pf)                 # both bits start set
      let msg = "x"
      discard send(SocketHandle(a), unsafeAddr msg[0], msg.len, 0.cint)
      pioWaitRead(pf)
      var buf: array[8, char]
      let r = recv(SocketHandle(b), addr buf[0], buf.len, 0.cint)
      check r == 1
      pf.rdReady = false
      var parked = false
      let t = go parkOnRead(pf, addr parked)
      delay(30)
      check not parked
      cancel(t)
      discard posix.close(a)
      pioClose(pf)
      discard posix.close(b)
else:
  import std/unittest
  suite "PollFd latch":
    test "skipped on non-Linux":
      check true

when isMainModule:
  echo "PollFd tests finished"
