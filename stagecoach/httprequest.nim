import std/[strutils, os, strtabs]
import std/posix as posix
from std/posix import recv, MSG_PEEK, EAGAIN, EWOULDBLOCK
import std/logging
import stagelane/sched
import stagelane/core
import stagelane/transform
import httpservercore
from coachserver import SocketCloseCause, shuttingdown, closeSocket

proc closeHttpSocket*(ctx: HttpContext, cause = CloseCalled, msg = "") =
  let fd = ctx.socket
  if fd == INVALID_SOCKET:
    return
  ctx.socket = INVALID_SOCKET
  closeSocket(ctx.server, fd, cause, msg)

proc classifyRecv*(ret: int, ctx: HttpContext): SocketState =
  if unlikely(shuttingdown):
    return Fail
  if likely(ret > 0):
    return Progress
  if unlikely(ret == 0):
    closeHttpSocket(ctx, ClosedbyClient, "peer closed")
    return Fail
  let lastError = osLastError().int
  if lastError in [EAGAIN.int, EWOULDBLOCK.int]:
    return TryAgain
  var cause = NetErrored
  if lastError == posix.EBADF.int:
    cause = AlreadyClosed
  elif lastError == posix.EFAULT.int:
    cause = EFault
  elif lastError == posix.EPIPE.int:
    cause = ConnectionLost
  elif lastError == posix.ECONNRESET.int:
    cause = ClosedbyClient
  closeHttpSocket(ctx, cause, osErrorMsg(OSErrorCode(lastError)))
  Fail

proc waitSocketReadable*(ctx: HttpContext) {.flow.} =
  let server = ctx.server
  if server.sockettimeoutms <= 0:
    waitReadable(int(ctx.socket))
    return
  let self = curTask()
  let timer = addTimer(server.sockettimeoutms, proc () = cancel(self))
  try:
    waitReadable(int(ctx.socket))
  finally:
    cancel(timer)

proc recvSome*(ctx: HttpContext, buf: pointer, n: int): int {.flow.} =
  while true:
    let r = recv(ctx.socket, buf, n.cint, MSG_DONTWAIT)
    if r > 0:
      return r
    if r == 0:
      return 0
    let e = osLastError()
    if e.int in [EAGAIN.int, EWOULDBLOCK.int]:
      ctx.waitSocketReadable()
    else:
      return r

proc parseMethod*(ctx: HttpContext, server: HttpServer): bool =
  if unlikely(ctx.requestlen < 13):
    ctx.closeHttpSocket(ProtocolViolated, "too short request")
    return false
  while ctx.methlen < ctx.requestlen and ctx.request[ctx.methlen] != ' ':
    ctx.methlen.inc
  if unlikely(ctx.methlen == ctx.requestlen):
    ctx.closeHttpSocket(ProtocolViolated, "http method missing")
    return false
  if unlikely(ctx.request[0 .. 1] notin ["GE", "PO", "HE", "PU", "DE", "CO", "OP", "TR", "PA"]):
    ctx.closeHttpSocket(ProtocolViolated, "invalid http method")
    return false
  true

proc parseRequestLine*(ctx: HttpContext, server: HttpServer): bool =
  if not ctx.parseMethod(server):
    return false
  var i = ctx.methlen + 1
  let start = i
  while i < ctx.requestlen and ctx.request[i] != ' ':
    i.inc
  ctx.uristart = start
  ctx.urilen = i - start
  if unlikely(ctx.requestlen < ctx.uristart + ctx.urilen + 9):
    ctx.closeHttpSocket(ProtocolViolated, "parseRequestLine: no version")
    return false
  if unlikely(ctx.request[ctx.uristart + ctx.urilen + 1] != 'H' or
      ctx.request[ctx.uristart + ctx.urilen + 8] != '1'):
    ctx.closeHttpSocket(ProtocolViolated, "request not HTTP/1.1")
    return false
  server.log(lvlDebug, $server.port & "/" & $ctx.socket & ": " &
    ctx.request[0 .. ctx.uristart + ctx.urilen + 8])
  true

const ContentLengthNeedle = "content-length:"

proc findContentLength(ctx: HttpContext, last: int): int =
  let nlen = ContentLengthNeedle.len
  if last < nlen - 1:
    return -1
  var i = 0
  while i + nlen <= last:
    var j = 0
    while j < nlen and ctx.request[i + j].toLowerAscii() == ContentLengthNeedle[j]:
      inc j
    if j == nlen:
      return i
    inc i
  -1

