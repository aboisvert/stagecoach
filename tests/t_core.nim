import std/[unittest, strtabs, posix, strutils, sequtils, atomics]
import stagecoach/httpserver

type Logged = tuple[level: Level, msg: string]
var logged: seq[Logged]
var closed: seq[(SocketCloseCause, string)]

proc captureLog(level: Level, source: string, message: string) {.gcsafe, nimcall, raises: [].} =
  {.cast(gcsafe).}: logged.add (level, message)

proc captureClose(server: StagecoachServer, socket: SocketHandle, cause: SocketCloseCause, msg: string) {.gcsafe, nimcall, raises: [].} =
  {.cast(gcsafe).}: closed.add (cause, msg)

proc fresh(lvl = lvlAll, ct = Compact, fields: openArray[string] = []): HttpServer =
  logged.setLen(0)
  closed.setLen(0)
  result = HttpServer()
  result.logCallback = captureLog
  result.initHttpServer(lvl, true, ct, fields)
  result.onCloseSocketCallback = captureClose

proc openFd(): SocketHandle =
  var fds: array[2, cint]
  doAssert socketpair(AF_UNIX, SOCK_STREAM, 0, fds) == 0
  discard posix.close(fds[1])
  SocketHandle(fds[0])

suite "server defaults":
  test "defaults from newHttpServer":
    let s = newHttpServer(loglevel = lvlError)
    check s.maxheaderlength == 10000
    check s.bufferlength == 100000
    check s.sockettimeoutms == 5000
    check s.idleTimeoutms == 30000
    check s.requestTimeoutms == 30000
    check s.contenttype == Compact
    check s.parserequestline
    check s.nodelay
    check s.backlog == 4096
    check s.runtime.isNil
    check not s.started

  test "server ids are distinct":
    check newHttpServer().id != newHttpServer().id

  test "uppercase headerfields are rejected":
    expect ValueError:
      discard newHttpServer(headerfields = ["Origin"])
    discard newHttpServer(headerfields = ["x-custom-1"])

  test "more than 60 requested header fields are rejected":
    # parseHeaders tracks seen wanted names in a 64-bit mask; 60 user fields
    # plus the 4 always-tracked framing headers fill it exactly.
    var fields: seq[string]
    for i in 0 ..< 61: fields.add "x-f-" & $i
    expect ValueError:
      discard newHttpServer(headerfields = fields)
    fields.setLen(60)
    discard newHttpServer(headerfields = fields)
    # the limit counts list entries (dedup happens later), so a list whose
    # unique count is lower still has to fit the entry bound itself
    var withFraming: seq[string] = fields[0 ..< 59] & "connection"
    discard newHttpServer(headerfields = withFraming)

  test "stop is a no-op before serve":
    let s = fresh()
    stop(s)
    check not serverIsStopping(s)
    check serverIsOpen(s)

suite "context wanted set":
  test "framing headers are always tracked":
    for ct in [NoBody, Compact, Streaming]:
      let c = fresh(ct = ct).newHttpContext(INVALID_SOCKET)
      for f in ["connection", "transfer-encoding", "content-length"]:
        check f in c.wanted
        check c.headers.hasKey(f)

  test "requested headers are added once":
    let c = fresh(fields = ["origin", "content-length"]).newHttpContext(INVALID_SOCKET)
    check c.wanted.count("content-length") == 1
    check "origin" in c.wanted

  test "initial buffer is header-sized, not buffer-sized":
    let s = fresh()
    let c = s.newHttpContext(INVALID_SOCKET)
    check c.request.len == int(s.maxheaderlength) + 1
    s.maxheaderlength = 50
    s.bufferlength = 20
    check s.newHttpContext(INVALID_SOCKET).request.len == 21

suite "logging":
  test "log filters by level":
    let s = fresh(lvl = lvlWarn)
    s.log(lvlInfo, "hidden")
    s.log(lvlWarn, "shown")
    s.log(lvlError, "shown too")
    check logged.len == 2

  test "logClose maps causes to levels":
    let s = fresh()
    let expected = {CloseCalled: lvlDebug, Cancelled: lvlDebug, AlreadyClosed: lvlDebug,
      ClosedbyClient: lvlDebug, ConnectionLost: lvlInfo, TimedOut: lvlInfo,
      ProtocolViolated: lvlNotice, NetErrored: lvlNotice, SecurityThreatened: lvlWarn,
      Excepted: lvlError, EFault: lvlError}
    for (cause, lvl) in expected:
      logged.setLen(0)
      s.logClose(SocketHandle(7), cause, "m")
      check logged.len == 1
      check logged[0].level == lvl
      check ($cause) in logged[0].msg

suite "closing":
  test "closeSocket is a no-op on INVALID_SOCKET":
    let s = fresh()
    s.closeSocket(INVALID_SOCKET, ProtocolViolated, "x")
    check closed.len == 0

  test "closeSocket invokes the callback with cause and message":
    let s = fresh()
    s.closeSocket(openFd(), TimedOut, "slow")
    check closed == @[(TimedOut, "slow")]

  test "closeHttpSocket fires once and invalidates the context":
    let s = fresh()
    let c = s.newHttpContext(openFd())
    c.closeHttpSocket(ProtocolViolated, "a")
    c.closeHttpSocket(ProtocolViolated, "b")
    check closed.len == 1
    check c.socket == INVALID_SOCKET

suite "classifyRecv":
  var cause: SocketCloseCause
  var msg: string

  test "positive is progress":
    check classifyRecv(5, cause, msg) == Progress

  test "zero is a client close":
    check classifyRecv(0, cause, msg) == Fail
    check cause == ClosedbyClient

  test "errno mapping for negative results":
    for (e, st, expectedCause) in [
        (EAGAIN, SocketState.TryAgain, CloseCalled), (EWOULDBLOCK, SocketState.TryAgain, CloseCalled),
        (EINTR, SocketState.TryAgain, CloseCalled),
        (EBADF, Fail, AlreadyClosed), (ECONNRESET, Fail, ClosedbyClient),
        (EPIPE, Fail, ConnectionLost), (EFAULT, Fail, EFault), (EIO, Fail, NetErrored)]:
      cause = CloseCalled
      posix.errno = e
      check classifyRecv(-1, cause, msg) == st
      if st == Fail: check cause == expectedCause

  test "shutdown takes priority over everything":
    shutdown()
    check classifyRecv(5, cause, msg) == Fail
    check cause == CloseCalled
    shuttingdown.store(false)

when isMainModule:
  echo "Core tests finished"
