import std/[strutils, strtabs, monotimes, times]
import std/logging
import stagelane/core
import stagelane/transform
import httpservercore
import socketio
import httpcore
import httpresponse
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
  # 13 == "X / HTTP/1.0\c": the shortest byte run that can possibly contain a
  # full request line up to its CR, so anything shorter is 400 without a scan.
  if unlikely(ctx.requestlen < 13):
    ctx.reject(Http400, ProtocolViolated, "too short request")
    return false
  while ctx.methlen < ctx.requestlen and ctx.request[ctx.methlen] != ' ':
    ctx.methlen.inc
  if unlikely(ctx.methlen == ctx.requestlen):
    ctx.reject(Http400, ProtocolViolated, "http method missing")
    return false
  # The whole method must be a valid token: accepts standard and extension
  # methods (REPORT, LOCK, QUERY, ...) and rejects non-token bytes.
  for i in 0 ..< ctx.methlen.int:
    if not ctx.request[i].isTchar():
      ctx.reject(Http400, ProtocolViolated, "invalid http method")
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
    ctx.reject(Http400, ProtocolViolated, "empty request target")
    return false
  let ver = ctx.uristart + ctx.urilen + 1
  if unlikely(ctx.requestlen < ver + 8):
    ctx.reject(Http400, ProtocolViolated, "parseRequestLine: no version")
    return false
  if unlikely(not ctx.request.bytesEq(ver, "HTTP/1.") or ctx.request[ver + 7] notin {'0', '1'} or
      ctx.request[ver + 8] != '\c'):
    ctx.reject(Http400, ProtocolViolated, "request not HTTP/1.x")
    return false
  ctx.http10 = ctx.request[ver + 7] == '0'
  server.log(lvlDebug, $server.port & "/" & $ctx.socket & ": " &
    ctx.request[0 ..< ver + 8])
  true

# --- headers ----------------------------------------------------------------

proc isHeaderreceived*(ctx: HttpContext, previouslen, currentlen: int): bool =
  ## True at the first `\c\l\c\l`. Resumes 4 bytes before `previouslen`
  ## so a terminator straddling the previous scan's end is still seen.
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

proc hasTokenIn(buf: string, start, len: int, token: string): bool =
  ## Case-insensitive search for `token` in a comma-separated list held in
  ## `buf[start ..< start+len]`, without allocating.
  var i = start
  let e = start + len
  while i <= e:
    var j = i
    while j < e and buf[j] != ',': inc j
    var a = i
    var z = j
    while a < z and buf[a] in {' ', '\t'}: inc a
    while z > a and buf[z - 1] in {' ', '\t'}: dec z
    if eqLower(buf, a, z - a, token): return true
    i = j + 1
  false

proc headerFieldSlice(ctx: HttpContext, name: string): string {.inline.} =
  let wi = ctx.wanted.find(name)
  if wi < 0: return ""
  let st = ctx.headerStart[wi].int64
  let ln = ctx.headerLen[wi].int64
  if ln <= 0: return ""
  ctx.request[st ..< st + ln]

proc headerValue*(ctx: HttpContext, name: string): string =
  ## `name` must be lower-case and listed in `headerfields` (or be a framing header).
  headerFieldSlice(ctx, name)

proc headerSpan*(ctx: HttpContext, name: string): HttpSpan =
  let wi = ctx.wanted.find(name)
  if wi < 0: return HttpSpan()
  HttpSpan(start: ctx.headerStart[wi].int64, len: ctx.headerLen[wi].int64)

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
  # 64-bit mask: at most 64 wanted names (60 user fields + 4 framing headers),
  # enforced by newHttpServer; a wider mask would need per-name bookkeeping.
  var seen: uint64 = 0                    # bitmask: wanted names already matched
  while i < hdrEnd:
    var eol = i
    while eol < hdrEnd and ctx.request[eol] != '\l':
      inc eol
    var lineEnd = eol
    if lineEnd > i and ctx.request[lineEnd - 1] == '\c':
      dec lineEnd
    else:
      ctx.reject(Http400, ProtocolViolated, "header line not CRLF-terminated")
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
        ctx.reject(Http400, ProtocolViolated, "whitespace before header colon")
        return false
      for wi in 0 ..< ctx.wanted.len:
        let w = ctx.wanted[wi]
        if eqLower(ctx.request, i, nameEnd - i, w):
          let bit = 1'u64 shl wi
          if (seen and bit) != 0:
            # Only framing/identity headers are a smuggling risk; for other
            # requested headers the first occurrence wins.
            if w in ["content-length", "transfer-encoding", "connection", "expect", "host"]:
              ctx.reject(Http400, ProtocolViolated, "duplicate header field: " & w)
              return false
            break
          seen = seen or bit
          var vs = colon + 1
          while vs < lineEnd and ctx.request[vs] in {' ', '\t'}:
            inc vs
          var ve = lineEnd
          while ve > vs and ctx.request[ve - 1] in {' ', '\t'}:
            dec ve
          ctx.headerStart[wi] = vs.int32
          ctx.headerLen[wi] = (ve - vs).int32
          # Internal framing headers are read from spans; only user-requested
          # fields (listed first in `wanted`) are copied into the table.
          if wi < ctx.userFields:
            ctx.headers[w] = ctx.request[vs ..< ve]
          break
    i = eol + 1
  true

