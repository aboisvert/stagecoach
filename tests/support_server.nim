import std/atomics
import stagecoach/[flow, httpserver]

const testPort = 18081
var hits: Atomic[int]

proc handler(ctx: HttpContext) {.flow.} =
  let n = hits.fetchAdd(1) + 1
  ctx.reply("hit=" & $n)

let server = newHttpServer(loglevel = lvlError)
server.sockettimeoutms = 400
serve(server, testPort, handler, osThreads = 1, connLimit = 8, inflightLimit = 4)
wait(server)
