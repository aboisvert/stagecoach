import std/[strutils, strtabs, monotimes, times]
import std/logging
import stagelane/core
import stagelane/transform
import httpservercore
import socketio
from coachserver import SocketCloseCause, isShuttingDown
export socketio

# --- byte helpers -----------------------------------------------------------

proc bytesEq(buf: string, start: int64, s: string): bool {.inline.} =
  if s.len == 0: return true
  start >= 0 and start + s.len <= buf.len and equalMem(unsafeAddr buf[start], unsafeAddr s[0], s.len)

proc eqLower(buf: string, start, len: int, lowerName: string): bool {.inline.} =
  if len != lowerName.len: return false
  for i in 0 ..< len:
    if buf[start + i].toLowerAscii() != lowerName[i]: return false
  true

# --- request line -----------------------------------------------------------

proc isTchar(c: char): bool {.inline.} =
  ## RFC 7230 token character.
  c in {'!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~'} or
      c in {'0' .. '9'} or c.isAlphaAscii()

proc parseMethod*(ctx: HttpContext): bool =
  if unlikely(ctx.requestlen < 13):
    ctx.closeHttpSocket(ProtocolViolated, "too short request")
    return false
  while ctx.methlen < ctx.requestlen and ctx.request[ctx.methlen] != ' ':
    ctx.methlen.inc
  if unlikely(ctx.methlen == ctx.requestlen):
    ctx.closeHttpSocket(ProtocolViolated, "http method missing")
    return false
  # The whole method must be a valid token: accepts standard and extension
  # methods (REPORT, LOCK, QUERY, ...) and rejects non-token bytes.
  for i in 0 ..< ctx.methlen.int:
    if not ctx.request[i].isTchar():
      ctx.closeHttpSocket(ProtocolViolated, "invalid http method")
      return false
  true

proc parseRequestLine*(ctx: HttpContext, server: HttpServer): bool =
  if not ctx.parseMethod():
    return false
  var i = ctx.methlen + 1
  let start = i
  while i < ctx.requestlen and ctx.request[i] != ' ':
    i.inc
  ctx.uristart = start
  ctx.urilen = i - start
  if unlikely(ctx.urilen == 0):
    ctx.closeHttpSocket(ProtocolViolated, "empty request target")
    return false
  let ver = ctx.uristart + ctx.urilen + 1
  if unlikely(ctx.requestlen < ver + 8):
    ctx.closeHttpSocket(ProtocolViolated, "parseRequestLine: no version")
    return false
  if unlikely(not ctx.request.bytesEq(ver, "HTTP/1.") or ctx.request[ver + 7] notin {'0', '1'} or
      ctx.request[ver + 8] != '\c'):
    ctx.closeHttpSocket(ProtocolViolated, "request not HTTP/1.x")
    return false
  ctx.http10 = ctx.request[ver + 7] == '0'
  server.log(lvlDebug, $server.port & "/" & $ctx.socket & ": " &
    ctx.request[0 ..< ver + 8])
  true

# --- headers ----------------------------------------------------------------

proc isHeaderreceived*(ctx: HttpContext, previouslen, currentlen: int): bool =
  if currentlen < 4:
    return false
  var i = if previouslen > 4: previouslen - 4 else: 0
  while i <= currentlen - 4:
    if ctx.request[i] == '\c' and ctx.request[i + 1] == '\l' and ctx.request[i + 2] == '\c' and
        ctx.request[i + 3] == '\l':
      ctx.bodystart = i + 4
      return true
    inc i
  false

proc hasConnToken(value: string, token: string): bool {.inline.} =
  ## True when a comma-separated Connection list contains `token`.
  for t in value.split(','):
    if strip(t, leading = true, trailing = true) == token:
      return true
  false