proc getContentLength*(ctx: HttpContext, server: HttpServer): bool =
  let last = if ctx.bodystart > 0: ctx.bodystart - 1 else: ctx.requestlen.int - 1
  if last < ContentLengthNeedle.len - 1:
    return true
  let start = ctx.findContentLength(last)
  if start == -1:
    return true
  var i = start + ContentLengthNeedle.len
  while i < ctx.requestlen and ctx.request[i] != '\c':
    i += 1
  if i == ctx.requestlen:
    return true
  try:
    ctx.contentlength = parseInt(strip(ctx.request[start + ContentLengthNeedle.len ..< i]))
  except ValueError:
    ctx.closeHttpSocket(ProtocolViolated, "could not parse content-length")
    return false
  let bufCap = server.bufferlength + 1
  if ctx.bodystart >= 0 and ctx.bodystart + ctx.contentlength > bufCap:
    ctx.closeHttpSocket(ProtocolViolated, "content-length exceeds buffer")
    return false
  true

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

proc getUri*(ctx: HttpContext): string =
  if ctx.urilen == 0:
    return ""
  ctx.request[ctx.uristart ..< ctx.uristart + ctx.urilen]

proc isUri*(ctx: HttpContext, uri: string): bool =
  if ctx.urilen != uri.len:
    return false
  for i in 0 ..< ctx.urilen:
    if ctx.request[ctx.uristart + i] != uri[i]:
      return false
  true

proc startsUri*(ctx: HttpContext, uristart: string): bool =
  if ctx.urilen < uristart.len:
    return false
  for i in 0 ..< uristart.len:
    if ctx.request[ctx.uristart + i] != uristart[i]:
      return false
  true

proc getMethod*(ctx: HttpContext): string =
  if ctx.methlen == 0:
    return ""
  ctx.request[0 ..< ctx.methlen]

proc isMethod*(ctx: HttpContext, amethod: string): bool =
  if ctx.methlen != amethod.len:
    return false
  for i in 0 ..< ctx.methlen:
    if ctx.request[i] != amethod[i]:
      return false
  true

proc getBody*(ctx: HttpContext): string =
  if ctx.bodystart < 1:
    return ""
  ctx.request[ctx.bodystart ..< ctx.requestlen]

proc isBody*(ctx: HttpContext, body: string): bool =
  let len = ctx.requestlen - ctx.bodystart
  if len != body.len:
    return false
  for i in 0 ..< len:
    if ctx.request[ctx.bodystart + i] != body[i]:
      return false
  true

proc getRequest*(ctx: HttpContext): string =
  ctx.request[0 ..< ctx.requestlen]

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
  if server.headerfields.len > 0 and not ctx.headers.isNil:
    for key in server.headerfields:
      ctx.headers[key].setLen(0)

proc recordCarry*(ctx: HttpContext, server: HttpServer) =
  var reqEnd = ctx.requestlen
  if ctx.bodystart >= 0:
    if server.contenttype == ContentType.Compact and ctx.contentlength > 0:
      reqEnd = ctx.bodystart + ctx.contentlength
    elif ctx.contentlength > 0:
      reqEnd = ctx.bodystart + ctx.contentreceived
    else:
      reqEnd = ctx.bodystart
  if ctx.requestlen > reqEnd:
    ctx.carryLen = ctx.requestlen - reqEnd
    ctx.carryStart = reqEnd
  else:
    ctx.carryLen = 0
    ctx.carryStart = 0

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
      if value:
        current[1].add(':')
      value = true
    of ' ':
      if value:
        if current[1].len != 0:
          current[1].add(ctx.request[i])
      else:
        current[0].add(ctx.request[i])
    of '\l':
      if ctx.headers.contains(current[0]):
        ctx.headers[current[0]] = current[1]
      value = false
      current = ("", "")
    else:
      if value:
        current[1].add(ctx.request[i])
      else:
        current[0].add(ctx.request[i].toLowerAscii())
    inc i

proc hasRequestData*(ctx: HttpContext, server: HttpServer): bool {.flow.} =
  var probe = [0.char]
  var r = recv(ctx.socket, addr probe[0], 1, MSG_PEEK or MSG_DONTWAIT)
  if likely(r == 1):
    return true
  let state = classifyRecv(r, ctx)
  if state == TryAgain:
    ctx.waitSocketReadable()
    r = recv(ctx.socket, addr probe[0], 1, MSG_PEEK or MSG_DONTWAIT)
    if r == 1:
      return true
    let again = classifyRecv(r, ctx)
    if again == TryAgain:
      ctx.closeHttpSocket(ClosedbyClient, "client sent nothing")
  false

