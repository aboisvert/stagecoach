import cgi, stagecoach/[flow, httpserver]

proc handleGet(ctx: HttpContext) {.flow.} =
  if ctx.isUri("/favicon.ico"):
    ctx.replyHeaders(Http204, [])
  else:
    ctx.reply """
      <!doctype html><title>Stagecoach Example</title><body>
      <form action="http://localhost:5051" method="post" accept-charset="utf-8">
      <input name="say" value="Hi"><button>Send"""

proc handlePost(ctx: HttpContext) {.flow.} =
  echo "client said: ", readData(ctx.getBody()).getOrDefault("say")
  ctx.replyHeaders(Http303, ["location: " & ctx.headers.getOrDefault("origin")])

let getserver = newHttpServer(loglevel = lvlInfo, contenttype = NoBody)
let postserver = newHttpServer(headerfields = ["origin"])
serve(getserver, 5050, handleGet, osThreads = 2)
serve(postserver, 5051, handlePost, osThreads = 2)
wait(getserver)
