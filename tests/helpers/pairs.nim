## In-process helpers: an HttpContext over a socketpair, driven by a scripted
## peer running as a task on the same stagelane event loop.

import std/[posix, nativesockets]
import stagecoach/[flow, httpserver]
import stagelane/sched

type Pair* = object
  ctx*: HttpContext
  peer*: SocketHandle

proc setNoSigpipe(fd: SocketHandle) =
  when defined(macosx):
    var one: cint = 1
    discard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, addr one, SockLen(sizeof(one)))

proc newPair*(server: HttpServer): Pair =
  var fds: array[2, cint]
  doAssert socketpair(AF_UNIX, SOCK_STREAM, 0, fds) == 0
  let a = SocketHandle(fds[0])
  let b = SocketHandle(fds[1])
  a.setBlocking(false)
  setNoSigpipe(a)
  setNoSigpipe(b)
  Pair(ctx: server.newHttpContext(a), peer: b)

proc closePeer*(p: var Pair) =
  if p.peer != INVALID_SOCKET:
    discard posix.close(p.peer)
    p.peer = INVALID_SOCKET

proc peerSend*(fd: SocketHandle, data: string) =
  ## Blocking send from the peer end (ignores a closed server end).
  var sent = 0
  while sent < data.len:
    let r = send(fd, unsafeAddr data[sent], data.len - sent, 0)
    if r <= 0: return
    sent += r

proc peerRecvAll*(fd: SocketHandle): string =
  ## Non-blocking drain of everything currently readable on the peer end.
  fd.setBlocking(false)
  var buf: array[4096, char]
  while true:
    let r = recv(fd, addr buf[0], buf.len, 0)
    if r <= 0: break
    for i in 0 ..< r: result.add buf[i]
  fd.setBlocking(true)

proc peerScript*(fd: SocketHandle, chunks: seq[string], gapMs: int) {.flow.} =
  ## Sends each chunk, sleeping `gapMs` between them.
  for i, c in chunks:
    if i > 0 and gapMs > 0: delay(gapMs)
    peerSend(fd, c)

type BeginResult* = enum brFalse, brTrue, brCancelled

proc driveBegin*(ctx: HttpContext, peer: SocketHandle, chunks: seq[string], gapMs: int): BeginResult {.flow.} =
  ## beginRequest while a peer task feeds `chunks`.
  let t = go peerScript(peer, chunks, gapMs)
  try:
    result = if ctx.beginRequest(): brTrue else: brFalse
  except CancelledError:
    result = brCancelled
  cancel(t)

proc waitPeerDone(t: TaskBase) {.flow.} = waitDone(t)
