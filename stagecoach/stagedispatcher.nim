import std/[posix, os, nativesockets, net, osproc, logging]
from std/posix import recv, close, MSG_PEEK
import stagelane/sched
import stagelane/net
import stagelane/sync
import stagelane/transform

when defined(linux):
  const SO_REUSEPORT = 15

type
  HttpRuntime = ref object
    httpServer: HttpServer
    threads: seq[Thread[WorkerIdx]]
    shutdownPipes: seq[(cint, cint)]
    listeners: seq[TcpListener]
    sharedListener: TcpListener
    useReusePort: bool

  WorkerIdx = object
    runtime: HttpRuntime
    idx: int

var httpRuntimes {.global.}: seq[HttpRuntime]

proc makeListener(port: int): TcpListener =
  when defined(linux):
    let fd = createNativeSocket(Domain.AF_INET, SockType.SOCK_STREAM, Protocol.IPPROTO_TCP)
    if fd == osInvalidSocket:
      raiseOSError(osLastError())
    fd.setSockOptInt(SOL_SOCKET, SO_REUSEADDR, 1)
    var one: cint = 1
    discard setsockopt(fd, SOL_SOCKET, cint(SO_REUSEPORT), addr one, SockLen(sizeof(one)))
    var ai = getAddrInfo("0.0.0.0", Port(port), Domain.AF_INET, SockType.SOCK_STREAM, Protocol.IPPROTO_TCP)
    if bindAddr(fd, ai.ai_addr, ai.ai_addrlen.SockLen) < 0:
      freeAddrInfo(ai)
      raiseOSError(osLastError())
    freeAddrInfo(ai)
    if posix.listen(fd, 128.cint) < 0:
      raiseOSError(osLastError())
    fd.setBlocking(false)
    return TcpListener(fd: fd)
  listenTcp(port)

proc pokeAllShutdownPipes() {.nimcall, raises: [].} =
  {.cast(gcsafe).}:
    for rt in httpRuntimes:
      for (wfd, _) in rt.shutdownPipes:
        var b: array[1, char] = ['x']
        discard write(wfd, addr b[0], 1)

proc registerShutdownPipes() {.nimcall.} = pokeAllShutdownPipes()
system.add(shutdownCallbacks, registerShutdownPipes)

const defaultConnLimit = 1024
const defaultInflightLimit = 64

proc storeOsThreadCount(s: HttpServer, n: int) =
  # Outside the serve template so the field name is not substituted.
  s.osThreads = n

template serve*(httpSrv: HttpServer, bindPort: int, handler: untyped, osThreads: int = 0,
                connLimit: int = defaultConnLimit, inflightLimit: int = defaultInflightLimit) =
  block:
    let nThreads = if osThreads > 0: osThreads else: max(1, countProcessors())
    storeOsThreadCount(httpSrv, nThreads)
    httpSrv.maxConnections = connLimit
    httpSrv.maxInflight = inflightLimit
    httpSrv.port = uint16(bindPort)
    var rt = HttpRuntime(
      httpServer: httpSrv,
      useReusePort: when defined(linux): true else: false)
    when defined(linux):
      for i in 0 ..< nThreads:
        let li = makeListener(bindPort)
        let j = rt.listeners.len
        setLen(rt.listeners, j + 1)
        rt.listeners[j] = li
    else:
      rt.sharedListener = listenTcp(bindPort)
    for i in 0 ..< nThreads:
      var fds: array[2, cint]
      if pipe(fds) != 0:
        raiseOSError(osLastError())
      discard fcntl(fds[0], F_SETFL, O_NONBLOCK)
      block:
        let j = rt.shutdownPipes.len
        setLen(rt.shutdownPipes, j + 1)
        rt.shutdownPipes[j] = (fds[1], fds[0])
    block:
      let j = httpRuntimes.len
      setLen(httpRuntimes, j + 1)
      httpRuntimes[j] = rt
    httpSrv.runtime = cast[pointer](rt)
    httpSrv.started = true
    httpSrv.log(lvlInfo, "listening on port " & $bindPort & " with " & $nThreads & " OS threads")

    proc connectionLoop(clientFd: SocketHandle, connSem, inflight: Semaphore) {.flow.} =
      let s = httpSrv
      let ctx = s.newHttpContext(clientFd)
      try:
        while ctx.keepAlive and not shuttingdown:
          ctx.prepareHttpContext(s)
          if not ctx.readHeader(s):
            break
          acquire(inflight)
          try:
            if s.parserequestline and not ctx.parseRequestLine(s):
              break
            case s.contenttype
            of NoBody:
              discard
            of Compact:
              if ctx.contentlength > s.bufferlength:
                closeSocket(s, ctx.socket, ProtocolViolated, "content-length too large")
                break
              if not ctx.receiveToSingleBuffer(s):
                break
            of Streaming:
              discard
            handler(ctx)
          finally:
            release(inflight)
          if shuttingdown: break
          var probe = [0.char]
          let r = recv(ctx.socket, addr probe[0], 1, MSG_PEEK or MSG_DONTWAIT)
          if r <= 0:
            let e = osLastError().int
            if r == 0 or e notin [EAGAIN.int, EWOULDBLOCK.int]:
              break
            waitReadable(int(ctx.socket))
      except CancelledError:
        closeSocket(s, ctx.socket, TimedOut, "cancelled")
      except CatchableError as ex:
        closeSocket(s, ctx.socket, Excepted, ex.msg)
      finally:
        release(connSem)
        if ctx.socket != INVALID_SOCKET:
          discard posix.close(ctx.socket)

    proc workerAcceptLoop(runtime: HttpRuntime, workerIdx: int) {.flow.} =
      let s = runtime.httpServer
      let perConn = max(1, (s.maxConnections + nThreads - 1) div nThreads)
      let perInflight = max(1, (s.maxInflight + nThreads - 1) div nThreads)
      let connSem = newSemaphore(perConn)
      let inflight = newSemaphore(perInflight)
      let listener =
        if runtime.useReusePort and workerIdx < runtime.listeners.len:
          runtime.listeners[workerIdx]
        else:
          runtime.sharedListener
      let shutdownRfd = runtime.shutdownPipes[workerIdx][1]
      scope conns:
        while not shuttingdown:
          if shutdownRfd >= 0:
            var dummy: array[16, char]
            if posix.read(shutdownRfd, addr dummy[0], 16) > 0:
              break
          acquire(connSem)
          try:
            let stream = listener.accept()
            let clientFd = stream.fd
            discard conns.go connectionLoop(clientFd, connSem, inflight)
          except CatchableError:
            release(connSem)

    proc workerThreadMain(w: WorkerIdx) {.thread.} =
      {.cast(gcsafe).}:
        run workerAcceptLoop(w.runtime, w.idx)

    rt.threads.setLen(nThreads)
    for i in 0 ..< nThreads:
      createThread(rt.threads[i], workerThreadMain, WorkerIdx(runtime: rt, idx: i))

template start* = serve
template join* = wait

template wait*(srv: HttpServer) =
  block:
    let rt = cast[HttpRuntime](srv.runtime)
    if not rt.isNil:
      for i in 0 ..< rt.threads.len:
        joinThread(rt.threads[i])
