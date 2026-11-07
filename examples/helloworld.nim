import guildenstern/[flow, httpserver]

proc handle(ctx: HttpContext) {.flow.} =
  ctx.reply("hello world")

let server = newHttpServer(loglevel = lvlInfo)
serve(server, 8080, handle)
wait(server)
