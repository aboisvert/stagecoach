import stagecoach/[flow, httpserver]

proc handleHttpRequest(ctx: HttpContext) {.flow.} =
  let body = "replyfromport" & $(ctx.server.port)
  doAssert ctx.getMethod() == "GET"
  doAssert ctx.headers.getOrDefault("connection") == "keep-alive"
  case ctx.getUri():
    of "/close":
      ctx.replyHeaders(Http204, [])
      ctx.closeHttpSocket()
    of "/stop":
      ctx.reply("stop")
      shutdown()
    else:
      ctx.reply(body)

proc onCloseSocket(server: StagecoachServer, socket: SocketHandle, cause: SocketCloseCause, msg: string) =
  echo "closing socket ", socket, " due to ", cause, " ", msg

echo "Starting at ports 8070, 8071"
var server0 = newHttpServer(loglevel = lvlAll, headerfields = ["connection"])
var server1 = newHttpServer(loglevel = lvlAll, headerfields = ["connection"])
server0.onCloseSocketCallback = onCloseSocket
server1.onCloseSocketCallback = onCloseSocket
serve(server0, 8070, handleHttpRequest, osThreads = 2)
serve(server1, 8071, handleHttpRequest, osThreads = 4)
wait(server0)
