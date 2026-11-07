import std/[strutils, os]
from std/posix import recv, MSG_PEEK, EAGAIN, EWOULDBLOCK
import std/logging
import stagelane/sched
from coachserver import StagecoachServer, SocketCloseCause, shuttingdown, closeSocket

proc classifyRecv*(ret: int, server: StagecoachServer, ctx: HttpContext): SocketState =
  if unlikely(shuttingdown): return Fail
  if likely(ret > 0): return Progress
  if unlikely(ret == 0): return TryAgain
  let lastError = osLastError().int
  if lastError in [EAGAIN.int, EWOULDBLOCK.int]: return TryAgain
  let cause =
    if lastError in [2, 9]: AlreadyClosed
    elif lastError == 14: EFault
    elif lastError == 32: ConnectionLost
    elif lastError == 104: ClosedbyClient
    else: NetErrored
  closeSocket(server, ctx.socket, cause, osErrorMsg(OSErrorCode(lastError)))
  Fail

proc recvSome*(ctx: HttpContext, buf: pointer, n: int): int {.flow.} =
  while true:
    let r = recv(ctx.socket, buf, n.cint, MSG_DONTWAIT)
    if r >= 0: return r
    let e = osLastError().int
    if e in [EAGAIN.int, EWOULDBLOCK.int]:
      waitReadable(int(ctx.socket))
    else:
      return r

proc parseMethod*(ctx: HttpContext, server: HttpServer): bool =
  if unlikely(ctx.requestlen < 13):
    closeSocket(server, ctx.socket, ProtocolViolated, "too short request")
    return false
  while ctx.methlen < ctx.requestlen and ctx.request[ctx.methlen] != ' ':
    ctx.methlen.inc
  if unlikely(ctx.methlen == ctx.requestlen):
    closeSocket(server, ctx.socket, ProtocolViolated, "http method missing")
    return false
  if unlikely(ctx.request[0 .. 1] notin ["GE", "PO", "HE", "PU", "DE", "CO", "OP", "TR", "PA"]):
    closeSocket(server, ctx.socket, ProtocolViolated, "invalid http method")
    return false
  true

proc parseRequestLine*(ctx: HttpContext, server: HttpServer): bool =
  if not ctx.parseMethod(server): return false
  var i = ctx.methlen + 1
  let start = i
  while i < ctx.requestlen and ctx.request[i] != ' ':
    i.inc
  ctx.uristart = start
  ctx.urilen = i - start
  if unlikely(ctx.requestlen < ctx.uristart + ctx.urilen + 9):
    closeSocket(server, ctx.socket, ProtocolViolated, "parseRequestLine: no version")
    return false
  if unlikely(ctx.request[ctx.uristart + ctx.urilen + 1] != 'H' or
      ctx.request[ctx.uristart + ctx.urilen + 8] != '1'):
    closeSocket(server, ctx.socket, ProtocolViolated, "request not HTTP/1.1")
    return false
  server.log(lvlDebug, $server.port & "/" & $ctx.socket & ": " & ctx.request[0 .. ctx.uristart + ctx.urilen + 8])
  true

const ContentLength = "content-length: "
const ContentLengthLength = ContentLength.len

const BadCharShift = block:
  var result: array[high(char), int]
  for c in low(char) .. high(char):
    result[c] = ContentLengthLength
  for i in 0 ..< ContentLengthLength - 1:
    let c = ContentLength[i]
    result[c] = ContentLengthLength - 1 - i
    if c == 'c': result['C'] = ContentLengthLength - 1 - i
    elif c == 'l': result['L'] = ContentLengthLength - 1 - i
  result

proc findContentLength(ctx: HttpContext, last: int): int =
  var shift = 0
  let maxShift = last - ContentLengthLength
  while shift <= maxShift:
    var j = ContentLengthLength - 1
    while j >= 0:
      let tChar = ctx.request[shift + j]
      let pChar = ContentLength[j]
      if pChar == tChar:
        dec j
      elif pChar == 'c' and tChar == 'C':
        dec j
      elif pChar == 'l' and tChar == 'L':
        dec j
      else:
        break
    if j < 0:
      return shift
    let lastCharInWindow = ctx.request[shift + ContentLengthLength - 1]
    shift += BadCharShift[lastCharInWindow]
  -1

