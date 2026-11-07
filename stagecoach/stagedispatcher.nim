## Runtime plumbing for `serve`: listeners, shutdown pipes, per-request steps.
## Only the handler-dependent glue lives in the `serve` template (flow procs
## need a static call to the handler).
##
## Worker thread layout (per worker):
##   workerMain
##   ├── acceptLoop      owns `listener.accept()`; spawns into `conns`
##   ├── acceptWatcher   wakes on the runtime's stop pipe; cancels acceptLoop
##   └── conns (Scope)   every accepted connection's task
## stop() pokes the pipes; acceptLoop exits; workerMain lets connection tasks
## finish naturally for `drainms` and force-cancels whatever is left.

import std/[posix, os, nativesockets, osproc, logging, atomics]
import stagelane/core
import stagelane/sched
import stagelane/net
import stagelane/sync
import stagelane/transform
import httpservercore, httprequest, socketio
from coachserver import shutdownCallbacks, isShuttingDown, log
export httpservercore

when defined(linux):
  const SO_REUSEPORT = 15

type
  CtxPool* = ref object
    ## Per-worker reuse pool for `HttpContext` objects. Lives on exactly one
    ## worker's event loop: pop on accept, push back in `connectionLoop`'s
    ## finally, never shared across threads.
    ctxs*: seq[HttpContext]
    cap*: int

  Worker* = object
    connSem*: Semaphore
    inflight*: Semaphore
    pool*: CtxPool

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

proc setNoDelay(fd: SocketHandle) =
  ## Disable Nagle so chunked/small replies are not held back on platforms
  ## without MSG_MORE (e.g. macOS) by the delayed-ACK interaction.
  var one: cint = 1
  discard posix.setsockopt(fd, posix.IPPROTO_TCP, posix.TCP_NODELAY, addr one, SockLen(sizeof(one)))

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
  ## Builds the runtime for one `serve` call. Re-runnable: a previous run's
  ## resources are torn down again in `wait`.
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
  let permits = max(1, (s.maxConnections + nThreads - 1) div nThreads)
  Worker(
    connSem: newSemaphore(permits),
    inflight: newSemaphore(max(1, (s.maxInflight + nThreads - 1) div nThreads)),
    pool: CtxPool(cap: permits))

proc listenerFor*(rt: HttpRuntime, idx: int): TcpListener =
  if idx < rt.listeners.len: rt.listeners[idx] else: rt.sharedListener

proc acceptWatcher*(shutdownRfd: cint, victim: TaskBase) {.flow.} =
  ## Wakes once on a write to this worker's shutdown pipe, then cancels the
  ## accept loop so it stops blocking on `listener.accept()`. Connection tasks
  ## are NOT cancelled here: the worker's drain logic owns them.
  if not isShuttingDown():
    waitReadable(shutdownRfd)
    var dummy: array[16, char]
    discard posix.read(shutdownRfd, addr dummy[0], 16)
  cancel(victim)

proc beginRequest*(ctx: HttpContext): bool {.flow.} =
  ## Reads and validates one request (header, request line, Compact body).
  ## Returns false when the connection should be dropped (socket already closed
  ## if that was due to an error).
  let s = ctx.server
  if not serverIsOpen(s):
    return false
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
  if ctx.socket == INVALID_SOCKET or not serverIsOpen(ctx.server) or not ctx.keepAlive:
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

proc stop*(srv: HttpServer, drainms = 10_000) =
  ## Stop this server (not the process): stop accepting, then let connection
  ## tasks finish for `drainms` milliseconds; whatever is still alive after
  ## that window is force-cancelled (0 = cancel immediately). Callers block on
  ## `wait(srv)` to join the worker threads.
  let rt = srv.runtime
  if rt.isNil or rt.stopping.load(moRelaxed):
    return
  rt.drainms = drainms
  rt.stopping.store(true, moRelease)
  for (wfd, _) in rt.shutdownPipes:
    var b: array[1, char] = ['x']
    discard write(wfd, addr b[0], 1)

