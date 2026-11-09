## Configurable fixture server for integration tests. See tests/helpers/fixture.nim.
import std/[atomics, strutils, parseopt]
import stagecoach/[flow, httpserver]
import stagelane/sched

const causes = [EFault, Excepted, CloseCalled, Cancelled, AlreadyClosed, ClosedbyClient,
                ConnectionLost, TimedOut, ProtocolViolated, NetErrored, SecurityThreatened, DontClose]

var
  hits: Atomic[int]
  inflightNow, inflightMax: Atomic[int]
  closes: array[causes.len, Atomic[int]]
  accepted: Atomic[int]

proc causeIdx(c: SocketCloseCause): int =
  for i, x in causes:
    if x == c: return i
  0

proc onClose(server: StagecoachServer, socket: SocketHandle, cause: SocketCloseCause, msg: string) {.gcsafe, nimcall, raises: [].} =
  {.cast(gcsafe).}:
    discard closes[causeIdx(cause)].fetchAdd(1)

proc queryParam(uri, key: string): string =
  let q = uri.find('?')
  if q < 0: return ""
  for pair in uri[q + 1 .. ^1].split('&'):
    let kv = pair.split('=', 1)
    if kv[0] == key and kv.len == 2: return kv[1]

proc statsText(): string =
  result = "hits=" & $hits.load() & "\n" &
    "inflightNow=" & $inflightNow.load() & "\n" &
    "inflightMax=" & $inflightMax.load() & "\n"
  for i, c in causes:
    result.add "close." & $c & "=" & $closes[i].load() & "\n"

proc resetStats() =
  hits.store 0
  inflightNow.store 0
  inflightMax.store 0
  for i in 0 ..< causes.len: closes[i].store 0

proc bumpMax(n: int) =
  var cur = inflightMax.load()
  while n > cur and not inflightMax.compareExchange(cur, n): discard

proc echoText(ctx: HttpContext): string =
  result = "method=" & ctx.getMethod() & "\nuri=" & ctx.getUri() & "\n"
  if ctx.server.contenttype == Compact:
    result.add "bodylen=" & $ctx.getBody().len & "\nbody=" & ctx.getBody() & "\n"
  for k, v in ctx.headers:
    if k notin ["content-length", "transfer-encoding"]:
      result.add "h:" & k & "=" & v & "\n"

proc checksum(s: string, acc: var uint32) =
  for c in s: acc = acc * 31'u32 + uint32(ord(c))

proc handler(ctx: HttpContext) {.flow.} =
  let uri = ctx.getUri()
  let path = uri.split('?')[0]
  case path
  of "/":
    let n = hits.fetchAdd(1) + 1
    ctx.reply("hit=" & $n)
  of "/echo":
    ctx.reply(echoText(ctx))
  of "/sleep":
    let n = inflightNow.fetchAdd(1) + 1
    bumpMax(n)
    try:
      delay(parseInt(queryParam(uri, "ms")))
    finally:
      discard inflightNow.fetchSub(1)
    ctx.reply("slept")
  of "/raise":
    raise newException(ValueError, "boom")
  of "/close":
    ctx.reply("bye")
    ctx.closeHttpSocket()
  of "/closenoreply":
    ctx.closeHttpSocket()
  of "/code":
    discard ctx.reply(HttpCode(parseInt(queryParam(uri, "c"))))
  of "/chunked":
    let n = parseInt(queryParam(uri, "n"))
    let size = parseInt(queryParam(uri, "size"))
    if ctx.replyStartChunked():
      for i in 0 ..< n:
        if not ctx.replyContinueChunked(repeat(chr(ord('a') + i mod 26), size)): return
      discard ctx.replyFinishChunked()
  of "/big":
    ctx.reply(repeat('z', parseInt(queryParam(uri, "n"))))
  of "/stream":
    var total = 0
    var sum = 0'u32
    while true:
      let (st, chunk) = ctx.readBodyChunk(ctx.server)
      if st == Fail: return
      total += chunk.len
      checksum(chunk, sum)
      if st == Complete: break
    ctx.reply("len=" & $total & " sum=" & $sum)
  of "/stats":
    ctx.reply(statsText())
  of "/reset":
    resetStats()
    ctx.reply("ok")
  of "/stop":
    ctx.reply("stopping")
    shutdown()
  else:
    ctx.reply(Http404, "nope")

var s1, s2: HttpServer

proc main() =
  var port, port2 = 0
  var mode = "compact"
  var parseline = true
  var headers: seq[string]
  var sockTimeout, reqTimeout, idleTimeout = -1
  var maxHeader, buffer = -1
  var threads = 1
  var connLimit = 64
  var inflight = 32
  for kind, key, val in getopt():
    if kind != cmdLongOption: continue
    case key
    of "port": port = parseInt(val)
    of "second-port": port2 = parseInt(val)
    of "mode": mode = val
    of "parseline": parseline = val == "on"
    of "headers": headers = val.split(',')
    of "socketTimeout": sockTimeout = parseInt(val)
    of "idleTimeout": idleTimeout = parseInt(val)
    of "requestTimeout": reqTimeout = parseInt(val)
    of "maxHeader": maxHeader = parseInt(val)
    of "buffer": buffer = parseInt(val)
    of "threads": threads = parseInt(val)
    of "connLimit": connLimit = parseInt(val)
    of "inflight": inflight = parseInt(val)
    else: quit "unknown option " & key
  let ct = case mode
    of "nobody": NoBody
    of "streaming": Streaming
    else: Compact
  proc mk(): HttpServer =
    result = newHttpServer(loglevel = lvlError, parserequestline = parseline,
                           contenttype = ct, headerfields = headers)
    result.onCloseSocketCallback = onClose
    if sockTimeout >= 0: result.sockettimeoutms = sockTimeout
    if idleTimeout >= 0: result.idleTimeoutms = idleTimeout
    if reqTimeout >= 0: result.requestTimeoutms = reqTimeout
    if buffer >= 0: result.bufferlength = buffer
    if maxHeader >= 0: result.maxheaderlength = maxHeader
  s1 = mk()
  serve(s1, port, handler, osThreads = threads, connLimit = connLimit, inflightLimit = inflight)
  if port2 != 0:
    s2 = mk()
    serve(s2, port2, handler, osThreads = threads, connLimit = connLimit, inflightLimit = inflight)
    wait(s2)
  wait(s1)

main()