proc parseHeaders*(ctx: HttpContext): bool =
  ## Line-based scan that stores only the header names in `ctx.wanted`.
  ## The first occurrence of a wanted header wins. Requires `ctx.bodystart`
  ## to be set (header block complete).
  ## Returns false and closes the socket when a header line is not
  ## CRLF-terminated or when a wanted header name occurs more than once
  ## (duplicate framing/identity headers are a request-smuggling primitive).
  let hdrEnd = ctx.bodystart - 2          # points at the blank line's CR
  var i = 0
  while i < hdrEnd and ctx.request[i] != '\l':   # skip the request line
    inc i
  inc i
  var seen = 0                            # bitmask: wanted names already matched
  while i < hdrEnd:
    var eol = i
    while eol < hdrEnd and ctx.request[eol] != '\l':
      inc eol
    var lineEnd = eol
    if lineEnd > i and ctx.request[lineEnd - 1] == '\c':
      dec lineEnd
    else:
      ctx.closeHttpSocket(ProtocolViolated, "header line not CRLF-terminated")
      return false
    var colon = i
    while colon < lineEnd and ctx.request[colon] != ':':
      inc colon
    if colon < lineEnd:
      var nameEnd = colon
      while nameEnd > i and ctx.request[nameEnd - 1] in {' ', '\t'}:
        dec nameEnd
      if nameEnd != colon:
        # RFC 7230 3.2.4: whitespace before the colon is a smuggling vector.
        ctx.closeHttpSocket(ProtocolViolated, "whitespace before header colon")
        return false
      for wi in 0 ..< ctx.wanted.len:
        let w = ctx.wanted[wi]
        if eqLower(ctx.request, i, nameEnd - i, w):
          let bit = 1 shl wi
          if (seen and bit) != 0:
            ctx.closeHttpSocket(ProtocolViolated, "duplicate header field: " & w)
            return false
          seen = seen or bit
          var vs = colon + 1
          while vs < lineEnd and ctx.request[vs] in {' ', '\t'}:
            inc vs
          var ve = lineEnd
          while ve > vs and ctx.request[ve - 1] in {' ', '\t'}:
            dec ve
          ctx.headers[w] = ctx.request[vs ..< ve]
          break
    i = eol + 1
  true

proc requestLineIsHttp10(ctx: HttpContext): bool =
  var e = 0
  while e < ctx.bodystart and ctx.request[e] != '\c':
    inc e
  e >= 8 and ctx.request[e - 8 ..< e] == "HTTP/1.0"

proc processHeaders*(ctx: HttpContext, server: HttpServer): bool =
  ## Validates framing headers (Content-Length, Transfer-Encoding) and decides
  ## keep-alive. Closes the socket and returns false on a protocol violation.
  if not ctx.parseHeaders():
    return false
  if ctx.headers["transfer-encoding"].len > 0:
    ctx.closeHttpSocket(ProtocolViolated, "transfer-encoding not supported")
    return false
  block framing:
    let raw = ctx.headers["content-length"]
    if raw.len > 0:
      var n: int64
      try:
        for c in raw:
          if c notin {'0' .. '9'}: raise newException(ValueError, "digit")
        n = parseBiggestInt(raw)
      except ValueError:
        ctx.closeHttpSocket(ProtocolViolated, "non-parseable content-length")
        return false
      if n < 0:
        ctx.closeHttpSocket(ProtocolViolated, "negative content-length")
        return false
      if server.contenttype == ContentType.NoBody and n > 0:
        # No body is ever read, so its bytes would be parsed as the next request.
        ctx.closeHttpSocket(ProtocolViolated, "request body not accepted (NoBody server)")
        return false
      if server.contenttype == ContentType.Compact and n > server.bufferlength + 1 - ctx.bodystart:
        ctx.closeHttpSocket(ProtocolViolated, "content-length exceeds buffer")
        return false
      ctx.contentlength = n
  let http10 = ctx.requestLineIsHttp10()
  ctx.http10 = http10
  let conn = ctx.headers["connection"].toLowerAscii()
  # RFC 7230 §6.6: `close` wins over `keep-alive` when both tokens appear.
  ctx.keepAlive = if http10:
      hasConnToken(conn, "keep-alive") and not hasConnToken(conn, "close")
    else:
      not hasConnToken(conn, "close")
  true

# --- accessors --------------------------------------------------------------

