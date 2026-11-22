## Socket I/O on a real io_uring. Run with -d:stagecoachRingTest on Linux.
when defined(linux) and defined(stagecoachRingTest):
  import std/[unittest, nativesockets, posix, os, strutils]
  import stagelane/[sched, uring]
  import stagecoach/[flow, httpserver, socketio]
  import ../helpers/pairs

  doAssert ringEnable(), "io_uring is required for this test"

  proc ringPair(): Pair =
    let server = newHttpServer(loglevel = lvlError)
    server.sockettimeoutms = 500
    server.idleTimeoutms = 500
    result = newPair(server)
    result.ctx.socket.setBlocking(true)
    result.ctx.ringIo = true

  proc exchange(p: Pair): string {.flow.} =
    let writer = go peerScript(p.peer, @["hello"], 0)
    var buf: array[16, char]
    let n = p.ctx.recvSome(addr buf[0], buf.len)
    for i in 0 ..< max(n, 0): result.add buf[i]
    waitDone(writer)
    let reply = "world"
    if p.ctx.sendSome(unsafeAddr reply[0], reply.len, 0) != Complete:
      result.add "/send failed"

  proc readUntilCancelled(ctx: HttpContext): bool {.flow.} =
    var buf: array[8, char]
    try:
      discard ctx.recvSome(addr buf[0], buf.len)
    except CancelledError:
      return true
    false

  proc cancelRead(ctx: HttpContext): bool {.flow.} =
    let reader = go readUntilCancelled(ctx)
    yieldNow()
    cancel(reader)
    await(reader)

  proc idleRead(ctx: HttpContext): bool {.flow.} =
    var buf: array[8, char]
    let n = ctx.recvSome(addr buf[0], buf.len)
    n == 0 and ctx.idleExpired

  proc receiveError(ctx: HttpContext): SocketCloseCause {.flow.} =
    let n = ctx.recvSome(nil, 1)
    var cause = CloseCalled
    var msg = ""
    discard classifyRecv(n, cause, msg)
    cause

  proc receiveEof(ctx: HttpContext): int {.flow.} =
    var buf: array[1, char]
    ctx.recvSome(addr buf[0], buf.len)

  proc sendUntilTimeout(ctx: HttpContext): bool {.flow.} =
    let payload = newString(8_000_000)
    try:
      discard ctx.sendSome(unsafeAddr payload[0], payload.len, 0)
    except CancelledError:
      return true
    false

  proc drainBytes(fd: SocketHandle, expected: int): int {.flow.} =
    fd.setBlocking(false)
    var buf: array[65536, char]
    while result < expected:
      let n = recv(fd, addr buf[0], buf.len, 0)
      if n > 0:
        result += n
      elif n < 0 and posix.errno in [EAGAIN, EWOULDBLOCK]:
        waitReadable(int(fd))
      else:
        break

  proc sendLarge(p: Pair): bool {.flow.} =
    let payload = newString(8_000_000)
    let reader = go drainBytes(p.peer, payload.len)
    let status = p.ctx.sendSome(unsafeAddr payload[0], payload.len, 0)
    let received = await(reader)
    status == Complete and received == payload.len

  proc delayedDrain(fd: SocketHandle, expected: int): int {.flow.} =
    delay(50)
    drainBytes(fd, expected)

  proc fileWithSlowReader(p: Pair, path: string, expected: int): bool {.flow.} =
    var ticked = false
    let timer = addTimer(20, proc () {.closure.} = ticked = true)
    let reader = go delayedDrain(p.peer, expected)
    let sent = p.ctx.replyFile(path)
    let received = await(reader)
    cancel(timer)
    sent and ticked and received >= expected

  proc sendFile(ctx: HttpContext, path: string): bool {.flow.} =
    ctx.replyFile(path)

  proc replyThenClose(ctx: HttpContext) {.flow.} =
    ctx.holdWrites = true
    ctx.reply("bye")
    ctx.closeHttpSocket()

  proc waitOnPipe(fd: cint) {.flow.} =
    waitReadable(int(fd))

  proc childReplyThenClose(ctx: HttpContext) {.flow.} =
    var fds: array[2, cint]
    doAssert pipe(fds) == 0
    let watcher = go waitOnPipe(fds[0])
    let child = go replyThenClose(ctx)
    waitDone(child)
    cancel(watcher)
    waitDone(watcher)
    discard posix.close(fds[0])
    discard posix.close(fds[1])

  proc truncateLater(path: string) {.flow.} =
    delay(10)
    writeFile(path, "")

  proc drainUntilClose(fd: SocketHandle) {.flow.} =
    delay(50)
    fd.setBlocking(false)
    var buf: array[65536, char]
    while true:
      let n = recv(fd, addr buf[0], buf.len, 0)
      if n > 0: continue
      if n < 0 and posix.errno in [EAGAIN, EWOULDBLOCK]:
        waitReadable(int(fd))
      else:
        break

  proc truncatedFile(p: Pair, path: string): bool {.flow.} =
    let truncator = go truncateLater(path)
    let reader = go drainUntilClose(p.peer)
    let sent = p.ctx.replyFile(path)
    waitDone(truncator)
    waitDone(reader)
    not sent and p.ctx.socket == INVALID_SOCKET

  suite "io_uring socket I/O":
    test "an epoll socket stays on epoll after the ring is enabled":
      var p = newPair(newHttpServer(loglevel = lvlError))
      let reads = ringTestReads
      let writes = ringTestWrites
      check (run exchange(p)) == "hello"
      check peerRecvAll(p.peer) == "world"
      check ringTestReads == reads
      check ringTestWrites == writes
      p.ctx.closeHttpSocket()
      p.closePeer()

    test "reads and writes through the ring":
      var p = ringPair()
      let reads = ringTestReads
      let writes = ringTestWrites
      check (run exchange(p)) == "hello"
      check peerRecvAll(p.peer) == "world"
      check ringTestReads > reads
      check ringTestWrites > writes
      p.ctx.closeHttpSocket()
      p.closePeer()

    test "cancellation completes before the read buffer is released":
      var p = ringPair()
      check (run cancelRead(p.ctx))
      p.ctx.closeHttpSocket()
      p.closePeer()

    test "idle timeout interrupts a pending ring read":
      var p = ringPair()
      p.ctx.server.idleTimeoutms = 50
      check (run idleRead(p.ctx))
      p.ctx.closeHttpSocket()
      p.closePeer()

    test "completion errors are mapped to the socket close cause":
      var p = ringPair()
      peerSend(p.peer, "x")
      check (run receiveError(p.ctx)) == EFault
      p.ctx.closeHttpSocket()
      p.closePeer()

    test "peer close returns EOF":
      var p = ringPair()
      p.closePeer()
      check (run receiveEof(p.ctx)) == 0
      p.ctx.closeHttpSocket()

    test "a blocked send respects the socket timeout":
      var p = ringPair()
      p.ctx.server.sockettimeoutms = 50
      check (run sendUntilTimeout(p.ctx))
      p.ctx.closeHttpSocket()
      p.closePeer()

    test "partial sends eventually deliver the whole buffer":
      var p = ringPair()
      p.ctx.server.sockettimeoutms = 3000
      let writes = ringTestWrites
      check (run sendLarge(p))
      check ringTestWrites > writes + 1
      p.ctx.closeHttpSocket()
      p.closePeer()

    test "a slow file response does not block the worker":
      let path = getTempDir() / "stagecoach-ring-slow-file"
      writeFile(path, newString(8_000_000))
      var p = ringPair()
      p.ctx.server.sockettimeoutms = 3000
      check (run fileWithSlowReader(p, path, 8_000_000))
      p.ctx.closeHttpSocket()
      p.closePeer()
      removeFile(path)

    test "a file response preserves headers and body":
      let path = getTempDir() / "stagecoach-ring-small-file"
      writeFile(path, "file-bytes")
      var p = ringPair()
      check (run sendFile(p.ctx, path))
      let wire = peerRecvAll(p.peer)
      check "Content-Length: 10\r\n" in wire
      check wire.endsWith("\r\n\r\nfile-bytes")
      p.ctx.closeHttpSocket()
      p.closePeer()
      removeFile(path)

    test "closing flushes a held reply before closing the socket":
      var p = ringPair()
      run childReplyThenClose(p.ctx)
      check peerRecvAll(p.peer).endsWith("\r\n\r\nbye")
      check p.ctx.socket == INVALID_SOCKET
      p.closePeer()

    test "a truncated file closes the incomplete response":
      let path = getTempDir() / "stagecoach-ring-truncated-file"
      writeFile(path, newString(8_000_000))
      var p = ringPair()
      p.ctx.server.sockettimeoutms = 3000
      check (run truncatedFile(p, path))
      p.closePeer()
      removeFile(path)

else:
  when isMainModule:
    echo "Run on Linux with -d:stagecoachRingTest to exercise io_uring"
