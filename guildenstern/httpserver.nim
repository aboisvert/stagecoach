## HTTP/1.1 server on the stagelane M:N runtime.

import std/[os, strtabs, strutils, osproc, logging]
from std/posix import recv, EAGAIN, EWOULDBLOCK, close, SocketHandle, INVALID_SOCKET
import httpcore
export httpcore
export strtabs
import guildenserver
export guildenserver
import stagelane/core
import stagelane/sched
export sched.CancelledError
import stagelane/sync
import stagelane/transform

type
  ContentType* = enum
    NoBody
    Compact
    Streaming

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
    headers*: StringTableRef
    keepAlive*: bool

  SocketState* = enum
    Fail = -1
    TryAgain = 0
    Progress = 1
    Complete = 2

  HttpServerObj* = object of GuildenServerObj
    contenttype*: ContentType
    maxheaderlength*: int64
    bufferlength*: int64
    sockettimeoutms*: int
    parserequestline*: bool
    headerfields*: seq[string]
    workerCount*: int
    maxConnections*: int
    maxInflight*: int
    runtime*: pointer

  HttpServer* = ptr HttpServerObj

const
  MSG_DONTWAIT* = when defined(macosx): 0x80.cint else: 0x40.cint
  MSG_MORE* = 0x8000.cint

include httprequest
include httpresponse

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
  s.workerCount = 0
  s.maxConnections = 0
  s.maxInflight = 0

proc newHttpServer*(loglevel = Level.lvlWarn, parserequestline = true,
                    contenttype = Compact, headerfields: openArray[string] = []): HttpServer =
  result = cast[HttpServer](allocShared0(sizeof(HttpServerObj)))
  result.initHttpServer(loglevel, parserequestline, contenttype, headerfields)
  for field in result[].headerfields:
    for c in field:
      if c != '-' and not isLowerAscii(c):
        result.log(lvlError, "Header field not in lower case: " & field)

proc newHttpContext*(server: HttpServer, socket: SocketHandle): HttpContext =
  result = HttpContext(server: server, socket: socket, bodystart: -1, keepAlive: true)
  result.request = newString(server.bufferlength + 1)
  if server.contenttype != NoBody or server.headerfields.len > 0:
    result.headers = newStringTable()
    for field in server.headerfields:
      result.headers[field] = ""
    if not result.headers.contains("content-length"):
      result.headers["content-length"] = ""

include stagedispatcher
