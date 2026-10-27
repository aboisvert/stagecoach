import std/[atomics, strutils, times]
import asyncdispatch
import guildenstern/[dispatcher, httpserver]

type Job = object
  pending: PendingReply
  uri: string
  id: int

var jobId: Atomic[int]
var jobs: Channel[Job]

proc finishJob(job: Job) {.async.} =
  echo getTime(), " async start job ", job.id, " uri=", job.uri
  await sleepAsync(50)
  withPending(job.pending, proc() =
    reply("async reply for " & job.uri & " (job " & $job.id & ")"))
  echo getTime(), " async done job ", job.id

proc asyncLoop() {.thread, gcsafe.} =
  while true:
    if shuttingdown:
      break
    let job = jobs.recv()
    waitFor finishJob(job)

proc handleRequest() =
  let id = jobId.fetchAdd(1) + 1
  let uri = getUri()
  let pending = replyPending()
  echo getTime(), " handler accepted job ", id, " uri=", uri, " (pending)"
  jobs.send(Job(pending: pending, uri: uri, id: id))

echo "Listening on http://localhost:8090 (max 2 concurrent pending replies)"
jobs.open()
var asyncThread: Thread[void]
createThread(asyncThread, asyncLoop)
let server = newHttpServer(handleRequest, loglevel = lvlInfo, maxPendingRequests = 2)
server.start(8090, threadpoolsize = 4, maxactivethreadcount = 4)
joinThread(server.thread)