proc receiveHeader*(ctx: HttpContext, server: HttpServer): bool {.flow.} =
  while true:
    if shuttingdown:
      return false
    let maxRead = (1 + server.maxheaderlength - ctx.requestlen).int
    if maxRead <= 0:
      ctx.closeHttpSocket(ProtocolViolated, "maximum allowed header size exceeded")
      return false
    let prev = ctx.requestlen.int
    let ret = ctx.recvSome(addr ctx.request[ctx.requestlen], maxRead)
    let state = classifyRecv(ret, ctx)
    if state == Fail:
      return false
    if state == TryAgain:
      continue
    ctx.requestlen += ret
    if ctx.isHeaderreceived(prev, ctx.requestlen.int):
      break
    if ctx.requestlen > server.maxheaderlength:
      ctx.closeHttpSocket(ProtocolViolated, "maximum allowed header size exceeded")
      return false
  ctx.contentreceived = ctx.requestlen - ctx.bodystart
  true

proc readHeader*(ctx: HttpContext, server: HttpServer): bool {.flow.} =
  if ctx.requestlen == 0:
    if not ctx.hasRequestData(server):
      return false
  if ctx.bodystart < 0 and ctx.requestlen >= 4:
    discard ctx.isHeaderreceived(0, ctx.requestlen.int)
  if ctx.bodystart < 0 and not ctx.receiveHeader(server):
    return false
  if server.headerfields.len == 0:
    if server.contenttype == ContentType.NoBody:
      return true
    return ctx.getContentLength(server)
  ctx.parseHeaders()
  if server.contenttype != ContentType.NoBody:
    try:
      if ctx.headers["content-length"].len > 0:
        ctx.contentlength = ctx.headers["content-length"].parseInt()
        let bufCap = server.bufferlength + 1
        if ctx.bodystart >= 0 and ctx.bodystart + ctx.contentlength > bufCap:
          ctx.closeHttpSocket(ProtocolViolated, "content-length exceeds buffer")
          return false
    except ValueError:
      ctx.closeHttpSocket(ProtocolViolated, "non-parseable content-length")
      return false
  true

proc receiveToSingleBuffer*(ctx: HttpContext, server: HttpServer): bool {.flow.} =
  if ctx.contentlength == 0:
    return true
  if ctx.contentreceived >= ctx.contentlength:
    return true
  while ctx.contentreceived < ctx.contentlength:
    if shuttingdown:
      return false
    let need = ctx.contentlength - ctx.contentreceived
    let recvsize = min(need, server.bufferlength).int
    let position = ctx.bodystart + ctx.contentreceived
    let ret = ctx.recvSome(addr ctx.request[position], recvsize)
    let state = classifyRecv(ret, ctx)
    if state == Fail:
      return false
    if state == TryAgain:
      continue
    let got = min(ret.int64, need)
    ctx.contentreceived += got
    ctx.requestlen = ctx.bodystart + ctx.contentreceived
    if ret.int64 > got:
      ctx.carryStart = position + got
      ctx.carryLen = ret.int64 - got
      ctx.requestlen = ctx.carryStart + ctx.carryLen
  true

proc readBodyChunk*(ctx: HttpContext, server: HttpServer): (SocketState, string) {.flow.} =
  if ctx.contentlength == 0:
    return (Complete, "")
  if ctx.bodyDelivered < ctx.contentreceived:
    let start = ctx.bodystart + ctx.bodyDelivered
    let n = ctx.contentreceived - ctx.bodyDelivered
    let chunk = ctx.request[start ..< start + n]
    ctx.bodyDelivered = ctx.contentreceived
    if ctx.contentreceived >= ctx.contentlength:
      return (Complete, chunk)
    return (Progress, chunk)
  if ctx.contentreceived >= ctx.contentlength:
    return (Complete, "")
  while true:
    if shuttingdown:
      return (Fail, "")
    let need = ctx.contentlength - ctx.contentreceived
    let recvsize = min(need, server.bufferlength).int
    let ret = ctx.recvSome(addr ctx.streamScratch[0], recvsize)
    let state = classifyRecv(ret, ctx)
    if state == Fail:
      return (Fail, "")
    if state == TryAgain:
      return (TryAgain, "")
    let got = min(ret.int64, need)
    ctx.contentreceived += got
    ctx.bodyDelivered += got
    let chunk = if got > 0: ctx.streamScratch[0 ..< got.int] else: ""
    if ctx.contentreceived >= ctx.contentlength:
      return (Complete, chunk)
    return (Progress, chunk)
