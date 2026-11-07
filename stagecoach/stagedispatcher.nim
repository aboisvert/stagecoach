## Runtime plumbing for `serve`: listeners, shutdown pipes, per-request steps.
## Only the handler-dependent glue lives in the `serve` template (flow procs
## need a static call to the handler).

import std/[posix, os, nativesockets, osproc, logging]
import stagelane/core
import stagelane/sched
import stagelane/net
import stagelane/sync
import stagelane/transform
import httpservercore, httprequest
from coachserver import shutdownCallbacks, isShuttingDown, log
export httpservercore

when defined(linux):
  const SO_REUSEPORT = 15

type
  Worker* = object
    connSem*: Semaphore
    inflight*: Semaphore

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
  else:
    listenTcp(port)

proc pokeAllShutdownPipes() {.nimcall, raises: [].} =
  {.cast(gcsafe).}:
    for rt in httpRuntimes:
      for (wfd, _) in rt.shutdownPipes:
        var b: array[1, char] = ['x']
        discard write(wfd, addr b[0], 1)

system.add(shutdownCallbacks, pokeAllShutdownPipes)

const defaultConnLimit* = 1024
const defaultInflightLimit* = 64

proc setupRuntime*(srv: HttpServer, port, nThreads, connLimit, inflightLimit: int): HttpRuntime =
  if srv.maxheaderlength > srv.bufferlength:
    raise newException(ValueError, "maxheaderlength must not exceed bufferlength")
  srv.osThreads = nThreads
  srv.maxConnections = connLimit
  srv.maxInflight = inflightLimit
  srv.port = uint16(port)
  result = HttpRuntime(httpServer: srv)
  for i in 0 ..< nThreads:
    when defined(linux):
      result.listeners.add makeListener(port)
    else:
      if i == 0: result.sharedListener = listenTcp(port)
    var fds: array[2, cint]
    if pipe(fds) != 0:
      raiseOSError(osLastError())
    discard fcntl(fds[0], F_SETFL, O_NONBLOCK)
    result.shutdownPipes.add (fds[1], fds[0])
  httpRuntimes.add result
  srv.runtime = result
  srv.started = true
  srv.log(lvlInfo, "listening on port " & $port & " with " & $nThreads & " OS threads")

proc newWorker*(rt: HttpRuntime, nThreads: int): Worker =
  let s = rt.httpServer
  Worker(
    connSem: newSemaphore(max(1, (s.maxConnections + nThreads - 1) div nThreads)),
    inflight: newSemaphore(max(1, (s.maxInflight + nThreads - 1) div nThreads)))

proc listenerFor*(rt: HttpRuntime, idx: int): TcpListener =
  if idx < rt.listeners.len: rt.listeners[idx] else: rt.sharedListener

proc shutdownAcceptWatcher*(shutdownRfd: cint, victim: typeof(curTask())) {.flow.} =
  while not isShuttingDown():
    waitReadable(shutdownRfd)
    var dummy: array[16, char]
    discard posix.read(shutdownRfd, addr dummy[0], 16)
    break
  cancel(victim)

proc beginRequest*(ctx: HttpContext): bool {.flow.} =
  ## Reads and validates one request (header, request line, Compact body).
  ## Returns false when the connection should be dropped (socket already closed
  ## if that was due to an error).
  let s = ctx.server
  ctx.prepareHttpContext(s)
  if not ctx.readHeader(s):
    return false
  if s.parserequestline and not ctx.parseRequestLine(s):
    return false
  if s.contenttype == ContentType.Compact and not ctx.receiveToSingleBuffer(s):
    return false
  true

proc endRequest*(ctx: HttpContext): bool =
  ## Post-handler bookkeeping: false means "stop serving this connection".
  if ctx.socket == INVALID_SOCKET or isShuttingDown() or not ctx.keepAlive:
    return false
  # A partially consumed Streaming body leaves its unread tail in the socket:
  # keep-alive here would misparse the tail as the next request. (Compact
  # bodies are fully received by beginRequest, so `bodyDelivered` legitimately
  # stays 0 for handlers that use `getBody`.)
  let s = ctx.server
  if s.contenttype == ContentType.Streaming and ctx.bodystart >= 0 and
      ctx.bodyDelivered < ctx.contentlength:
    return false
  ctx.recordCarry(ctx.server)
  true

proc joinRuntime*(srv: HttpServer) =
  let rt = srv.runtime
  if not rt.isNil:
    for i in 0 ..< rt.threads.len:
      joinThread(rt.threads[i])

template serve*(httpSrv: HttpServer, bindPort: int, handler: untyped, osThreads: int = 0,
                connLimit: int = defaultConnLimit, inflightLimit: int = defaultInflightLimit) =
  block:
    let nThreads = if osThreads > 0: osThreads else: max(1, countProcessors())
    let rt = setupRuntime(httpSrv, bindPort, nThreads, connLimit, inflightLimit)

    proc connectionLoop(clientFd: SocketHandle, w: Worker) {.flow.} =
      let ctx = httpSrv.newHttpContext(clientFd)
      try:
        while ctx.beginRequest():
          acquire(w.inflight)
          try:
            handler(ctx)
          finally:
            release(w.inflight)
          if not ctx.endRequest():
            break
      except CancelledError:
        ctx.closeHttpSocket(TimedOut, "cancelled")
      except CatchableError as ex:
        ctx.closeHttpSocket(Excepted, ex.msg)
      finally:
        release(w.connSem)
        ctx.closeHttpSocket(CloseCalled, "")

    proc workerAcceptLoop(runtime: HttpRuntime, workerIdx: int) {.flow.} =
      let s = runtime.httpServer
      let w = newWorker(runtime, nThreads)
      let listener = runtime.listenerFor(workerIdx)
      let acceptLoop = curTask()
      discard go shutdownAcceptWatcher(runtime.shutdownPipes[workerIdx][1], acceptLoop)
      scope conns:
        while not isShuttingDown():
          acquire(w.connSem)
          var stream: TcpStream
          try:
            stream = listener.accept()
          except CancelledError:
            release(w.connSem)
            raise
          except CatchableError as e:
            release(w.connSem)
            s.log(lvlError, "accept: " & e.msg)
            delay(50)             # e.g. EMFILE: don't spin
            continue
          discard conns.go connectionLoop(stream.fd, w)

    proc workerThreadMain(w: WorkerIdx) {.thread.} =
      {.cast(gcsafe).}:
        run workerAcceptLoop(w.runtime, w.idx)

    rt.threads.setLen(nThreads)
    for i in 0 ..< nThreads:
      createThread(rt.threads[i], workerThreadMain, WorkerIdx(runtime: rt, idx: i))

template start*(httpSrv: HttpServer, bindPort: int, handler: untyped, osThreads: int = 0,
                connLimit: int = defaultConnLimit, inflightLimit: int = defaultInflightLimit) =
  serve(httpSrv, bindPort, handler, osThreads, connLimit, inflightLimit)

proc wait*(srv: HttpServer) = joinRuntime(srv)
proc join*(srv: HttpServer) = joinRuntime(srv)