proc requestLineIsHttp10(ctx: HttpContext): bool =
  ## Scans the raw bytes for the version, independent of parseRequestLine:
  ## framing/keep-alive must see HTTP/1.0 even with `parserequestline = false`.
  var e = 0
  while e < ctx.bodystart and ctx.request[e] != '\c':
    inc e
  e >= 8 and ctx.request[e - 8 ..< e] == "HTTP/1.0"

proc processHeaders*(ctx: HttpContext, server: HttpServer): bool =
  ## Validates framing headers (Content-Length, Transfer-Encoding) and decides
  ## keep-alive. Closes the socket and returns false on a protocol violation.
  ctx.headOnly = ctx.requestlen >= 5 and ctx.request.bytesEq(0, "HEAD ")
  if not ctx.parseHeaders():
    return false
  if ctx.headerLen[ctx.wantedIdx.te] > 0:
    ctx.reject(Http501, ProtocolViolated, "transfer-encoding not supported")
    return false
  let ei = ctx.wantedIdx.expect
  if ctx.headerLen[ei] > 0 and not ctx.request.hasTokenIn(ctx.headerStart[ei], ctx.headerLen[ei], "100-continue"):
    # Any expectation other than 100-continue is rejected before reading a body.
    ctx.reject(Http417, ProtocolViolated, "expectation failed")
    return false
  block framing:
    let ci = ctx.wantedIdx.cl
    if ctx.headerLen[ci] > 0:
      var n: int64
      var bad = false
      for k in 0 ..< ctx.headerLen[ci].int:
        let c = ctx.request[ctx.headerStart[ci].int + k]
        # stop before the 10n + digit multiply can overflow int64
        if c notin {'0' .. '9'} or n > (high(int64) - 9) div 10:
          bad = true
          break
        n = n * 10 + (ord(c) - ord('0')).int64
      if bad:
        ctx.reject(Http400, ProtocolViolated, "non-parseable content-length")
        return false
      if server.contenttype == ContentType.NoBody and n > 0:
        # No body is ever read, so its bytes would be parsed as the next request.
        ctx.reject(Http400, ProtocolViolated, "request body not accepted (NoBody server)")
        return false
      if server.contenttype == ContentType.Compact and n > server.bufferlength + 1 - ctx.bodystart:
        ctx.reject(Http413, ProtocolViolated, "content-length exceeds buffer")
        return false
      ctx.contentlength = n
  let http10 = ctx.requestLineIsHttp10()
  ctx.http10 = http10
  let ni = ctx.wantedIdx.conn
  let hasClose = ctx.headerLen[ni] > 0 and
    ctx.request.hasTokenIn(ctx.headerStart[ni], ctx.headerLen[ni], "close")
  let hasKeep = ctx.headerLen[ni] > 0 and
    ctx.request.hasTokenIn(ctx.headerStart[ni], ctx.headerLen[ni], "keep-alive")
  # RFC 7230 §6.6: `close` wins over `keep-alive` when both tokens appear.
  ctx.keepAlive = if http10: hasKeep and not hasClose else: not hasClose
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

proc pathSpan*(ctx: HttpContext): HttpSpan =
  ## Borrowed path portion of the request target (target up to `'?'`).
  ## Result points into `ctx.request`; valid until `prepareHttpContext` or
  ## `compactRequest`. `'?'` itself is excluded; no URL decoding is done.
  if ctx.urilen == 0: return HttpSpan()
  if ctx.queryAt == -2:                  # not scanned yet for this request
    ctx.queryAt = -1
    for i in 0 ..< ctx.urilen.int:
      if ctx.request[ctx.uristart + i] == '?':
        ctx.queryAt = i.int32
        break
  if ctx.queryAt < 0:
    HttpSpan(start: ctx.uristart, len: ctx.urilen)
  else:
    HttpSpan(start: ctx.uristart, len: ctx.queryAt.int64)

