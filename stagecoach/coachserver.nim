const StagecoachVersion* = "0.2"

import std/[logging, atomics]
from std/posix import SocketHandle, INVALID_SOCKET, SIGINT, SIGTERM, onSignal, `==`, close
from std/strutils import replace

export SocketHandle, INVALID_SOCKET, posix.`==`, Level

const LogColors = ["\e[90m", "\e[36m", "\e[32m", "\e[34m", "\e[33m", "\e[31m", "\e[35m", "\e[35m"]
template LogLevel*(thelevel: untyped): untyped = Level {.deprecated: "use Level (std/logging) instead of LogLevel".}
const lvlTRACE* = lvlAll

type
  SocketCloseCause* = enum
    EFault = -10000
    Excepted = -1000
    CloseCalled
    Cancelled
    AlreadyClosed
    ClosedbyClient
    ConnectionLost
    TimedOut
    ProtocolViolated
    NetErrored
    SecurityThreatened
    DontClose

  LogCallback* = proc(loglevel: Level, source: string, message: string) {.gcsafe, nimcall, raises: [].}
  OnCloseSocketCallback* = proc(server: StagecoachServer, socket: SocketHandle, cause: SocketCloseCause, msg: string) {.gcsafe, nimcall, raises: [].}

  StagecoachServerObj* {.inheritable.} = object
    port*: uint16
    id*: int
    name*: string
    logCallback*: LogCallback
    loglevel*: Level
    started*: bool
    onCloseSocketCallback*: OnCloseSocketCallback

  StagecoachServer* = ref StagecoachServerObj

var
  shuttingdown*: Atomic[bool]
  nextid: Atomic[int]
  shutdownCallbacks* {.global.}: seq[proc() {.nimcall, raises: [].}]

proc isShuttingDown*(): bool {.inline.} = shuttingdown.load(moRelaxed)

proc `$`*(x: SocketHandle): string {.inline.} = $(x.cint)

proc shutdown*() =
  {.gcsafe.}:
    shuttingdown.store(true, moRelease)
    for shutdownCallback in shutdownCallbacks:
      shutdownCallback()

{.hint[XDeclaredButNotUsed]: off.}
onSignal(SIGTERM): shutdown()
onSignal(SIGINT): shutdown()
{.hint[XDeclaredButNotUsed]: on.}

template log*(theserver: StagecoachServer, level: Level, message: untyped) =
  if unlikely(int(level) >= int(theserver.loglevel)):
    if likely(not isNil(theserver.logCallback)):
      var s = theserver.name & "-" & $getThreadId()
      theserver.logCallback(level, s, $message)

template log*(theserver: StagecoachServer, level: Level, source: string, message: string) =
  if unlikely(int(level) >= int(theserver.loglevel)):
    if likely(not isNil(theserver.logCallback)):
      theserver.logCallback(level, source, message)

proc initialize*(server: StagecoachServer, loglevel: Level) =
  server.id = nextid.fetchAdd(1, moRelaxed)
  server.loglevel = loglevel
  if isNil(server.logCallback):
    server.logCallback = proc(level: Level, source: string, message: string) {.nimcall.} =
      if unlikely(not isNil(getCurrentException())):
        echo LogColors[level.int], level, "\e[0m ", source, " ", message, ": ", getCurrentExceptionMsg()
      elif message.len < 200:
        echo LogColors[level.int], level, "\e[0m ", source, " ", message
      else:
        let excerpt = message[0 .. 49] & " ... (" & $(message.len - 100) & " chars omitted) ... " & message[(message.len - 50) .. (message.len - 1)]
        echo LogColors[level.int], level, "\e[0m ", source, " ", excerpt.replace("\n", "\\n ")

proc logClose*(server: StagecoachServer, socket: SocketHandle, cause = CloseCalled, msg: string) =
  let level =
    if cause in [CloseCalled, Cancelled, AlreadyClosed, ClosedbyClient]: lvlDebug
    elif cause in [ConnectionLost, TimedOut]: lvlInfo
    elif cause in [ProtocolViolated, NetErrored]: lvlNotice
    elif cause == SecurityThreatened: lvlWarn
    else: lvlError
  server.log(level, "socket " & $socket & " " & $cause & ": " & msg)

proc closeSocket*(server: StagecoachServer, socket: SocketHandle, cause = CloseCalled, msg = "") =
  if socket == INVALID_SOCKET: return
  logClose(server, socket, cause, msg)
  if not isNil(server.onCloseSocketCallback):
    server.onCloseSocketCallback(server, socket, cause, msg)
  discard close(socket)
