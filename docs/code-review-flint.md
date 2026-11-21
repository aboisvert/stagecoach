# Code Review Report — GuildenStern (`HEAD` = `2fdc143`)

**Scope reviewed:** commit range `HEAD~9..HEAD` (9 commits, +3365/−244 across 33 files)
**Type of change:** HTTP server hardening + lifecycle work (Phases 2–9 of the `HttpContext` rework) merged with developer-experience/infra (Docker Linux test runner, CI, docs, version bump to 0.2).

## Context

This is really two work streams in one window:

1. **Server hardening / lifecycle** (`stagecoach/`): stricter framing validation (method token, version, CRLF, whitespace-before-colon, duplicate framing headers, Content-Length overflow/`413`/`501`/`417`, keep-alive matrix, `pathSpan`/`querySpan`/`queryParam` borrowed spans), response changes (canned replies, held-write flush thresholds, `writeToSocket` waits for full send, `replyFile` EINTR retry), PollFd latch discipline, runtime teardown on partial setup failure, stop/drain.
2. **Infra / tests / docs**: Docker Linux test+benches, CI, new test suites, version bump.

## Findings

### Required (before merge)

1. **Required** — Docker test runner silently skips the new regression suite: `scripts/linux-test.sh:42-46` loops `for t in core parser io response pollfd http modes limits shutdown stop stream` — **`slowlap` is missing**. The justfile `test-integration` recipe includes `tests/t_slowlap.nim`, and the README claims the Docker path runs "the full test suite". Consequence: `just linux-test` / `scripts/linux-test.sh test` cannot execute the new keep-alive-slow-handler regression suite.
2. **Required** — `stagecoach.nimble` `task test` suite list omits `slowlap` (claims unit+integration parity with `just test`). Same follow-up as #1.
3. **Required** — README testing docs drift: `just test-unit` is described as only `t_core, t_parser, t_io, t_response`; `just test-integration` list is missing `t_slowlap/t_stop/t_stream`; the "Layers" section is incomplete. Docs now contradict the justfile.

### Required-ish (process)

4. **Required** (process) — Change sizing: this window is +3365/−244 over 33 files, mixing infra, server hardening, and a brand-new test layer. Past the ~1000-changed-lines "too large to review" signal; recommend splitting (infra → hardening → tests) before the 0.2 release.

### Optional / Nit

5. `scripts/linux-test.sh bench`: `docker compose run --rm -e REQUESTS -e CONCURRENCY` passes flag-only env names; depends on exported shell vars. Nit.
6. `docker/Dockerfile`: installs `build-essential clang python3 curl gdb valgrind procps git ca-certificates golang-go` plus a Go toolchain just to install `hey` — heavy for a benchmark helper. Nit.
7. Module growth nit: `stagecoach/httprequest.nim` (518 lines), `httpresponse.nim` (295), `socketio.nim` (216), `stagedispatcher.nim` (365) — nothing exceeds the 1000-line mark, but the `serve` template and request/response modules have grown well past their original cohesion.
8. `tests/t_slowlap.nim` is timing-based (4s handler / 5s read timeout / `sleep(200)` before mid-flight send, 260 rapid cross-connection requests). Acceptable today; flag for flakiness review.

### FYI

9. `deps/stagelane` shows local modifications (`src/stagelane/core.nim` `ParkKind`, `src/stagelane/sched.nim` PollFd) — expected, from applying `patches/stagelane-pollfd.patch`.

## What I verified (no changes made)

- **Tests run locally (macOS arm64, Nim 2.2.12): all green.**
  - `just test-unit` → PASS (`t_core`, `t_parser`, `t_io`, `t_response`; `t_pollfd` skipped on macOS by design)
  - `just test-integration` → PASS (`t_http`, `t_modes`, `t_limits`, `t_slowlap`, `t_shutdown`, `t_stop`, `t_stream`)
  - `just stress` → PASS (200k requests; RSS growth OK)
  - `just examples` → PASS (all examples compile, incl. `querybench`)
- **Not run here:** real Linux PollFd suite (Linux-only; exercised via Docker/CI path instead) and `just linux-bench`.

## Assessment by axis

- **Correctness:** No Critical defect found in the reviewed implementation; the hardening logic (including the `-4` rescan in `isHeaderreceived`, int64 overflow guard, `queryAt` sentinel state machine, carry/compact invariants) holds up under the expanded suites. The new suites meaningfully pin the changed behavior.
- **Security:** No new critical findings. Duplicate framing headers, whitespace-before-colon, TE/Expect handling, and Content-Length bounds are validated and covered by tests. No injection vectors introduced (no SQL; no new user-input sinks beyond existing span-slicing accessors, which are bounds-checked by construction).
- **Performance:** PollFd patch eliminates per-wait `epoll_ctl` churn; no N+1 or unbounded loops introduced.
- **Architecture:** Clean module boundaries retained; the new `HttpSpan` borrowed-accessor API is coherent and documented.

## Verdict

- **Approve the implementation**, conditional on the three required follow-ups (Docker suite list, `nimble test` task, README drift) being fixed.
- No Critical/Required code findings in the changed server logic itself; test verification story is strong (unit + integration + stress + examples, all green).

**Recommended next step:** add `slowlap` to the Docker test loop and the nimble task, sync the README testing lists, and consider splitting this ~3.3k-line window into stacked PRs before the 0.2 release.
