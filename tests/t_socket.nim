import std/[unittest, net, os, osproc, strutils, times]

const testPort = 18081

var serverProc: Process

proc startTestServer() =
  let root = getCurrentDir()
  doAssert execCmd("nim c --hints:off -o:" & root & "/bin/support_server " &
    root & "/tests/support_server.nim") == 0
  serverProc = startProcess(root & "/bin/support_server", options = {poUsePath, poStderrToStdout})
  # poll for readiness instead of sleeping a fixed time
  for _ in 0 ..< 100:
    try:
      var probe = newSocket()
      probe.connect("127.0.0.1", Port(testPort))
      probe.close()
      return
    except OSError:
      sleep(50)

proc stopTestServer() =
  if serverProc.running:
    serverProc.terminate()
  serverProc.close()

suite "socket integration":
  setup:
    startTestServer()

  teardown:
    stopTestServer()

  test "peer close does not wedge server":
    var client = newSocket()
    client.connect("127.0.0.1", Port(testPort))
    client.close()
    sleep(50)
    var client2 = newSocket()
    client2.connect("127.0.0.1", Port(testPort))
    client2.send("GET / HTTP/1.1\c\LHost: t\c\L\c\L")
    let line = client2.recvLine()
    check "200" in line
    client2.close()

  test "Connection: close closes the socket":
    var client = newSocket()
    client.connect("127.0.0.1", Port(testPort))
    client.send("GET / HTTP/1.1\c\LHost: t\c\LConnection: close\c\L\c\L")
    var all = ""
    while true:
      let chunk = client.recv(4096, timeout = 2000)
      if chunk.len == 0: break
      all.add chunk
    check "200" in all

  test "oversized content-length is rejected, server survives":
    var client = newSocket()
    client.connect("127.0.0.1", Port(testPort))
    client.send("POST / HTTP/1.1\c\LContent-Length: 9223372036854775807\c\L\c\L")
    check client.recv(16, timeout = 2000).len == 0
    var client2 = newSocket()
    client2.connect("127.0.0.1", Port(testPort))
    client2.send("GET / HTTP/1.1\c\LHost: t\c\L\c\L")
    check "200" in client2.recvLine()

  test "keep-alive coalesced requests":
    var client = newSocket()
    client.connect("127.0.0.1", Port(testPort))
    let piped = "GET /a HTTP/1.1\c\LHost: t\c\LConnection: keep-alive\c\L\c\L" &
      "GET /b HTTP/1.1\c\LHost: t\c\LConnection: close\c\L\c\L"
    client.send(piped)
    sleep(300)
    let buf = client.recv(4096)
    check "hit=1" in buf
    check "hit=2" in buf

  test "idle connection times out":
    var client = newSocket()
    client.connect("127.0.0.1", Port(testPort))
    let t0 = getTime().toUnixFloat()
    let chunk = client.recv(16)
    let elapsed = getTime().toUnixFloat() - t0
    check chunk.len == 0 or elapsed >= 0.25

when isMainModule:
  echo "Socket tests finished"