proc getContentLength*(ctx: HttpContext, server: HttpServer): bool =
  let last = if ctx.bodystart > 0: ctx.bodystart - 1 else: ctx.requestlen - 1
  if last < ContentLengthLength: return true
  let start = ctx.findContentLength(last)
  if start == -1: return true
  var i = start + ContentLengthLength
  while i < ctx.requestlen and ctx.request[i] != '\c':
    i += 1
  if i == ctx.requestlen: return true
  try:
    ctx.contentlength = parseInt(ctx.request[start + ContentLengthLength ..< i])
    true
  except:
    closeSocket(server, ctx.socket, ProtocolViolated, "could not parse content-length")
    false

proc isHeaderreceived*(ctx: HttpContext, previouslen, currentlen: int): bool =
  if currentlen < 4: return false
  if ctx.request[currentlen - 4] == '\c' and ctx.request[currentlen - 3] == '\l' and
      ctx.request[currentlen - 2] == '\c' and ctx.request[currentlen - 1] == '\l':
    ctx.bodystart = currentlen
    return true
  var i = if previouslen > 4: previouslen - 4 else: previouslen
  while i <= currentlen - 4:
    if ctx.request[i] == '\c' and ctx.request[i + 1] == '\l' and ctx.request[i + 2] == '\c' and
        ctx.request[i + 3] == '\l':
      ctx.bodystart = i + 4
      return true
    inc i
  false

proc getUri*(ctx: HttpContext): string =
  if ctx.urilen == 0: return ""
  ctx.request[ctx.uristart ..< ctx.uristart + ctx.urilen]

proc isUri*(ctx: HttpContext, uri: string): bool =
  if ctx.urilen != uri.len: return false
  for i in 0 ..< ctx.urilen:
    if ctx.request[ctx.uristart + i] != uri[i]: return false
  true

proc startsUri*(ctx: HttpContext, uristart: string): bool =
  if ctx.urilen < uristart.len: return false
  for i in 0 ..< uristart.len:
    if ctx.request[ctx.uristart + i] != uristart[i]: return false
  true

proc getMethod*(ctx: HttpContext): string =
  if ctx.methlen == 0: return ""
  ctx.request[0 ..< ctx.methlen]

proc isMethod*(ctx: HttpContext, amethod: string): bool =
  if ctx.methlen != amethod.len: return false
  for i in 0 ..< ctx.methlen:
    if ctx.request[i] != amethod[i]: return false
  true

proc getBody*(ctx: HttpContext): string =
  if ctx.bodystart < 1: return ""
  ctx.request[ctx.bodystart ..< ctx.requestlen]

proc isBody*(ctx: HttpContext, body: string): bool =
  let len = ctx.requestlen - ctx.bodystart
  if len != body.len: return false
  for i in ctx.bodystart ..< ctx.bodystart + len:
    if ctx.request[i] != body[i]: return false
  true

proc getRequest*(ctx: HttpContext): string =
  ctx.request[0 ..< ctx.requestlen]

proc prepareHttpContext*(ctx: HttpContext, server: HttpServer) =
  ctx.requestlen = 0
  ctx.contentlength = 0
  ctx.uristart = 0
  ctx.urilen = 0
  ctx.methlen = 0
  ctx.bodystart = -1
  ctx.contentreceived = 0
  if server.headerfields.len > 0 and not ctx.headers.isNil:
    for key in ctx.headers.keys:
      ctx.headers[key].setLen(0)

proc parseHeaders*(ctx: HttpContext) =
  var value = false
  var current: (string, string) = ("", "")
  var i = 0
  while i <= ctx.requestlen - 4:
    case ctx.request[i]
    of '\c':
      if ctx.request[i + 1] == '\l' and ctx.request[i + 2] == '\c' and ctx.request[i + 3] == '\l':
        if ctx.headers.contains(current[0]):
          ctx.headers[current[0]] = current[1]
        return
    of ':':
      if value: current[1].add(':')
      value = true
    of ' ':
      if value:
        if current[1].len != 0: current[1].add(ctx.request[i])
      else:
        current[0].add(ctx.request[i])
    of '\l':
      if ctx.headers.contains(current[0]):
        ctx.headers[current[0]] = current[1]
      value = false
      current = ("", "")
    else:
      if value: current[1].add(ctx.request[i])
      else: current[0].add((ctx.request[i]).toLowerAscii())
    inc i

