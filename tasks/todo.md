# Task List: Stagelane upgrade and Linux io_uring

Plan: [`plan.md`](plan.md). User approved starting implementation.

## Task 1: Replace local PollFd ownership

**Description:** Remove first-party dependency on the patch's PollFd type,
latches, open/close, and drain. Use upstream readiness waits and, when
available, `watchFd`/`forgetFd`; keep a compatible plain-selector path on the
currently pinned older runtime until Task 3. Ensure forget precedes close and
waits occur only after would-block. Keep non-Linux behavior unchanged.

**Acceptance criteria:**
- [x] Old patched dependency still builds and serves correctly without first-party PollFd calls (focused macOS and Linux unit checks).
- [x] Descriptor ownership, close callbacks, retry behavior, and readiness waits pass the existing focused and integration suites.
- [x] Future upstream watched-fd path follows its registration and close contract (new Linux readiness suite).

**Verification:**
- [x] `just test-one io`, `just test-one response`, `just test-one http`.
- [x] `just examples`; exercise Linux readiness on an available Linux host.

**Dependencies:** None.
**Files likely touched:** `stagecoach/socketio.nim`, `stagecoach/stagedispatcher.nim`, `stagecoach/httpresponse.nim`, `stagecoach/httpservercore.nim`.
**Estimated scope:** Medium.

## Task 2: Replace patch-specific readiness tests

**Description:** Replace the PollFd latch-only suite with black-box readiness
and lifecycle tests that work with the old compatibility path and upstream
watched fds. Preserve regression coverage rather than simply dropping the suite.

**Acceptance criteria:**
- [ ] Tests cover delayed read/write wakeup, cancellation, close/fd reuse, and no busy-loop after draining.
- [x] Tests do not depend on private PollFd fields or the patch.

**Verification:**
- [x] Run the focused new suite on Linux and `just test-unit` on macOS.
- [ ] Confirm a deliberately broken wait or cleanup makes a relevant test fail.

**Dependencies:** Task 1.
**Files likely touched:** `tests/unit/t_pollfd.nim`, `tests/unit/t_readiness.nim`, `tests/unit/t_response.nim`.
**Estimated scope:** Medium.

## Checkpoint: Readiness baseline

- [x] The upgraded dependency passes `just test` and `just examples` on macOS and `just linux-test`; Linux readiness regression passes.
- [x] Confirm patch-replacement approach against upstream before the pin changes.

## Task 3: Upgrade and remove the local patch

**Description:** Pin all dependency resolution and automation to the requested
full SHA. Refresh `atlas.lock`, including its embedded Nimble metadata, without
discarding current package tasks. Remove patch application and the patch only
after the upstream readiness baseline works; ensure a fresh clone is reproducible.

**Acceptance criteria:**
- [x] Nimble/Atlas, CI, and Linux setup specify exactly `f5b7cad5babd884baf9b21f8ea11ee9558d02cff`; a fresh `atlas rep` checked out that SHA.
- [ ] No runtime or setup path depends on `stagelane-pollfd.patch`; upstream watched readiness works.
- [x] `atlas rep` does not restore the stale package definition (verified in a disposable directory).

**Verification:**
- [x] In a disposable directory, verify `git -C deps/stagelane rev-parse HEAD` and the package definition after `atlas rep`.
- [x] `just test`, `just examples` on macOS and `just linux-test` on Linux/Docker.

**Dependencies:** Tasks 1–2.
**Files likely touched:** `stagecoach.nimble`, `atlas.lock`, `.github/workflows/ci.yml`, `scripts/linux-test.sh`, `patches/stagelane-pollfd.patch`.
**Estimated scope:** Medium.

## Task 4: Add completion-based socket I/O

**Description:** Add a ring-active path in the central socket I/O module,
retaining readiness fallback. Map `-errno`, partial results, EOF, idle/socket
timeouts, and cancellation correctly. Keep data alive until the kernel releases
it; preserve response ordering even though upstream ringSend lacks `MSG_MORE`.
Do not enable ring by default yet.

**Acceptance criteria:**
- [ ] Focused ring-enabled socketpair tests prove receive/send, partial progress, EOF/error mapping and timeout/cancellation behavior.
- [ ] Readiness and non-Linux paths retain existing behavior; no synchronous blocking send/recv occurs on ring sockets.
- [ ] Cancellation cannot return buffers or contexts to a pool while an operation is in flight.

