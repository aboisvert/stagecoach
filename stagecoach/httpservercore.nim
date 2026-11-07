## Shared HTTP server types and constants (no request/response I/O).

import std/[strtabs, logging, strutils]
import stagelane/net
import coachserver
export coachserver

type
  ContentType* = enum
    NoBody
    Compact
    Streaming

  SocketState* = enum
    Fail = -1
    TryAgain = 0
    Progress = 1
    Complete = 2

  HttpServerObj* = object of StagecoachServerObj
    contenttype*: ContentType
    maxheaderlength*: int64
    bufferlength*: int64
    sockettimeoutms*: int      ## max wait for any single read/write (<= 0: none)
    requestTimeoutms*: int     ## max time to receive a full header/body once started (<= 0: none)
    parserequestline*: bool
    headerfields*: seq[string]
    nodelay*: bool             ## set TCP_NODELAY on accepted sockets (default true)
    osThreads*: int
    maxConnections*: int
    maxInflight*: int
    runtime*: HttpRuntime

  HttpServer* = ref HttpServerObj

  WorkerIdx* = object
    runtime*: HttpRuntime
    idx*: int

  HttpRuntime* = ref object
    ## Per-`serve` state: one listener and shutdown pipe per worker thread.
    httpServer*: HttpServer
    threads*: seq[Thread[WorkerIdx]]
    shutdownPipes*: seq[(cint, cint)]   # (write end, read end)
    listeners*: seq[TcpListener]        # per-worker (SO_REUSEPORT) when non-empty
    sharedListener*: TcpListener

  HttpContext* = ref object of RootObj
    server*: HttpServer
    socket*: SocketHandle
    request*: string
    requestlen*: int64
    uristart*: int64
    urilen*: int64
    methlen*: int64
    bodystart*: int64
    contentlength*: int64
    contentreceived*: int64
    bodyDelivered*: int64
    carryLen*: int64
    carryStart*: int64
    headers*: StringTableRef
    keepAlive*: bool
    streamScratch*: string
    sendBuf*: string       ## reused response buffer
    http10*: bool
    wanted*: seq[string]   ## lower-case header names captured into `headers`

const
  MSG_DONTWAIT* = when defined(macosx): 0x80.cint else: 0x40.cint
  MSG_MORE* = when defined(linux): 0x8000.cint else: 0.cint

proc initHttpServer*(s: HttpServer, loglevel: Level, parserequestline: bool,
                    contenttype: ContentType, headerfields: openArray[string]) =
  s.initialize(loglevel)
  s.name = "HTTP-" & $s.id
  s.maxheaderlength = 10000.int64
  s.bufferlength = 100000.int64
  s.sockettimeoutms = 5000
  s.requestTimeoutms = 30000
  s.contenttype = contenttype
  s.parserequestline = parserequestline
  s.headerfields = @headerfields
  s.nodelay = true
  s.osThreads = 0
  s.maxConnections = 0
  s.maxInflight = 0
  s.runtime = nil

proc newHttpServer*(loglevel = Level.lvlWarn, parserequestline = true,
                    contenttype = ContentType.Compact, headerfields: openArray[string] = []): HttpServer =
  new(result)
  result.initHttpServer(loglevel, parserequestline, contenttype, headerfields)
  for field in result.headerfields:
    for c in field:
      if c != '-' and not c.isLowerAscii():
        raise newException(ValueError,
          "Header field not in lower case (case-insensitive matching would never see it): " & field)

proc newHttpContext*(server: HttpServer, socket: SocketHandle): HttpContext =
  result = HttpContext(server: server, socket: socket, bodystart: -1, keepAlive: true)
  # Start header-sized; Compact bodies grow the buffer on demand (see readHeader).
  result.request = newString(min(server.maxheaderlength, server.bufferlength) + 1)
  result.headers = newStringTable()
  for field in server.headerfields:
    result.wanted.add field
  for field in ["connection", "transfer-encoding"]:
    if field notin result.wanted: result.wanted.add field
  if server.contenttype != ContentType.NoBody and "content-length" notin result.wanted:
    result.wanted.add "content-length"
  for field in result.wanted:
    result.headers[field] = ""