proc hasRequestData*(ctx: HttpContext, server: HttpServer): bool {.flow.} =
  var probe = [0.char]
  var r = recv(ctx.socket, addr probe[0], 1, MSG_PEEK or MSG_DONTWAIT)
  if likely(r == 1): return true
  let state = classifyRecv(r, server, ctx)
  if state == TryAgain:
    waitReadable(int(ctx.socket))
    r = recv(ctx.socket, addr probe[0], 1, MSG_PEEK or MSG_DONTWAIT)
    if r == 1: return true
    if classifyRecv(r, server, ctx) == TryAgain:
      closeSocket(server, ctx.socket, ClosedbyClient, "client sent nothing")
  false

proc receiveHeader*(ctx: HttpContext, server: HttpServer): bool {.flow.} =
  while true:
    if shuttingdown: return false
    let maxRead = (1 + server.maxheaderlength - ctx.requestlen).int
    if maxRead <= 0:
      closeSocket(server, ctx.socket, ProtocolViolated, "maximum allowed header size exceeded")
      return false
    let prev = ctx.requestlen
    let ret = ctx.recvSome(addr ctx.request[ctx.requestlen], maxRead)
    let state = classifyRecv(ret, server, ctx)
    if state == Fail: return false
    if state == TryAgain: continue
    ctx.requestlen += ret
    if ctx.isHeaderreceived(prev, ctx.requestlen): break
    if ctx.requestlen > server.maxheaderlength:
      closeSocket(server, ctx.socket, ProtocolViolated, "maximum allowed header size exceeded")
      return false
  ctx.contentreceived = ctx.requestlen - ctx.bodystart
  true

proc readHeader*(ctx: HttpContext, server: HttpServer): bool {.flow.} =
  if not ctx.hasRequestData(server): return false
  if not ctx.receiveHeader(server): return false
  if server.headerfields.len == 0:
    if server.contenttype == NoBody: return true
    return ctx.getContentLength(server)
  ctx.parseHeaders()
  if server.contenttype != NoBody:
    try:
      if ctx.headers["content-length"].len > 0:
        ctx.contentlength = ctx.headers["content-length"].parseInt()
    except:
      closeSocket(server, ctx.socket, ProtocolViolated, "non-parseable content-length")
      return false
  true

proc receiveToSingleBuffer*(ctx: HttpContext, server: HttpServer): bool {.flow.} =
  if ctx.contentlength == 0: return true
  if ctx.contentreceived >= ctx.contentlength: return true
  while ctx.contentreceived < ctx.contentlength:
    if shuttingdown: return false
    let recvsize = min(ctx.contentlength - ctx.contentreceived, server.bufferlength).int
    let position = ctx.bodystart + ctx.contentreceived
    let ret = ctx.recvSome(addr ctx.request[position], recvsize.int)
    let state = classifyRecv(ret, server, ctx)
    if state == Fail: return false
    if state == TryAgain: continue
    ctx.contentreceived += ret
    ctx.requestlen = ctx.bodystart + ctx.contentreceived
  true

proc readBodyChunk*(ctx: HttpContext, server: HttpServer): (SocketState, string) {.flow.} =
  if ctx.contentlength == 0:
    return (Complete, "")
  if ctx.contentreceived >= ctx.contentlength:
    if server.contenttype == Streaming and ctx.bodystart >= 0 and ctx.contentreceived > 0:
      return (Complete, ctx.request[ctx.bodystart ..< ctx.bodystart + ctx.contentreceived])
    return (Complete, "")
  while true:
    if shuttingdown:
      return (Fail, "")
    let recvsize = min(ctx.contentlength - ctx.contentreceived, server.bufferlength).int
    let position = if server.contenttype == Streaming: 0 else: ctx.bodystart + ctx.contentreceived
    let ret = ctx.recvSome(addr ctx.request[position], recvsize)
    let state = classifyRecv(ret, server, ctx)
    if state == Fail:
      return (Fail, "")
    if state == TryAgain:
      return (TryAgain, "")
    ctx.contentreceived += ret
    ctx.requestlen = if server.contenttype == Streaming: ret else: ctx.bodystart + ctx.contentreceived
    let chunk = if server.contenttype == Streaming: ctx.request[0 ..< ret] else: ""
    if ctx.contentreceived >= ctx.contentlength:
      return (Complete, chunk)
    return (Progress, chunk)