proc teardownRuntime(srv: HttpServer) =
  ## Frees the runtime's descriptors and registry entry after its threads
  ## joined. Makes the same `HttpServer` reusable with a fresh `serve` call.
  let rt = srv.runtime
  if rt.isNil:
    return
  for (wfd, rfd) in rt.shutdownPipes:
    discard posix.close(wfd)
    discard posix.close(rfd)
  for l in rt.listeners:
    discard posix.close(l.fd)
  if not rt.sharedListener.isNil:
    discard posix.close(rt.sharedListener.fd)
  for i, cand in httpRuntimes:
    if cand == rt:
      httpRuntimes.delete(i)
      break
  srv.runtime = nil
  srv.started = false

proc joinRuntime*(srv: HttpServer) =
  let rt = srv.runtime
  if not rt.isNil:
    for i in 0 ..< rt.threads.len:
      joinThread(rt.threads[i])
    teardownRuntime(srv)

template serve*(httpSrv: HttpServer, bindPort: int, handler: untyped, osThreads: int = 0,
                connLimit: int = defaultConnLimit, inflightLimit: int = defaultInflightLimit) =
  block:
    let nThreads = if osThreads > 0: osThreads else: max(1, countProcessors())
    let rt = setupRuntime(httpSrv, bindPort, nThreads, connLimit, inflightLimit)

    proc connectionLoop(clientFd: SocketHandle, w: Worker) {.flow.} =
      var ctx: HttpContext
      # Reuse: a pooled context keeps its buffers/wanted list for this server;
      # beginRequest runs prepareHttpContext per request anyway.
      if w.pool.ctxs.len > 0:
        ctx = w.pool.ctxs.pop()
        ctx.socket = clientFd
      else:
        ctx = httpSrv.newHttpContext(clientFd)
      if httpSrv.nodelay:
        setNoDelay(clientFd)
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
        ctx.closeHttpSocket(Cancelled, "cancelled")
      except CatchableError as ex:
        ctx.closeHttpSocket(Excepted, ex.msg)
      finally:
        release(w.connSem)
        ctx.closeHttpSocket(CloseCalled, "")
        if w.pool.ctxs.len < w.pool.cap:
          ctx.carryLen = 0        # half-consumed pipelined bytes die with the conn
          ctx.carryStart = 0
          w.pool.ctxs.add ctx

    proc acceptLoop(rt: HttpRuntime, workerIdx: int, w: Worker, conns: Scope) {.flow.} =
      let s = rt.httpServer
      let listener = rt.listenerFor(workerIdx)
      while not isShuttingDown() and not serverIsStopping(s):
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

    proc workerMain(rt: HttpRuntime, workerIdx: int, w: Worker) {.flow.} =
      let conns = newScope()    # explicit: survives acceptLoop's cancellation
      let acceptTask = go acceptLoop(rt, workerIdx, w, conns)
      let watcherTask = go acceptWatcher(rt.shutdownPipes[workerIdx][1], acceptTask)
      waitDone(acceptTask)
      # Graceful path: stop() or a process signal cancelled the accept loop.
      # Bound how long lingering connection tasks may keep draining. `drainms`
      # on the runtime defaults to 0 = cancel the leftovers immediately (the
      # signal path); stop(drainms) sets the window explicitly.
      if rt.stopping.load(moRelaxed) or isShuttingDown():
        waitDone(watcherTask)
        let drain = rt.drainms
        if drain > 0:
          discard addTimer(drain, proc () {.closure.} =
            {.cast(gcsafe).}: conns.cancel())
        else:
          conns.cancel()
      joinQuiet(conns)

    proc workerThreadMain(w: WorkerIdx) {.thread.} =
      {.cast(gcsafe).}:
        let worker = newWorker(w.runtime, w.nThreads)
        run workerMain(w.runtime, w.idx, worker)

    rt.threads.setLen(nThreads)
    for i in 0 ..< nThreads:
      createThread(rt.threads[i], workerThreadMain, WorkerIdx(runtime: rt, idx: i, nThreads: nThreads))

template start*(httpSrv: HttpServer, bindPort: int, handler: untyped, osThreads: int = 0,
                connLimit: int = defaultConnLimit, inflightLimit: int = defaultInflightLimit) =
  serve(httpSrv, bindPort, handler, osThreads, connLimit, inflightLimit)

proc wait*(srv: HttpServer) = joinRuntime(srv)
proc join*(srv: HttpServer) = joinRuntime(srv)
