## Shared HTTP server types and constants (no request/response I/O).

import std/[strtabs, logging, strutils]
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
    sockettimeoutms*: int
    parserequestline*: bool
    headerfields*: seq[string]
    osThreads*: int
    maxConnections*: int
    maxInflight*: int
    runtime*: pointer

  HttpServer* = ref HttpServerObj

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
  s.contenttype = contenttype
  s.parserequestline = parserequestline
  s.headerfields = @headerfields
  s.osThreads = 0
  s.maxConnections = 0
  s.maxInflight = 0

proc newHttpServer*(loglevel = Level.lvlWarn, parserequestline = true,
                    contenttype = ContentType.Compact, headerfields: openArray[string] = []): HttpServer =
  new(result)
  result.initHttpServer(loglevel, parserequestline, contenttype, headerfields)
  for field in result.headerfields:
    for c in field:
      if c != '-' and not c.isLowerAscii():
        result.log(lvlError, "Header field not in lower case: " & field)

proc newHttpContext*(server: HttpServer, socket: SocketHandle): HttpContext =
  result = HttpContext(server: server, socket: socket, bodystart: -1, keepAlive: true)
  result.request = newString(server.bufferlength + 1)
  if server.contenttype == ContentType.Streaming:
    result.streamScratch = newString(server.bufferlength.int)
  if server.contenttype != ContentType.NoBody or server.headerfields.len > 0:
    result.headers = newStringTable()
    for field in server.headerfields:
      result.headers[field] = ""
    if not result.headers.contains("content-length"):
      result.headers["content-length"] = ""