proc getUri*(ctx: HttpContext): string =
  if ctx.urilen == 0:
    return ""
  ctx.request[ctx.uristart ..< ctx.uristart + ctx.urilen]

proc isUri*(ctx: HttpContext, uri: string): bool =
  ctx.urilen == uri.len and ctx.request.bytesEq(ctx.uristart, uri)

proc startsUri*(ctx: HttpContext, uristart: string): bool =
  ctx.urilen >= uristart.len and ctx.request.bytesEq(ctx.uristart, uristart)

proc getMethod*(ctx: HttpContext): string =
  if ctx.methlen == 0:
    return ""
  ctx.request[0 ..< ctx.methlen]

proc isMethod*(ctx: HttpContext, amethod: string): bool =
  ctx.methlen == amethod.len and ctx.request.bytesEq(0, amethod)

proc bodyEnd*(ctx: HttpContext): int64 {.inline.} =
  ## End offset (exclusive) of this request's body inside `ctx.request`;
  ## never includes bytes of a following pipelined request.
  if ctx.bodystart < 0: ctx.requestlen
  else: ctx.bodystart + min(ctx.contentreceived, max(ctx.contentlength, 0))

proc getBody*(ctx: HttpContext): string =
  if ctx.bodystart < 0:
    return ""
  ctx.request[ctx.bodystart ..< ctx.bodyEnd]

proc isBody*(ctx: HttpContext, body: string): bool =
  ctx.bodystart >= 0 and ctx.bodyEnd - ctx.bodystart == body.len and
    ctx.request.bytesEq(ctx.bodystart, body)

proc getRequest*(ctx: HttpContext): string =
  ctx.request[0 ..< ctx.requestlen]

# --- per-request state ------------------------------------------------------

proc prepareHttpContext*(ctx: HttpContext, server: HttpServer) =
  if ctx.carryLen > 0:
    moveMem(addr ctx.request[0], addr ctx.request[ctx.carryStart], ctx.carryLen.int)
    ctx.requestlen = ctx.carryLen
    ctx.carryLen = 0
    ctx.carryStart = 0
  else:
    ctx.requestlen = 0
  ctx.contentlength = 0
  ctx.uristart = 0
  ctx.urilen = 0
  ctx.methlen = 0
  ctx.bodystart = -1
  ctx.contentreceived = 0
  ctx.bodyDelivered = 0
  ctx.bodyClockSet = false
  ctx.keepAlive = true
  ctx.http10 = false
  for key in ctx.wanted:
    ctx.headers[key].setLen(0)

proc recordCarry*(ctx: HttpContext, server: HttpServer) =
  let reqEnd = ctx.bodyEnd
  if ctx.requestlen > reqEnd:
    ctx.carryLen = ctx.requestlen - reqEnd
    ctx.carryStart = reqEnd
  else:
    ctx.carryLen = 0
    ctx.carryStart = 0

# --- receiving --------------------------------------------------------------

proc timedOut(server: HttpServer, t0: MonoTime): bool {.inline.} =
  server.requestTimeoutms > 0 and (getMonoTime() - t0).inMilliseconds > server.requestTimeoutms

proc receiveHeader*(ctx: HttpContext, server: HttpServer): bool {.flow.} =
  var t0 = getMonoTime()
  var started = ctx.requestlen > 0      # the clock starts at the first byte
  while true:
    if not serverIsOpen(server):
      return false
    let limit = min(1 + server.maxheaderlength, ctx.request.len.int64)
    let maxRead = (limit - ctx.requestlen).int
    if maxRead <= 0:
      ctx.closeHttpSocket(ProtocolViolated, "maximum allowed header size exceeded")
      return false
    let prev = ctx.requestlen.int
    let ret = ctx.recvSome(addr ctx.request[ctx.requestlen], maxRead)
    if ret <= 0 and ctx.checkRecv(ret) == Fail:
      return false
    if not started:
      started = true
      t0 = getMonoTime()
    ctx.requestlen += ret
    if ctx.isHeaderreceived(prev, ctx.requestlen.int):
      if ctx.bodystart > server.maxheaderlength:
        ctx.closeHttpSocket(ProtocolViolated, "maximum allowed header size exceeded")
        return false
      return true
    if ctx.requestlen > server.maxheaderlength:
      ctx.closeHttpSocket(ProtocolViolated, "maximum allowed header size exceeded")
      return false
    if timedOut(server, t0):
      ctx.closeHttpSocket(TimedOut, "request header too slow")
      return false

