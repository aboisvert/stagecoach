# Implementation Plan: Stagelane upgrade and Linux io_uring

## Overview

Pin Stagelane to `f5b7cad5babd884baf9b21f8ea11ee9558d02cff`,
replace the local PollFd integration with upstream facilities, and move Linux
connection I/O to io_uring while preserving HTTP, timeout, shutdown, and
non-Linux behavior.

## Findings and decisions

- The current lockfile and Linux setup scripts use `f72f1ea`; the Nimble
  dependency uses `#head`. `atlas.lock` embeds a stale `stagecoach.nimble`,
  so reproduce/install must not overwrite the current package definition.
- At the requested revision, upstream provides `watchFd` / `forgetFd` and
  `waitReadable` / `waitWritable`, with persistent Linux epoll readiness.
  This replaces the purpose of `patches/stagelane-pollfd.patch`, although the
  APIs and latch semantics are different. The original PollFd patch is no
  longer needed. See [upstream scheduler](https://github.com/ghazalialshafi/stagelane/blob/f5b7cad5babd884baf9b21f8ea11ee9558d02cff/src/stagelane/sched.nim).
- A separate scheduler cleanup patch **is needed**: without it, ten threads
  that enable a ring leak ten descriptors on exit. The patch exposes
  `releaseSched` for normal builds and closes the watched-fd epoll instance.
  Verified with repeated ring and watched-fd workers, with and without
  `-d:flowThreads`. Apply the patch during CI, Docker, and documented Atlas
  setup. Readiness also leaks worker descriptors without it, so a build without
  the cleanup marker fails clearly instead of running an unsafe backend.
- `ringEnable()` is per scheduler thread and opt-in; `stagelane/net.accept`
  uses ring accept only when active. Stagecoach currently calls POSIX `recv`,
  `send`, and `sendfile` directly, so enabling the ring alone is insufficient.
  Use upstream `ringRecv` / `ringSend` for connection traffic. Their results
  are `-errno`, not `osLastError()`, and their buffers must remain valid until
  completion or confirmed cancellation. See [upstream uring API](https://github.com/ghazalialshafi/stagelane/blob/f5b7cad5babd884baf9b21f8ea11ee9558d02cff/src/stagelane/uring.nim).
- Linux defaults to automatic selection: prefer io_uring on every worker and
  explicitly report fallback to readiness if unavailable. Compile-time
  `-d:stagecoachIoUring` requires io_uring and fails startup if any worker
  cannot enable it; `-d:stagecoachReadiness` requires the readiness backend.
  Reject both flags together and reject a forced io_uring build on non-Linux.
  An explicit choice must never silently select a different backend. Other
  platforms default to readiness. Exercise both choices; a skipped ring test
  is **not** ring verification.
- Ring sockets are blocking according to upstream. Never run synchronous
  `sendfile` on them: use a bounded buffered file path with ring sends, or
  another demonstrably nonblocking solution. Existing nonblocking `sendfile`
  remains suitable for readiness mode. `ringSend` suppresses SIGPIPE but does
  not accept Stagecoach's `MSG_MORE`; preserve wire ordering and test chunked
  and file replies rather than assuming identical corking/performance.
- Preserve idle, per-operation socket, and total request timeout semantics,
  including close causes; cancellation must finish before buffer/context reuse
  or descriptor close. Keep the shutdown-pipe readiness wait alongside ring
  completions and test mixed scheduler operation.
- Integration suites compile `tests/fixture_server.nim` and
  `tests/support_stream.nim` separately; propagate the selected compile-time
  backend to these subprocess builds as well as to the top-level test binaries.
- Prepare source compatibility against the old patched runtime before moving
  the pin so every checkpoint remains buildable. Do not manually edit `deps/stagelane`;
  never use the current Linux script on a checkout with uncommitted dependency
  work, because it force-resets that checkout.

## Ordered task index

See [`todo.md`](todo.md) for acceptance criteria, commands, and checkpoints.

1. Replace first-party PollFd ownership with readiness API compatibility.
2. Replace patch-specific tests with behavior-level readiness regressions.
3. Pin the new upstream revision, retire the PollFd patch, and carry the
   independently required scheduler cleanup patch.
4. Add and test Linux completion-based socket operations.
5. Make file responses safe for ring-mode sockets.
6. Enable io_uring per Linux worker and verify complete server behavior.
7. Document dependency, backend selection, and Linux verification.

Tasks 1–3 establish a working readiness baseline. Tasks 4–5 prepare the ring
path without making it the default; task 6 performs the cutover. Shared source
files and the pin make these tasks sequential; docs may be drafted in parallel
after the interfaces settle. Review with the user at checkpoints.

## Risks and mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| io_uring activation fails unexpectedly | Forced backend unavailable | Auto mode reports fallback; forced mode fails visibly; test failure injection and actual ring operations |
| Blocking ring socket reaches POSIX sendfile | Worker stalls under a slow reader | Ring-mode buffered sends; integration test slow reader while another request completes |
| Negative completion error, partial I/O, or timeout mapped incorrectly | Incorrect close cause, hang, or corrupt response | Focused tests for EOF, reset, partial sends, all timeout classes and cancellation |
| Cancellation races with buffer/context reuse or fd reuse | Memory corruption or wrong connection | Wait for kernel completion before reuse; repeated cancellation, shutdown, and restart stress tests |
| Upstream readiness semantics differ from the local latches | Missed wakeups or busy loops | Migrate via `watchFd`/`forgetFd`, wait only after would-block, test wakeups, fd reuse, and cancellation |
| `MSG_MORE` is unavailable via upstream ringSend | Performance/latency changes | Verify response ordering and benchmark; do not claim an improvement without comparable measurements |
| Pin/config drift or stale embedded lock metadata | Different code used locally and in CI | Verify actual checked-out SHA and clean-clone reproduction across every install route |
| Shared macOS worktree has no Linux ring access | False confidence | Record macOS checks separately; require actual Linux ring and forced fallback runs before completion |

## Verification and rollout

Run `just test`, `just stress`, and `just examples` on macOS and Linux. Run
Linux tests once with `-d:stagecoachIoUring` and once with `-d:stagecoachReadiness`,
including the complete integration and stress suites. Prove ring activation and
actual accept/recv/send ring operations through a deterministic backend test or
Linux syscall tracing; successful HTTP alone is insufficient. Exercise
stop/restart, slow clients, large and chunked/file responses, streaming,
pipelining, disconnects, and concurrent workers. The Docker kernel supports
io_uring, but the default Docker seccomp profile blocked its setup here; an
explicit `seccomp=unconfined` test run of upstream `t_uring` passed. Configure
the test environment to permit the required calls and disclose any security
tradeoff; never count a skipped test as evidence. Roll back the source and pin
together if the new backend fails; no data migration is involved.

## Open questions

None. Backend selection and ring-capable Linux environments are specified above.
