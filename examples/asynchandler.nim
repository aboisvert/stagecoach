import std/times
import guildenstern/[flow, httpserver]
import stagelane/sched

var inflight = 0

proc handle(ctx: HttpContext) {.flow.} =
  inflight.inc
  echo getTime(), " start id=", inflight, " uri=", ctx.getUri()
  delay(200)
  ctx.reply("async reply for " & ctx.getUri())
  echo getTime(), " done"

echo "Listening on http://localhost:8090 (maxInflight=2 per worker pool)"
let server = newHttpServer(loglevel = lvlInfo)
serve(server, 8090, handle, numWorkers = 2, inflightLimit = 2)
wait(server)