proc readHeader*(ctx: HttpContext, server: HttpServer): bool {.flow.} =
  if ctx.bodystart < 0 and ctx.requestlen >= 4:
    discard ctx.isHeaderreceived(0, ctx.requestlen.int)     # carried bytes
  if ctx.bodystart < 0 and not ctx.receiveHeader(server):
    return false
  ctx.contentreceived = ctx.requestlen - ctx.bodystart
  if not ctx.processHeaders(server):
    return false
  # Body bytes already on the wire when framing became known start the
  # per-request body-receive clock (see readBodyChunk/receiveToSingleBuffer).
  if ctx.contentreceived > 0:
    ctx.bodyClock = getMonoTime()
    ctx.bodyClockSet = true
  if server.contenttype == ContentType.Compact:
    let cap = ctx.bodystart + ctx.contentlength + 1
    if ctx.request.len < cap:
      ctx.request.setLen(cap)
  true

proc receiveToSingleBuffer*(ctx: HttpContext, server: HttpServer): bool {.flow.} =
  if ctx.contentreceived >= ctx.contentlength:
    return true
  if not ctx.bodyClockSet:
    ctx.bodyClock = getMonoTime()
    ctx.bodyClockSet = true
  while ctx.contentreceived < ctx.contentlength:
    if not serverIsOpen(server):
      return false
    let need = ctx.contentlength - ctx.contentreceived
    let position = ctx.bodystart + ctx.contentreceived
    let ret = ctx.recvSome(addr ctx.request[position], need.int)
    if ret <= 0 and ctx.checkRecv(ret) == Fail:
      return false
    ctx.contentreceived += ret
    ctx.requestlen = ctx.bodystart + ctx.contentreceived
    if ctx.contentreceived < ctx.contentlength and timedOut(server, ctx.bodyClock):
      ctx.closeHttpSocket(TimedOut, "request body too slow")
      return false
  true

proc readBodyChunk*(ctx: HttpContext, server: HttpServer): (SocketState, string) {.flow.} =
  if ctx.contentlength == 0:
    return (Complete, "")
  let avail = min(ctx.contentreceived, ctx.contentlength)
  if ctx.bodyDelivered < avail:
    let start = ctx.bodystart + ctx.bodyDelivered
    let n = avail - ctx.bodyDelivered
    let chunk = ctx.request[start ..< start + n]
    ctx.bodyDelivered = avail
    if avail >= ctx.contentlength:
      return (Complete, chunk)
    return (Progress, chunk)
  if avail >= ctx.contentlength:
    return (Complete, "")
  if not serverIsOpen(server):
    return (Fail, "")
  if ctx.streamScratch.len == 0:
    ctx.streamScratch = newString(server.bufferlength.int)
  if not ctx.bodyClockSet:
    ctx.bodyClock = getMonoTime()
    ctx.bodyClockSet = true
  let need = ctx.contentlength - ctx.contentreceived
  let recvsize = min(need, ctx.streamScratch.len.int64).int
  let ret = ctx.recvSome(addr ctx.streamScratch[0], recvsize)
  if ret <= 0 and ctx.checkRecv(ret) == Fail:
    return (Fail, "")
  ctx.contentreceived += ret
  ctx.bodyDelivered += ret
  let chunk = ctx.streamScratch[0 ..< ret]
  if ctx.contentreceived >= ctx.contentlength:
    return (Complete, chunk)
  # A dribbling client (1 byte just under sockettimeoutms apart) would never
  # trip the per-op waits: the total body-receive time is the bound here.
  if timedOut(server, ctx.bodyClock):
    ctx.closeHttpSocket(TimedOut, "request body too slow")
    return (Fail, "")
  (Progress, chunk)