**Verification:**
- [ ] `just test-one io` and focused ring tests on a Linux host where ring activation is asserted.
- [ ] `just test-unit` on macOS and Linux readiness mode.

**Dependencies:** Task 3.
**Files likely touched:** `stagecoach/socketio.nim`, `tests/unit/t_io.nim`, `tests/helpers/pairs.nim`, `tests/unit/t_uring.nim`.
**Estimated scope:** Medium.

## Task 5: Make file responses ring-safe

**Description:** Retain nonblocking Linux sendfile for readiness sockets; use
bounded buffered transfer and ring sends for ring sockets, with correct
Content-Length, ordering, truncation, timeout, and disconnect handling.

**Acceptance criteria:**
- [ ] Large and truncated file responses retain framing and close behavior in both modes.
- [ ] A slow file reader does not block another connection on the same worker.

**Verification:**
- [ ] `just test-one response`, `just test-one http` in ring-required and readiness modes.
- [ ] Run a bounded slow-reader concurrency regression on a ring-capable Linux host.

**Dependencies:** Task 4.
**Files likely touched:** `stagecoach/httpresponse.nim`, `tests/unit/t_response.nim`, `tests/integration/t_http.nim`, `tests/fixture_server.nim`.
**Estimated scope:** Medium.

## Checkpoint: Completion primitives

- [ ] Ring socket and file regressions actually execute on Linux; fallback and macOS tests remain green.
- [ ] Review timeout/error behavior and explicit backend policy before cutover.

## Task 6: Enable io_uring on Linux workers

**Description:** Enable the ring before each worker's first I/O; allow upstream
net accept to select its ring path and use completion-based socket operations.
By default Linux prefers ring and reports readiness fallback if unavailable.
`-d:stagecoachIoUring` requires ring and fails startup when unavailable;
`-d:stagecoachReadiness` selects readiness. Reject conflicting flags and forced
ring on non-Linux. Coordinate worker startup so a failed required ring is
reported to the caller and all partially started workers/listeners are cleaned
up. Preserve shutdown pipe polling and worker lifecycle.

**Acceptance criteria:**
- [ ] On a capable Linux host every worker enables ring and real accept/recv/send operations are verified as ring operations.
- [ ] Auto mode falls back visibly; explicit selection never silently falls back, and unavailable required ring fails startup.
- [ ] Conflicting flags and forced ring on non-Linux fail at compile time; macOS/BSD defaults compile.
- [ ] Stop, drain, cancellation, restart, timeouts, pipelining, and concurrent clients pass in both Linux modes.

**Verification:**
- [ ] Run `just test` and `just stress` with `-d:stagecoachIoUring` and `-d:stagecoachReadiness`; assert backend, do not count skips.
- [ ] Propagate the same compile-time selection to separately compiled fixture and streaming servers.
- [ ] Test auto selection, injected ring failure, forced-ring failure, and invalid flag combinations.
- [ ] Use deterministic backend instrumentation or syscall tracing to prove real ring operations; run `just examples` on macOS and Linux.

**Dependencies:** Tasks 4–5.
**Files likely touched:** `stagecoach/stagedispatcher.nim`, `tests/fixture_server.nim`, `tests/integration/t_stop.nim`, `tests/integration/t_http.nim`, `scripts/run-tests.sh`.
**Estimated scope:** Medium.

Progress: `stagecoach/iobackend.nim` defines and tests the compile-time policy;
it is not yet connected to worker startup, so the flags do not yet select a
running backend.

## Task 7: Document and verify installation

**Description:** Update current dependency, patch, platform, backend fallback,
and testing guidance. Preserve historical review/spec files as history.

**Acceptance criteria:**
- [ ] README and agent guidance describe the exact pin, clean install, ring requirements, fallback, and test commands accurately.
- [ ] No current setup instruction asks users to apply the retired patch.

**Verification:**
- [ ] Follow the documented clean-clone install and verify the resolved SHA.
- [ ] Search current setup docs and automation for stale pin and patch references.

**Dependencies:** Tasks 3 and 6.
**Files likely touched:** `README.md`, `AGENT.md`.
**Estimated scope:** Small.

## Checkpoint: Complete

- [ ] macOS: `just test`, `just stress`, `just examples` pass.
- [ ] Linux: same suites pass with ring required and readiness forced; actual ring operations are evidenced.
- [ ] Ring-capable Linux host, Docker, and CI paths are exercised; any unexpected limitations are recorded, not counted as ring coverage.
- [ ] Clean install matches the exact SHA; no unintended changes; human review completed.
