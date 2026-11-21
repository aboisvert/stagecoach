# AGENT.md

Agent-specific guidance for this repo. `README.md` is the source of truth for
the project overview, requirements, setup, public API, examples, Docker
workflow, test commands, and release notes. Read it first; this file only adds
what an agent needs beyond it.

## Orientation

- [README § Requirements](README.md#requirements) and
  [§ Dependencies](README.md#dependencies) — Nim/stagelane setup.
- [README § Quick start](README.md#quick-start) — handler shape, `serve`
  parameters, server knobs, lifecycle, and the Streaming body rule.
- [README § API overview](README.md#api-overview) — public modules.
- [README § Testing](README.md#testing) and
  [§ Running Linux tests on macOS (Docker)](README.md#running-linux-tests-on-macos-docker)
  — suites, layers, and commands.
- `specs/` — design/hardening history; `patches/` — stagelane patches.

## Setup notes

- `deps/` is vendored and not committed. Never edit files under
  `deps/stagelane/`; carry changes as a patch in `patches/`.
- CI pins stagelane to `f72f1ea`. `atlas install` follows `#head`; use
  `atlas rep` to reproduce `atlas.lock` (see quirks below).
- The Linux PollFd path needs `patches/stagelane-pollfd.patch`; CI and the
  Docker recipes apply it automatically (README § Running Linux tests on macOS
  (Docker)).

## Architecture

Public modules are listed in README § API overview. The internal request path:

```
worker thread -> acceptLoop -> connectionLoop
  -> beginRequest (readHeader, parseRequestLine, body framing)
  -> handler(ctx)
  -> endRequest (keep-alive/carry) -> next pipelined request
```

Internal modules an agent will usually touch:

- `stagecoach/httpservercore.nim` — server/context types, defaults, platform
  constants, `serverIsOpen`/`serverIsStopping`.
- `stagecoach/httprequest.nim` — request line/header parsing, body receive,
  accessors (`getUri`, `headerValue`, `pathSpan`, `readBodyChunk`, …).
- `stagecoach/httpresponse.nim` — `reply`, `reject`, chunked replies,
  `replyFile`, lingering close.
- `stagecoach/socketio.nim` — the only home for non-blocking recv/send retry
  loops, errno classification, socket-timeout wrapper, PollFd latch handling.
- `stagecoach/stagedispatcher.nim` — `serve`/`wait`/`stop`, worker threads,
  accept/connection loops, context pool, shutdown pipes.
- `stagecoach/coachserver.nim` — logging, close causes, global `shutdown()`.
- `tests/fixture_server.nim` and `tests/helpers/` — integration fixture and raw
  client.

## Invariants

### Protocol and security

- Framing is intentionally strict. Reject duplicate `Content-Length` /
  `Transfer-Encoding` / `Connection` / `Expect` / `Host`, bare-LF header lines,
  whitespace before the colon, request `Transfer-Encoding`, invalid or negative
  `Content-Length`, non-`tchar` methods, and junk after the HTTP version.
- `Connection: close` wins over every other token.
- Header field names requested via `headerfields` must be lower-case; at most
  60 user fields (the parser tracks 64 total in a bitmask).
- Never echo exception text to a client. Log it and send a generic 500.
- Once `ctx.responded` is set, never emit a second status line; close instead.
- Every framing change needs a regression test in `t_parser` or `t_http`.

### Concurrency and lifecycle

- Each worker is one OS thread running one stagelane loop. Keep per-worker state
  thread-local; nothing is shared across workers except atomics, shutdown
  pipes, and explicitly pooled work.
- `HttpContext` objects are pooled per worker and reused across connections.
  Never share a context across threads; buffers and spans are only valid until
  `prepareHttpContext` / `compactRequest`.
- Handlers hold an in-flight permit while running. Long blocking work starves
  the worker; use `delay`/`pool.go` (with `-d:flowThreads`) instead.
- `shutdownCallbacks` run in a signal context: only `write(2)` and atomics.
  No locks, logging, or allocation.
- On Linux, clear the PollFd `rdReady`/`wrReady` latch on `EAGAIN` or a short
  read/write before parking, or the next wait busy-loops.
- Keep the BSD/macOS path working; guard Linux-only constants and syscalls with
  `when defined(linux)`.

### Style

- 2-space indentation; follow existing Nim stdlib style and local naming
  (`httpSrv`, `ctx`, `srv`, `rt`, `w`).
- Start modules with a `##` summary. Use `##` for public API contracts
  (ownership, buffer/span lifetime, platform behavior) and `#` for non-obvious
  *why* comments (RFC references, errno/platform details, race reasoning).
- Callbacks stay `{.gcsafe, nimcall, raises: [].}` unless there is a concrete
  reason otherwise.
- Prefer the existing module boundaries. New retry loops, errno maps, or
  timeout wrappers belong in `socketio.nim`, not in request/response code.
- Keep changes focused; do not reformat or refactor unrelated code.

## Testing conventions

See README § Testing for the suites, layers, and commands. Agent-specific:

- Each suite is a standalone `tests/t_<name>.nim` with a `when isMainModule`
  tail.
- Register a new suite in both `justfile` and `stagecoach.nimble`; the lists
  differ (`t_slowlap` is in `just` only). Prefer `just test` over `nimble test`
  for that reason.
- Keep tests deterministic: free ports, bounded `waitFor` polling, no arbitrary
  sleeps. Keep stress-test failures replayable.
- Callbacks that capture results into module globals use `{.cast(gcsafe).}`
  around the mutation (see `tests/t_core.nim`). Prefer the server's
  observation callbacks over shared global state where possible.
- Add the regression test with the fix: `t_parser` for framing/parsing,
  `t_http`/`t_io` for wire and connection behavior.

## Before finishing

- Full suite green: README § Testing.
- Stress suite for concurrency/timing/soak changes: `just stress` (not part of
  `just test`).
- Examples still compile: README § Examples.
- Linux/PollFd/sendfile changes: README § Running Linux tests on macOS (Docker).
- Public behavior changes: update README and any relevant `specs/` phase doc.
- Keep the version in `stagecoach.nimble` and `StagecoachVersion` in
  `stagecoach/coachserver.nim` in sync.
- No incidental changes to `nim.cfg` / `atlas.lock` unless the dependency
  change is intentional.
- Commit style matches history: imperative, sentence-case subject with a
  trailing period, small atomic commits. No conventional-commit prefixes
  (`feat:`, `fix:`, …); `Spec:`-prefixed subjects track spec/phase progress.

## Known quirks

- `.gitignore` ignores extensionless files under `tests/` (compiled binaries)
  while keeping `.nim` sources and `tests/helpers/` tracked. Build test
  binaries into `bin/` rather than next to the sources.
- `atlas rep` also replays the lockfile's embedded copy of `stagecoach.nimble`,
  which is stale (version 0.1, missing tasks). It overwrites the current file;
  restore `stagecoach.nimble` afterwards or refresh `atlas.lock`.
- The Docker workflow resets `deps/stagelane` to the CI commit on every
  `linux-test`/`linux-bench` run; local edits there will be discarded.