proc querySpan*(ctx: HttpContext): HttpSpan =
  ## Borrowed query portion of the request target (`'?'` excluded, spans
  ## everything after it, `'&'`-separated). Empty when the target has no
  ## query. Valid until `prepareHttpContext` or `compactRequest`.
  let p = pathSpan(ctx)
  if p.len == 0 or p.len >= ctx.urilen: return HttpSpan()
  let qstart = p.start + p.len + 1
  HttpSpan(start: qstart, len: ctx.urilen - p.len - 1)

proc queryParam*(ctx: HttpContext, name: string): HttpSpan =
  ## Borrowed value span of the FIRST `'&'`-separated `key=value` segment of
  ## the query whose key compares byte-wise equal to `name` (pinned by the
  ## URL-and-header-spans suite). Deliberately not decoded or split further:
  ## a key with no `'='` (`key`), an empty value (`key=`), and an unknown
  ## key all yield the empty span, and only the first match counts even if
  ## a later occurrence carries a value. Use the span to copy or slice the
  ## value into your own representation.
  let q = querySpan(ctx)
  if q.len == 0: return HttpSpan()
  var i = 0
  while i < q.len.int:
    var j = i
    while j < q.len.int and ctx.request[q.start.int + j] != '&': inc j
    var e = i
    while e < j and ctx.request[q.start.int + e] != '=': inc e
    if e - i == name.len and (name.len == 0 or ctx.request.bytesEq(q.start + i, name)):
      if e < j:
        return HttpSpan(start: q.start + e + 1, len: (j - e - 1).int64)
      return HttpSpan()
    i = j + 1
  HttpSpan()

proc compactRequest*(ctx: HttpContext, server: HttpServer) =
  ## Move any pipelined tail to the front of the header-sized buffer. A buffer
  ## that grew beyond header size is replaced once the tail fits.
  let hdrCap = min(server.maxheaderlength, server.bufferlength).int + 1
  let tailStart = ctx.bodyEnd
  let tailLen = ctx.requestlen - tailStart
  if tailLen <= 0:
    if ctx.request.len > hdrCap:
      ctx.request = newString(hdrCap)      # shrink the grown buffer back
    ctx.requestlen = 0
    return
  if tailLen > hdrCap:
    # tail does not fit the header-sized buffer: leave everything in place.
    # recordCarry has already marked the tail (carryStart/carryLen), and
    # prepareHttpContext moves it byte-in-place when the next request starts.
    return
  if ctx.request.len <= hdrCap:
    if tailStart > 0:
      moveMem(addr ctx.request[0], addr ctx.request[tailStart], tailLen)
  else:
    let nb = newString(hdrCap)
    copyMem(addr nb[0], addr ctx.request[tailStart], tailLen)
    ctx.request = nb
  ctx.requestlen = tailLen
  ctx.carryLen = 0
  ctx.carryStart = 0

# --- per-request state ------------------------------------------------------

proc prepareHttpContext*(ctx: HttpContext, server: HttpServer) =
  if ctx.carryLen > 0:
    moveMem(addr ctx.request[0], addr ctx.request[ctx.carryStart], ctx.carryLen.int)
    ctx.requestlen = ctx.carryLen
    ctx.carryLen = 0
    ctx.carryStart = 0
  # else: pipelined tail may already sit at [0..requestlen) after compactRequest
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
  ctx.queryAt = -2
  ctx.responded = false
  ctx.headOnly = false
  ctx.idleExpired = false
  for i in 0 ..< ctx.wanted.len:
    ctx.headerStart[i] = -1
    ctx.headerLen[i] = 0
    # clear captured values from the previous request so a header present in
    # an earlier request cannot leak into a later request that omits it
    # (parseHeaders repopulates only headers it actually sees)
    ctx.headers[ctx.wanted[i]].setLen(0)

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
    # never hand recv more than the buffer can hold: request.len may be the
    # header cap exactly (and may be below maxheaderlength after buffer shrink)
    let limit = min(1 + server.maxheaderlength, ctx.request.len.int64)
    let maxRead = (limit - ctx.requestlen).int
    if maxRead <= 0:
      ctx.reject(Http431, ProtocolViolated, "request header fields too large")
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
        ctx.reject(Http431, ProtocolViolated, "request header fields too large")
        return false
      return true
    if ctx.requestlen > server.maxheaderlength:
      ctx.reject(Http431, ProtocolViolated, "request header fields too large")
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
  # 100 Continue is flushed before the body is read, only when not already
  # buffered, and never to an HTTP/1.0 client.
  if ctx.headerLen[ctx.wantedIdx.expect] > 0 and not ctx.http10 and
      ctx.contentlength > 0 and ctx.contentreceived < ctx.contentlength:
    if not ctx.replyContinue100():
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
