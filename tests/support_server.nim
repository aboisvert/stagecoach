import stagecoach/[flow, httpserver]

const testPort = 18081
var hits = 0

proc handler(ctx: HttpContext) {.flow.} =
  hits.inc
  ctx.reply("hit=" & $hits)

let server = newHttpServer(loglevel = lvlError)
server.sockettimeoutms = 400
serve(server, testPort, handler, osThreads = 1, connLimit = 8, inflightLimit = 4)
wait(server)
