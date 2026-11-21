## Spawns tests/fixture_server.nim as a subprocess on a free port.

import std/[net, os, osproc, strutils, tables, times, nativesockets, posix]
import rawclient
import buildflags
export rawclient

type Fixture* = ref object
  child: Process
  port*: int
  port2*: int

var built = false

proc freePort*(): int =
  var s = newSocket()
  defer: s.close()
  s.bindAddr(Port(0), "127.0.0.1")
  int(s.getLocalAddr()[1])

proc buildFixture*() =
  if built: return
  let root = getCurrentDir()
  createDir(root / "bin")
  doAssert execCmd("nim c --hints:off --threads:on" & backendBuildFlag & " -o:" & root / "bin" / "fixture_server " &
    root / "tests" / "fixture_server.nim") == 0, "fixture build failed"
  built = true

proc portOpen*(port: int): bool =
  var s = newSocket()
  try:
    s.connect("127.0.0.1", Port(port))
    true
  except OSError:
    false
  finally:
    s.close()

proc waitFor*(timeoutMs: int, cond: proc (): bool): bool =
  let deadline = epochTime() + timeoutMs / 1000
  while epochTime() < deadline:
    if cond(): return true
    sleep(10)
  cond()

proc startFixture*(args: seq[string] = @[], second = false): Fixture =
  buildFixture()
  result = Fixture(port: freePort())
  var a = @["--port=" & $result.port]
  if second:
    result.port2 = freePort()
    a.add "--second-port=" & $result.port2
  a.add args
  result.child = startProcess(getCurrentDir() / "bin" / "fixture_server", args = a,
                              options = {poParentStreams})
  let f = result
  doAssert waitFor(10000, proc (): bool = portOpen(f.port)), "fixture did not come up"

proc pid*(f: Fixture): int = f.child.processID

proc running*(f: Fixture): bool = f.child.running

proc waitExit*(f: Fixture, timeoutMs: int): bool =
  waitFor(timeoutMs, proc (): bool = not f.child.running)

proc stopFixture*(f: Fixture) =
  if f.child.running:
    f.child.terminate()
    discard f.waitExit(3000)
    if f.child.running: f.child.kill()
  f.child.close()

proc signal*(f: Fixture, sig: cint) = discard posix.kill(Pid(f.pid), sig)

proc exitCode*(f: Fixture): int = f.child.peekExitCode()

proc stats*(f: Fixture): Table[string, int] =
  let c = connectRaw(f.port)
  defer: c.close()
  let r = c.get("/stats", "Connection: close\r\n")
  for line in r.body.splitLines:
    let kv = line.split('=')
    if kv.len == 2: result[kv[0]] = parseInt(kv[1])

proc resetStats*(f: Fixture) =
  let c = connectRaw(f.port)
  defer: c.close()
  discard c.get("/reset", "Connection: close\r\n")

proc waitStat*(f: Fixture, key: string, atLeast: int, timeoutMs = 3000): bool =
  waitFor(timeoutMs, proc (): bool = f.stats().getOrDefault(key) >= atLeast)

proc rssKb*(f: Fixture): int =
  parseInt(execProcess("ps -o rss= -p " & $f.pid).strip())
