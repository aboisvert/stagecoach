## Stagelane scheduler resources must be released when a worker exits.
when defined(linux) and defined(stagecoachRingTest):
  import std/[os, posix, unittest, atomics]
  import stagelane/[core, sched, transform, uring]

  static: doAssert declared(stagecoachSchedCleanup)

  var drainCalls: Atomic[int]

  proc onDrain() {.nimcall.} =
    discard drainCalls.fetchAdd(1, moRelaxed)

  proc wakePeer(fd: cint) {.flow.} =
    yieldNow()
    var b = 'x'
    discard posix.write(fd, addr b, 1)

  proc exerciseWatchedFd() {.flow.} =
    var fds: array[2, cint]
    doAssert socketpair(AF_UNIX, SOCK_STREAM, 0, fds) == 0
    discard fcntl(fds[0], F_SETFL, O_NONBLOCK)
    watchFd(int(fds[0]))
    var b: char
    doAssert posix.read(fds[0], addr b, 1) < 0
    let writer = go wakePeer(fds[1])
    waitReadable(int(fds[0]))
    waitDone(writer)
    forgetFd(int(fds[0]))
    discard posix.close(fds[0])
    discard posix.close(fds[1])

  proc ringWorker() {.thread.} =
    {.cast(gcsafe).}:
      doAssert ringEnable(), "io_uring is required for this test"
      run exerciseWatchedFd()
      registerDrain(onDrain)
      releaseSched()

  proc countFds(): int =
    for _ in walkDir("/proc/self/fd"):
      inc result

  suite "worker scheduler cleanup":
    test "repeated ring workers do not leak descriptors":
      let before = countFds()
      let drainsBefore = drainCalls.load(moRelaxed)
      for _ in 0 ..< 10:
        var worker: Thread[void]
        createThread(worker, ringWorker)
        joinThread(worker)
      check countFds() == before
      check drainCalls.load(moRelaxed) - drainsBefore == 10
else:
  when isMainModule:
    echo "Run on Linux with -d:stagecoachRingTest to check scheduler cleanup"
