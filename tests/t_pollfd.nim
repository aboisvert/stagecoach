when defined(linux):
  import std/[unittest, posix, nativesockets]
  import stagelane/sched
  import helpers/pairs

  suite "PollFd latch":
    test "read readiness clears after a short recv":
      var fds: array[2, cint]
      check socketpair(AF_UNIX, SOCK_STREAM, 0, fds) == 0
      let a = fds[0]
      let b = fds[1]
      var pf = pioOpen(b)
      check pioWaitRead(pf)           # both bits start set
      let msg = "x"
      discard send(a, unsafeAddr msg[0], msg.len, 0)
      check pioWaitRead(pf)
      var buf: array[8, char]
      let r = recv(b, addr buf[0], buf.len, 0)
      check r == 1
      pf.rdReady = false
      var parked = false
      let t = go:
        pioWaitRead(pf)
        parked = true
      delay(30)
      check not parked
      cancel(t)
      joinAll([t], 1000)
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
