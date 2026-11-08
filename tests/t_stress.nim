## Stress / soak: concurrent pipelined clients, abrupt disconnects, close
## accounting and RSS growth. Not part of the default run (`just stress`).
import std/[unittest, strutils, random, os, tables, times, locks, strformat]
import helpers/fixture

const
  clients = 200
  requestsPerClient = 200

var
  failures: int
  failLock: Lock
  seedUsed: int64
  connsOpened: int

initLock(failLock)

proc fail(msg: string) =
  withLock failLock:
    inc failures
    if failures <= 5: echo "FAIL: ", msg

type Job = tuple[port: int, id: int, seed: int64, abrupt: bool]

proc clientMain(job: Job) {.thread.} =
  var rng = initRand(job.seed)
  let c = connectRaw(job.port)
  defer: c.close()
  var sent = 0
  while sent < requestsPerClient:
    let depth = min(rng.rand(1 .. 8), requestsPerClient - sent)
    var req = ""
    for k in 0 ..< depth:
      let n = rng.rand(0 .. 200)
      let id = sent + k
      req.add "POST /echo?c=" & $job.id & "&i=" & $id & " HTTP/1.1\r\nHost: t\r\nContent-Length: " &
        $n & "\r\n\r\n" & repeat('x', n)
    if job.abrupt and sent >= requestsPerClient div 2:
      discard c.trySend(req[0 ..< req.len div 2])    # die in the middle of a request
      return
    if not c.sendSplit(req, [rng.rand(1 .. 400)]):
      fail "client " & $job.id & ": send failed"
      return
    for k in 0 ..< depth:
      var r: Resp
      if not c.tryReadResponse(r, 10000):
        fail "client " & $job.id & ": missing response " & $(sent + k)
        return
      if ("uri=/echo?c=" & $job.id & "&i=" & $(sent + k) & "\n") notin r.body:
        fail "client " & $job.id & ": out-of-order response at " & $(sent + k)
        return
    sent += depth

suite "stress":
  test "concurrent pipelined clients with abrupt disconnects":
    let seed = getTime().toUnix
    seedUsed = seed
    echo "seed=", seed
    var rng = initRand(seed)
    let fx = startFixture(@["--threads=4", "--connLimit=2048", "--inflight=256", "--socketTimeout=5000"])
    defer: stopFixture(fx)
    var threads = newSeq[Thread[Job]](clients)
    var abruptCount = 0
    for i in 0 ..< clients:
      let abrupt = rng.rand(1.0) < 0.05
      if abrupt: inc abruptCount
      createThread(threads[i], clientMain, (fx.port, i, int64(rng.next() shr 2), abrupt))
    joinThreads(threads)
    check failures == 0
    # The server is still healthy and every connection was accounted for.
    let c = connectRaw(fx.port)
    check c.get("/").status == 200
    c.close()
    sleep(200)
    var total = 0
    let st = fx.stats()
    for k, v in st:
      if k.startsWith("close."): total += v
    # clients + this probe + the stats connection itself (still open while counting)
    check total >= clients + 1
    check total <= clients + 3
    echo &"  closes={total} abrupt={abruptCount} hits={st[\"hits\"]}"

  test "memory does not grow across 200k requests":
    let fx = startFixture(@["--threads=2", "--socketTimeout=5000"])
    defer: stopFixture(fx)
    proc burst(n: int) =
      let c = connectRaw(fx.port)
      defer: c.close()
      var req = ""
      for i in 0 ..< 100: req.add "GET /echo?i=" & $i & " HTTP/1.1\r\nHost: t\r\n\r\n"
      for _ in 0 ..< n div 100:
        c.sendRaw req
        discard c.readResponses(100)
    burst(20_000)                          # warm up
    let before = fx.rssKb()
    burst(200_000)
    # connection churn too
    for _ in 0 ..< 1000:
      let c = connectRaw(fx.port)
      discard c.get("/")
      c.close()
    let after = fx.rssKb()
    echo &"  rss before={before}KB after={after}KB"
    check after - before < 20_000

when isMainModule:
  echo "Stress tests finished"
