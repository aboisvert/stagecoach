import std/atomics
import stagecoach/[flow, httpserver]

## Streaming-body support server for tests/t_stream.nim.
const testPort = 18093
var hits: Atomic[int]

proc handler(ctx: HttpContext) {.flow.} =
  while true:
    let (st, _) = ctx.readBodyChunk(ctx.server)
    if st == Fail:
      return
    if st == Complete:
      break
  let n = hits.fetchAdd(1) + 1
  ctx.reply("ok n=" & $n)

let server = newHttpServer(loglevel = lvlError, contenttype = Streaming)
server.requestTimeoutms = 600    # bounds total body-receive time
server.sockettimeoutms = 300     # bounds each individual wait
serve(server, testPort, handler, osThreads = 1, connLimit = 8, inflightLimit = 4)
wait(server)
