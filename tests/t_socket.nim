import std/[unittest, net, os, osproc, strutils, times]

const testPort = 18081

var serverProc: Process

proc startTestServer() =
  let root = getCurrentDir()
  doAssert execCmd("nim c --hints:off -o:" & root & "/bin/support_server " &
    root & "/tests/support_server.nim") == 0
  serverProc = startProcess(root & "/bin/support_server", options = {poUsePath, poStderrToStdout})

proc stopTestServer() =
  if serverProc.running:
    serverProc.terminate()
  serverProc.close()

suite "socket integration":
  setup:
    startTestServer()
    sleep(500)

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
