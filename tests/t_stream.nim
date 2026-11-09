import std/[unittest, net, os, osproc, strutils, times]
import std/nativesockets
import helpers/rawclient

const testPort = 18093

var serverProc: Process

proc startTestServer() =
  let root = getCurrentDir()
  doAssert execCmd("nim c --hints:off --threads:on -o:" & root & "/bin/support_stream " &
    root & "/tests/support_stream.nim") == 0
  serverProc = startProcess(root & "/bin/support_stream", options = {poUsePath, poStderrToStdout})
  for _ in 0 ..< 200:
    try:
      var probe = newSocket()
      probe.connect("127.0.0.1", Port(testPort))
      probe.close()
      return
    except OSError:
      sleep(25)
  doAssert false, "support_stream did not come up"

proc stopTestServer() =
  if serverProc.running:
    serverProc.terminate()
  serverProc.close()

## Sends `parts` with `gapMs` between writes and collects the reply.
## Returns ("", elapsed) when the server drops the connection without
## responding.
##
## The client socket is deliberately non-blocking: a blocking `send` on a
## connection the server reset mid-dribble can wedge the test process (observed
## on macOS: `send` sits in the kernel with no SO_SNDTIMEO and Nim's std/net
## send has no timeout parameter). `trySend` fails fast instead.
proc dribble(parts: seq[string], gapMs = 0): (string, float) =
  var all = ""
  let t0 = epochTime()
  var c = newSocket()
  defer: c.close()
  c.connect("127.0.0.1", Port(testPort))
  c.getFd().setBlocking(false)
  var sent = true
  for i, part in parts:
    if gapMs > 0 and i > 0:
      sleep(gapMs)
    if not c.trySend(part):
      sent = false                    # server closed/reset our side
      break
  if sent:
    while true:
      try:
        let chunk = c.recv(4096, timeout = 4000)
        if chunk.len == 0:
          break
        all.add chunk
      except TimeoutError, OSError:
        break
  (all, epochTime() - t0)

suite "streaming body timeouts":
  setup:
    startTestServer()

  teardown:
    stopTestServer()

  test "a fast streaming body completes":
    let c = connectRaw(testPort)
    defer: c.close()
    let payload = "POST / HTTP/1.1\c\LContent-Length: 20\c\LHost: t\c\L\c\L" &
      ("0123456789" & "0123456789")
    check c.trySend(payload)
    let r = c.readResponse()
    check "ok n=" in r.body

  test "dribbling body is cut at requestTimeoutms":
    # Body bytes arrive one at a time: each gap is far inside
    # sockettimeoutms (300), but the total crosses requestTimeoutms (600)
    # long before the 20 dribbles are done. The server must cut the
    # connection ("request body too slow") instead of waiting forever.
    let head = "POST / HTTP/1.1\c\LContent-Length: 20\c\LHost: t\c\L\c\L"
    var parts = @[head]
    for ch in "0123456789" & "0123456789":
      parts.add($ch)
    let (resp, elapsed) = dribble(parts, gapMs = 50)
    check resp.len == 0             # cut, not answered
    check elapsed < 1.9             # worst case: full dribble only takes ~1.05 s

  test "stalled body cut near sockettimeoutms":
    # 5 of 20 body bytes, then nothing: the per-wait sockettimeoutms
    # (300) must cut the connection even though the header arrived fast.
    let head = "POST / HTTP/1.1\c\LContent-Length: 20\c\LHost: t\c\L\c\L"
    let (resp, elapsed) = dribble(@[head, "abcde"])
    check resp.len == 0
    check elapsed < 2.4
    check elapsed > 0.15            # not cut too eagerly

when isMainModule:
  echo "Streaming timeout tests finished"
