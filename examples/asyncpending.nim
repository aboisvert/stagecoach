import std/[atomics, times, os]
import asyncdispatch
import guildenstern/[dispatcher, httpserver]

type AsyncRequest = object
  id: int
  pending: PendingReply

var
  requestId: Atomic[int]
  requestChan: Channel[AsyncRequest]

proc runAsyncRequest(request: AsyncRequest) {.async.} =
  echo getTime(), " async start request ", request.id
  await sleepAsync(200)
  withPending(request.pending, proc() =
    reply("async reply for " & $request.id))
  echo getTime(), " async done request ", request.id

proc asyncLoop() {.thread, gcsafe.} =
  # This thread owns the only dispatcher that is polled. Futures scheduled
  # anywhere else never resume, because asyncdispatch state is thread-local.
  while not shuttingdown:
    let (ok, request) = requestChan.tryRecv()
    if ok:
      asyncCheck runAsyncRequest(request)
      continue
    try:
      poll(200)
    except ValueError:
      # poll raises until this dispatcher has a timer or handle registered.
      sleep(20)

proc handleRequest() {.gcsafe, raises: [].} =
  let id = requestId.fetchAdd(1) + 1
  let pending = replyPending()
  requestChan.send(AsyncRequest(id: id, pending: pending))
  echo getTime(), " handler accepted request ", id, " (pending)"

requestChan.open()

echo "Listening on http://localhost:8090 (max 2 concurrent pending replies)"
let server = newHttpServer(handleRequest, loglevel = lvlInfo, maxPendingRequests = 2)
server.start(8090, threadpoolsize = 4, maxactivethreadcount = 4)

var asyncThread: Thread[void]
createThread(asyncThread, asyncLoop)

joinThread(server.thread)
joinThread(asyncThread)
