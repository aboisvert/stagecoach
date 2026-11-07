# Stagecoach: correctness hardening, socket-IO consolidation, lifecycle

A staff-engineer review of the stagelane port found correctness bugs
(streaming-body keep-alive corruption, loose method validation,
smuggling-grade framing leniencies), structure problems (socket retry logic
living in three places, a process-global shutdown with no drain or restart),
and dropped dependencies from the original GuildenStern port (TCP_NODELAY).
This spec organizes the fixes into small, independently committable phases.
Perf work (context pooling, per-EAGAIN timer allocations) is deferred.

## Problem overview

One request flows [workerAcceptLoop → connectionLoop → beginRequest → handler →
endRequest][stagecoach/stagedispatcher.nim#connectionLoop] on a green flow task
per connection. Three groups of defects surfaced:

1. **Protocol correctness.** A `Streaming` handler that stops reading the body
   leaves the unread tail in the socket, yet `endRequest`
   [[stagecoach/httprequest.nim#endRequest]] reports keep-alive, so the tail is
   misparsed as the next request. Method "validation"
   [[stagecoach/httprequest.nim#parseMethod]] accepts two-letter prefixes
   (`GHOST`, `TRASH`) and rejects standard methods (`REPORT`). Framing
   tolerates duplicate `Content-Length` (last wins), bare-`LF` header lines,
   jпосле the version, and `Connection: close` buried among tokens.
2. **No real lifecycle.** `shutdown()` is a process-global one-way latch; there
   is no per-server `stop()`, no drain of in-flight handlers, and no restart
   after shutdown. `nextid` and the shutdown-callback list
   [[stagecoach/coachserver.nim#shutdown]] are mutated from a signal context.
3. **Duplication and dropped tuning.** The non-blocking read/write retry loop
   and its errno map exist three times (recv, send, recv-classify). TCP_NODELAY
   was lost in the port, so chunked replies on macOS batch with Nagle (can add
   ~40 ms per batch).

## Solution overview

Six phases, ordered so each lands alone and the test suite guards each step:
hardening → close-cause cleanup → socket-IO module → NODELAY → per-server
lifecycle → small cleanups. Tests run with `nimble test`
[[stagecoach.nimble#task test]]; the baseline run is green
(head 9d7d6f5, 19 tests).

```mermaid diff [Phases build the same request path]
 flowchart LR
   A[workerAcceptLoop] -->|connection fd| B[connectionLoop]
-  B --> C[recvSome + classifyRecv + sendSome, three errno maps]
-  C --> D[beginRequest: readHeader, parseRequestLine, receiveToSingleBuffer]
-  D --> E[handler ctx]
-  E --> F[endRequest: keep-alive even with unconsumed body]
-  F --> G[global shutdown: one-way latch, no drain]
+  B --> S[socketio: recvAll, sendAll, one errno map]
+  S --> D[beginRequest: framing hardening]
+  D --> E[handler ctx]
+  E --> F[endRequest: streaming body must be fully consumed]
+  F --> G[stop server: cancel idle connections, drain, join; restartable]
   %% ref node:B [[stagecoach/stagedispatcher.nim#connectionLoop]]
```

## Goals

- A client that abandons a `Streaming` body gets its connection closed, never
  misparsed pipelined requests; valid token methods (including `REPORT`) parse,
  garbage tokens close the connection.
- Duplicate `Content-Length`, bare-`LF` header lines, junk after the version,
  and `close` buried among connection tokens are rejected by framing, with
  parser tests.
- One non-blocking IO home: `stagecoach/socketio.nim` owning recv, send, errno
  classification, and the socket-timeout wrapper.
- TCP_NODELAY on accepted sockets by default, opt-out bool on `HttpServerObj`.
- `stop(srv)` per server: stop accepting, cancel idle connection tasks, drain
  window for in-flight handlers, then join; `shutdown()` composes per-server
  stops; `setupRuntime` works again after a `stop()`.
- A signal-driven shutdown performs only async-signal-safe work; `nextid` is
  atomic; a lowercase header-field name raises at construction time;
  `CancelledError` gets its own close cause; dead imports and the dead watcher
  loop are gone.

## Non-goals

- Per-worker context pooling and per-EAGAIN timer-allocation reduction
  (deferred; see Follow-ups).
- Changing the `serve`/`wait` call sites or the request-buffer design.
- Windows support; the branch stays POSIX.
- Raising the test-server portability bar beyond macOS + Linux.

### ✅ Phase 1: Harden request framing and method validation

**Today**

`beginRequest` parses and accepts: two-letter-prefix methods (so `GHOST /x`
is fine, `REPORT /x` is not), duplicate `Content-Length` headers (last wins —
desync with front-ends that take the first), header lines ending in bare `LF`,
`Connection: close, keep-alive` treated as keep-alive, and junk after the
version (`GET / HTTP/1.1junkcr` passes). Separately, `endRequest` keeps the
connection when a `Streaming` handler abandoned the body.

**Proposed**

- `parseMethod` validates the whole token against RFC 7230 `tchar`; the
  two-letter prefix list is deleted. Any valid token (GET, REPORT, LOCK,
  QUERY, `PAPAYA`) is accepted; invalid bytes close with `ProtocolViolated`.
- `parseHeaders` becomes first-wins and returns whether any wanted header name
  appeared more than once; `processHeaders` rejects duplicates.
- `parseHeaders` rejects header lines not ending in CRLF.
- `Connection` values are split on commas; `close` wins over every other token.
- `parseRequestLine` requires CR directly after the version.
- `endRequest` returns false when a `Streaming` body was not fully consumed
  (`bodyDelivered < contentlength`). The `Compact`+`getBody` path is
  unchanged (`bodyDelivered` legitimately stays 0 there).
- New parser tests for each rule, plus a `Streaming`-abandonment case
  asserting `endRequest == false`.

```callstack
 ok = connectionLoop(ctx) [[stagecoach/stagedispatcher.nim#connectionLoop]]
 └── while ctx.beginRequest() [[d999814:stagecoach/stagedispatcher.nim#beginRequest]]
     ├── readHeader → processHeaders [[d999814:stagecoach/httprequest.nim#processHeaders]]
-    │   ├── parseHeaders: last duplicate wins, bare LF tolerated
+    │   ├── parseHeaders: first wins, duplicates and bare LF rejected
+    │   └── Connection: close wins over other tokens
     ├── parseRequestLine [[d999814:stagecoach/httprequest.nim#parseRequestLine]]
-    │   └── version followed by anything
+    │   └── version followed by CR
     ├── parseMethod [[d999814:stagecoach/httprequest.nim#parseMethod]]
-    │   └── two-letter prefix list only
+    │   └── full RFC 7230 token validation
     └── ctx.endRequest() [[d999814:stagecoach/stagedispatcher.nim#endRequest]]
-    └── keepAlive even when the Streaming body was abandoned
+    └── Streaming body must be fully consumed for keep-alive
```

Changes live in [[d999814:stagecoach/httprequest.nim]] and
[[d999814:tests/t_parser.nim]].

```changes
d999814
stagecoach/httprequest.nim
stagecoach/stagedispatcher.nim
tests/t_parser.nim
```

### ✅ Phase 2: Close-cause cleanup and signal-safety basics

**Today**

A handler cancelled via `CancelledError` closes its socket with the
`TimedOut` cause, so logs can't distinguish client timeouts from internal
cancellation. `shutdown()` runs in signal context and mutates/iterates
`nextid` and the callback list. The shutdown watcher contains a dead loop, and
`newHttpServer` only logs a non-lowercase header name (the header then never
matches).

**Proposed**

- New `SocketCloseCause.Cancelled`; `connectionLoop` closes cancelled handlers
  with it; `logClose` maps it to `lvlDebug`.
- `pokeAllShutdownPipes` stays write-only (async-signal-safe); `shutdown()`
  snapshots the callback list before iterating, and `initialize` uses
  `atomicFetchAdd` for `nextid`.
- `shutdownAcceptWatcher` loses the dead `while`/`break`; straight-line wait +
  read + cancel.
- Lowercase header fields raise `ValueError` instead of logging.
- Dead imports removed (`osproc` in the dispatcher).

```changes
132d411
stagecoach/coachserver.nim
stagecoach/stagedispatcher.nim
stagecoach/httpservercore.nim
```

### ✅ Phase 3: One socket-IO home

**Today**

`recvSome`, `sendSome`, and `classifyRecv` each re-encode the
EINTR/EAGAIN/error-map state machine, and the HTTP version is parsed twice
(`parseRequestLine` and `requestLineIsHttp10`).

**Proposed**

`stagecoach/socketio.nim` owns the retry loops and errno→cause map; req/resp
modules call it. The version check becomes one helper used by both
`parseRequestLine` and `requestLineIsHttp10`. Response headers get one shared
builder. Behavior-preserving refactor; existing tests must pass unchanged.

```callstack
 ret = recvSome(ctx, buf, n) [[8e95b72:stagecoach/socketio.nim#recvSome]]
-└── inline EINTR/EAGAIN retry + classifyRecv (same list, twice)
+└── socketio.recvSome loop [[8e95b72:stagecoach/socketio.nim]]
+    └── socketio.classifyRecv: one errno → (state, cause, msg) map
 ret = sendSome(ctx, data, len, flags) [[8e95b72:stagecoach/socketio.nim#sendSome]]
-└── inline EINTR/EAGAIN retry
+└── socketio.sendSome loop
```

```changes
8e95b72
stagecoach/socketio.nim
stagecoach/httprequest.nim
stagecoach/httpresponse.nim
```

### ✅ Phase 4: TCP_NODELAY back, default on

**Today**

No TCP_NODELAY and `MSG_MORE` is 0 on macOS/BSD, so chunked replies can hit
the Nagle↔delayed-ACK interaction.

**Proposed**

`nodelay: bool = true` knob on `HttpServerObj` (documented in README's
`serve` table); accepted sockets get `TCP_NODELAY` in `connectionLoop` when
enabled. A knob, not a hard constant, so it can be toggled in benchmarks.

```changes
b53b3ee
stagecoach/httpservercore.nim
stagecoach/stagedispatcher.nim
```

### ✅ Phase 5: Real per-server lifecycle (stop, drain, restart)

**Today (latest review address)**

`shuttingdown` was a global atomic; `shutdown()` stopped every server and
rejoined nothing per server; nothing cancelled in-flight handlers; `nextid`
and the callback list were plain globals; `HttpRuntime` accumulated in a
global seq, and `serve` could run once ever.

**Proposed (landed in b35490d)**

- `stop(srv, drainms = 10_000)`: sets the runtime's `stopping` flag and pokes
  its stop pipes. The per-worker accept watcher cancels only the accept loop;
  connection tasks (now owned by an explicit per-worker `conns` `Scope`, not
  the structured `scope` template) keep finishing for the window and are
  force-cancelled after `drainms` (0 = immediately) via a drain timer.
- `wait()`/`join()` join threads, then tear the runtime down (pipe/listener
  `fd`s, registry slot) so the same `HttpServer` runs again with a fresh
  `serve` call.
- Request paths check `serverIsStopping(server)`/`serverIsOpen` instead of
  only the process latch.
- SIGINT/SIGTERM keep immediate behavior (the runtime's `drainms` defaults
  to 0 there); the process latch still prevents restart after a signal, since
  `shuttingdown` remains one-way. New `tests/t_stop.nim` covers stop, port
  release, and restart.

```mermaid diff [stop stops one server, shutdown stops all of them]
 flowchart LR
-  SIG[signal] -->|shuttingdown.store| G[one global latch]
-  G --> W[poke every runtime's pipes]
-  W --> A[accept loop cancelled]
-  A -.->|in-flight handlers never cancelled| H[wait joins: latency = longest handler]
+  SIG[signal] -->|poke pipes| C[watcher cancels only acceptLoop]
+  USER[server.stop drainms] --> C
+  C --> D2[ThreadPool worker main waits drainms]
+  D2 --> K[drain timer force-cancels conns scope]
+  K --> J[wait: threads joined, runtime torn down, server reusable]
   %% ref node:C [[b35490d:stagecoach/stagedispatcher.nim#acceptWatcher]]
```

```changes
b35490d
stagecoach/httpservercore.nim
stagecoach/httprequest.nim
stagecoach/stagedispatcher.nim
tests/t_stop.nim
stagecoach.nimble
```

### ✅ Phase 6: Small cleanups and written contracts

**Today**

`HttpContext` couples parse cursors, IO scratch, and framing state with no
written contract (`recordCarry`/`bodyEnd` invariants live only in code); two
public `closeSocket` overloads collide; `int64`↔`int` casts are scattered;
the README documents limits but not the new knobs/io module/lifecycle.

**Proposed**

- Contract doc comments on the `HttpContext` fields (`requestlen`, `carry*`,
  `bodyDelivered` vs `contentreceived`, `streamScratch` reuse).
- `closeSocket(ctx)` deprecated in favor of `closeHttpSocket` (the server/fd
  variant keeps its name); the httptest example is updated.
- Cast-width cleanup at parse boundaries where it is free.
- README: document `nodelay`, `stop`/`drainms`, the close causes, and
  the streaming-body keep-alive rule; note `Follow-ups` in the spec.

Landed in 7fe4fe0: written contracts on the `HttpContext` fields
[[7fe4fe0:stagecoach/httpservercore.nim]], the ctx-level `closeSocket`
deprecated in favor of `closeHttpSocket` [[7fe4fe0:stagecoach/httpresponse.nim]],
the httptest example updated, and the README documents the knobs, lifecycle
and 0.2 changes.

```changes
7fe4fe0
stagecoach/httpservercore.nim
stagecoach/httpresponse.nim
examples/httptest.nim
README.md
```

## Follow-ups (deferred)

- Per-worker `HttpContext` pooling (cuts the ~10 KB per-connection allocation).
- Timer-allocation churn in `withSocketTimeout` (per-EAGAIN closure + timer).
- Streaming-body timeout: `requestTimeoutms` still does not bound a dribbling
  `Streaming` body — needs a clock carried across `readBodyChunk` calls; needs
  a design decision before landing.
