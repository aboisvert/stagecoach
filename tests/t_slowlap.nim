## Regression for a GuildenStern bug report (does not reproduce here): a
## keep-alive connection whose request is handled for longer than one lap of
## the old dispatcher's 200-slot event queue was never read again - the
## worker re-read its queue slot after the handler returned, got another
## connection's SocketData, and restored that one's Read event instead.
## Stagecoach has no shared event queue: the connection task owns its socket
## for the connection's whole life and the handler runs inside it. These
## tests pin that invariant: >QueueSize requests on other connections while
## /sleep parks, then the slow connection must answer at once.
import std/[unittest, strutils, os]
import helpers/fixture

const
  slowMs = 4000               # handler runtime; the quick loop finishes well inside it
  quickRequests = 260         # the report's failing count (> QueueSize = 200)
  quickConns = 4              # keep-alive connections the quick requests cycle over
  readTimeoutMs = 5000        # a healthy next answer needs ~0ms; the old bug never answered

var fx: Fixture

suite "keep-alive survives a slow handler":
  teardown: stopFixture(fx)

  test "next request after a slow handler is answered at once":
    fx = startFixture(@["--threads=1"])
    let slow = connectRaw(fx.port)
    defer: slow.close()
    check "uri=/echo?i=first\n" in slow.get("/echo?i=first").body
    slow.sendRaw "GET /sleep?ms=" & $slowMs & " HTTP/1.1\r\nHost: t\r\n\r\n"
    # quick requests on other keep-alive connections while the slow one parks
    var cs: array[quickConns, RawClient]
    for c in cs.mitems: c = connectRaw(fx.port)
    var wrong = 0
    for i in 0 ..< quickRequests:
      if "uri=/echo?i=q" & $i & "\n" notin cs[i mod quickConns].get("/echo?i=q" & $i).body:
        inc wrong
    check wrong == 0                 # every quick answer was its own (no cross-wiring)
    for c in cs: c.close()
    check slow.readResponse(readTimeoutMs).body == "slept"
    # the regression: the same connection must serve its next request
    slow.sendRaw "GET /echo?i=again HTTP/1.1\r\nHost: t\r\n\r\n"
    check "uri=/echo?i=again\n" in slow.readResponse(readTimeoutMs).body

  test "request sent while the slow handler runs is answered too":
    fx = startFixture(@["--threads=1"])
    let slow = connectRaw(fx.port)
    defer: slow.close()
    slow.sendRaw "GET /sleep?ms=" & $slowMs & " HTTP/1.1\r\nHost: t\r\n\r\n"
    sleep(200)                       # let the handler park on delay()
    slow.sendRaw "GET /echo?i=midflight HTTP/1.1\r\nHost: t\r\n\r\n"
    let rs = slow.readResponses(2, readTimeoutMs)
    check rs[0].body == "slept"
    check "uri=/echo?i=midflight\n" in rs[1].body
