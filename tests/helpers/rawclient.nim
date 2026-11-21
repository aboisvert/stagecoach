## Blocking raw HTTP client for tests: scripted sends (optionally split) and
## minimal response parsing (Content-Length or chunked framing).

import std/[net, strutils, os, times, nativesockets, posix]

signal(SIGPIPE, SIG_IGN)

type
  RawClient* = ref object
    sock*: Socket
    buf: string          ## bytes received but not yet consumed

  Resp* = object
    status*: int
    reason*: string
    headers*: seq[(string, string)]
    body*: string
    chunked*: bool

proc connectRaw*(port: int): RawClient =
  result = RawClient(sock: newSocket())
  result.sock.connect("127.0.0.1", Port(port))
  result.sock.setSockOpt(OptNoDelay, true, level = cint(IPPROTO_TCP))
  result.sock.getFd().setBlocking(false)

proc close*(c: RawClient) =
  try: c.sock.close() except CatchableError: discard

proc trySend*(c: RawClient, data: string, timeoutMs = 5000): bool =
  ## False when the server already closed/reset the connection (or the send
  ## stalls). Uses a non-blocking fd: a blocking send on a reset connection
  ## can wedge on macOS.
  let fd = c.sock.getFd()
  let deadline = epochTime() + timeoutMs / 1000
  var sent = 0
  while sent < data.len:
    let r = posix.send(fd, unsafeAddr data[sent], data.len - sent, 0)
    if r > 0:
      sent += r
      continue
    if r < 0 and (errno == EAGAIN or errno == EWOULDBLOCK or errno == EINTR):
      let left = int((deadline - epochTime()) * 1000)
      if left <= 0: return false
      var pfd = TPollfd(fd: cint(fd), events: POLLOUT)
      discard poll(addr pfd, 1, cint(left))
      continue
    return false
  true

proc sendRaw*(c: RawClient, data: string) =
  doAssert c.trySend(data), "send failed (connection closed?)"

proc sendSplit*(c: RawClient, data: string, sizes: openArray[int], delayMs = 0): bool =
  ## Sends `data` in pieces of the given sizes (the last size repeats).
  var pos = 0
  var i = 0
  while pos < data.len:
    let n = min(sizes[min(i, sizes.high)], data.len - pos)
    if not c.trySend(data[pos ..< pos + n]): return false
    pos += n
    inc i
    if delayMs > 0 and pos < data.len: sleep(delayMs)
  true

proc recvPartial(c: RawClient, timeoutMs: int, eof: var bool): string =
  ## Returns whatever is readable within the timeout ("" on timeout); sets
  ## `eof` on orderly close or reset.
  let fd = c.sock.getFd()
  var pfd = TPollfd(fd: cint(fd), events: POLLIN)
  eof = false
  let n = poll(addr pfd, 1, cint(max(timeoutMs, 0)))
  if n <= 0: return ""
  var buf = newString(65536)
  let r = posix.recv(fd, addr buf[0], buf.len, 0)
  if r <= 0:
    eof = true
    return ""
  buf.setLen(r)
  buf

proc fill(c: RawClient, deadline: float): bool =
  ## Reads more bytes; false on EOF/reset/timeout.
  let left = int((deadline - epochTime()) * 1000)
  if left <= 0: return false
  var eof: bool
  let s = c.recvPartial(left, eof)
  if s.len == 0: return false
  c.buf.add s
  true

proc takeLine(c: RawClient, deadline: float, line: var string): bool =
  while true:
    let p = c.buf.find("\r\n")
    if p >= 0:
      line = c.buf[0 ..< p]
      c.buf = c.buf[p + 2 .. ^1]
      return true
    if not c.fill(deadline): return false

proc takeBytes(c: RawClient, deadline: float, n: int, dest: var string): bool =
  while c.buf.len < n:
    if not c.fill(deadline): return false
  dest.add c.buf[0 ..< n]
  c.buf = c.buf[n .. ^1]
  true

proc header*(r: Resp, name: string): string =
  for (k, v) in r.headers:
    if cmpIgnoreCase(k, name) == 0: return v

proc tryReadResponse*(c: RawClient, resp: var Resp, timeoutMs = 3000): bool =
  ## False if the connection ended (or timed out) before a complete response.
  let deadline = epochTime() + timeoutMs / 1000
  resp = Resp()
  var line = ""
  if not c.takeLine(deadline, line): return false
  let parts = line.split(' ', 2)
  if parts.len < 2 or not parts[0].startsWith("HTTP/"): return false
  resp.status = parseInt(parts[1])
  resp.reason = if parts.len > 2: parts[2] else: ""
  while true:
    if not c.takeLine(deadline, line): return false
    if line.len == 0: break
    let colon = line.find(':')
    resp.headers.add (line[0 ..< colon], line[colon + 1 .. ^1].strip())
  if cmpIgnoreCase(resp.header("transfer-encoding"), "chunked") == 0:
    resp.chunked = true
    while true:
      if not c.takeLine(deadline, line): return false
      let n = parseHexInt(line.split(';')[0].strip())
      if n == 0:
        if not c.takeLine(deadline, line): return false    # final CRLF
        break
      if not c.takeBytes(deadline, n, resp.body): return false
      if not c.takeLine(deadline, line): return false
  else:
    let cl = resp.header("content-length")
    if cl.len > 0 and not c.takeBytes(deadline, parseInt(cl), resp.body): return false
  true

proc readResponse*(c: RawClient, timeoutMs = 3000): Resp =
  doAssert c.tryReadResponse(result, timeoutMs), "no complete response (buffered: " & c.buf & ")"

proc readResponses*(c: RawClient, n: int, timeoutMs = 5000): seq[Resp] =
  for _ in 0 ..< n: result.add c.readResponse(timeoutMs)

proc expectClosed*(c: RawClient, timeoutMs = 2000): bool =
  ## True when the peer closes (EOF or reset) within the timeout. Bytes that
  ## still arrive are discarded.
  let deadline = epochTime() + timeoutMs / 1000
  while true:
    let left = int((deadline - epochTime()) * 1000)
    if left <= 0: return false
    var eof: bool
    discard c.recvPartial(left, eof)
    if eof: return true

proc get*(c: RawClient, uri: string, extra = ""): Resp =
  c.sendRaw "GET " & uri & " HTTP/1.1\r\nHost: t\r\n" & extra & "\r\n"
  c.readResponse()

proc post*(c: RawClient, uri, body: string, extra = ""): Resp =
  c.sendRaw "POST " & uri & " HTTP/1.1\r\nHost: t\r\nContent-Length: " & $body.len &
    "\r\n" & extra & "\r\n" & body
  c.readResponse()
