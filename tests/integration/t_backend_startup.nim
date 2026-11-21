## Backend selection and startup failure. Run on Linux with
## -d:stagecoachBackendTest and an explicit backend.
when defined(linux) and defined(stagecoachBackendTest):
  import std/[unittest, atomics, os, strutils, net]
  when defined(stagecoachRingTest):
    import std/posix
  when defined(stagecoachTestEnableRingInHandler):
    import stagelane/uring
  import stagecoach/[flow, httpserver, socketio]
  import ../helpers/fixture

  proc handle(ctx: HttpContext) {.flow.} =
    when defined(stagecoachTestEnableRingInHandler):
      doAssert ringEnable()
    when defined(stagecoachRingTest):
      let writes = ringTestWrites
      if ctx.ringIo:
        doAssert ringTestReads > 0
        doAssert (fcntl(ctx.socket.cint, F_GETFL) and O_NONBLOCK) == 0
    if ctx.getUri() == "/file":
      discard ctx.replyFile(getTempDir() / "stagecoach-backend-test-file")
      when defined(stagecoachRingTest):
        if ctx.ringIo: doAssert ringTestWrites > writes
      return
    ctx.reply(if ctx.ringIo: "ring" else: "readiness")
    when defined(stagecoachRingTest):
      if ctx.ringIo:
        doAssert ctx.flushSendBuf() == Complete
        doAssert ringTestWrites > writes

  var server: HttpServer
  var fallbackLogs: Atomic[int]

  proc recordLog(level: Level, source, message: string) {.gcsafe, nimcall, raises: [].} =
    if "io_uring unavailable" in message:
      discard fallbackLogs.fetchAdd(1, moRelaxed)

  proc countFds(): int =
    for _ in walkDir("/proc/self/fd"):
      inc result

  proc canBind(port: int): bool =
    let socket = newSocket()
    try:
      socket.setSockOpt(OptReuseAddr, true)
      socket.bindAddr(Port(port), "127.0.0.1")
      result = true
    except OSError:
      result = false
    finally:
      socket.close()

  proc startServer(port: int) =
    when defined(stagecoachTestEnableRingInHandler):
      serve(server, port, handle, osThreads = 1)
    else:
      serve(server, port, handle, osThreads = 2)

  suite "worker I/O backend":
    when defined(stagecoachIoUring) and
        (defined(stagecoachTestRingUnavailable) or defined(stagecoachTestRingFailOne)):
      test "required ring failure is reported and releases the listener":
        let port = freePort()
        server = newHttpServer(loglevel = lvlError)
        let before = countFds()
        var failed = false
        try:
          startServer(port)
        except CatchableError:
          failed = true
        if not server.runtime.isNil:
          stop(server, 0)
          wait(server)
        check failed
        check not server.started
        check server.runtime.isNil
        check countFds() == before
        check canBind(port)
    else:
      test "the selected backend handles an HTTP request":
        let port = freePort()
        let path = getTempDir() / "stagecoach-backend-test-file"
        let expectedFile = repeat("stagecoach", 20_000)
        writeFile(path, expectedFile)
        defer: removeFile(path)
        server = newHttpServer(loglevel = lvlWarn)
        server.logCallback = recordLog
        fallbackLogs.store(0, moRelaxed)
        when defined(stagecoachRingTest) and not defined(stagecoachReadiness):
          let workersBefore = ringTestWorkerCount.load(moRelaxed)
        startServer(port)
        let client = connectRaw(port)
        let response = client.get("/", "Connection: close\r\n")
        client.close()
        when defined(stagecoachIoUring):
          check response.body == "ring"
        elif defined(stagecoachReadiness) or defined(stagecoachTestRingUnavailable) or
            defined(stagecoachTestExpectReadiness):
          check response.body == "readiness"
        elif defined(stagecoachRingTest):
          check response.body == "ring"
        else:
          check response.body in ["ring", "readiness"]
        let fileClient = connectRaw(port)
        check fileClient.get("/file", "Connection: close\r\n").body == expectedFile
        fileClient.close()
        when defined(stagecoachTestEnableRingInHandler):
          for _ in 0 ..< 5:
            let next = connectRaw(port)
            check next.get("/", "Connection: close\r\n").body == "readiness"
            next.close()
        when (defined(stagecoachTestRingUnavailable) or defined(stagecoachTestExpectReadiness)) and
            not defined(stagecoachReadiness):
          check fallbackLogs.load(moRelaxed) == 2
        when defined(stagecoachRingTest) and not defined(stagecoachReadiness):
          check ringTestWorkerCount.load(moRelaxed) - workersBefore == 2
        stop(server, 0)
        wait(server)

      test "repeated start and stop release worker descriptors":
        let before = countFds()
        for _ in 0 ..< 5:
          let port = freePort()
          server = newHttpServer(loglevel = lvlError)
          startServer(port)
          stop(server, 0)
          wait(server)
        check countFds() == before

else:
  when isMainModule:
    echo "Run on Linux with -d:stagecoachBackendTest to test backend startup"
