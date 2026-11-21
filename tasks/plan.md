# Implementation Plan: Close the code-review findings + directory-based test discovery

## Overview

Fix the three Required findings and the actionable nits from
[`docs/code-review-flint.md`](../docs/code-review-flint.md), and remove the root
cause behind all three Required findings: the test-suite list is duplicated in
four places (`justfile`, `stagecoach.nimble`, `scripts/linux-test.sh`, docs).
Reorganize suites into `tests/unit/`, `tests/integration/`, and `tests/stress/`,
add one discovery runner (`scripts/run-tests.sh`), and make every entry point
delegate to it. Docs then describe the layout instead of naming suites.

**Decision (user-approved):** layer = directory, not an in-file marker. Shared
support stays at `tests/` root (`tests/helpers/`, `tests/fixture_server.nim`,
`tests/support_stream.nim`).

## Findings → tasks

| Finding (docs/code-review-flint.md) | Task(s) |
|---|---|
| #1 Docker runner skips `slowlap` | T7 |
| #2 `nimble test` omits `slowlap` | T6 |
| #3 README testing docs drift | T8, T9 |
| #4 change sizing (process) | Non-code follow-up (below) |
| #5 bench `-e REQUESTS -e CONCURRENCY` | T10 |
| #6 Dockerfile Go toolchain for `hey` | T11 |
| #7 module growth | Accepted; no action (see Out of scope) |
| #8 `t_slowlap` timing sensitivity | T12 |
| #9 `deps/stagelane` local mods | Expected; no action |

## Architecture decisions

1. **One runner owns enumeration.** `scripts/run-tests.sh` is the only place that
   knows how to list and run suites. `justfile`, `stagecoach.nimble`,
   `scripts/linux-test.sh`, and CI call it. No file may carry a suite list.
2. **The directory is the layer.** `tests/unit/t_*.nim`,
   `tests/integration/t_*.nim`, `tests/stress/t_*.nim`. Adding a suite means
   dropping a file into the right directory — no build-file or doc edits.
3. **Layers keep their meaning.** `unit` = no listening socket or subprocess;
   `integration` = fixture-server or self-hosted end-to-end suites; `stress` =
   release-built soak, opt-in and never part of `all`.
4. **`t_pollfd` stays in `unit`.** It compiles to an empty body off Linux; the
   Docker/Linux path exercises it automatically.
5. **Docs state conventions, never enumerations.** README and AGENT.md describe
   the three directories and the runner; they do not name individual suites, so
   they cannot drift again.
6. **Runner contract.**
   ```
   scripts/run-tests.sh [all|unit|integration|stress|one <name>|list|check]
   ```
   - default `all` = `unit` then `integration`, deterministic sorted order
   - `stress` adds `-d:release`
   - `one <name>` resolves `tests/*/t_<name>.nim` (replaces `just test-one`)
   - `list` prints `<layer>\t<path>`
   - `check` validates layout only (known layer dirs, no suite at `tests/` root,
     at least one unit and integration suite); every run mode calls it first
   - `NIM` env overrides the compiler (default `nim`); flags stay
     `--hints:off --threads:on --outdir:bin`
   - `cd` to the repo root from `$0`, propagate the first failure, exit non-zero
7. **`specs/` history is untouched.** It describes past phases and paths at the
   time; rewriting it would falsify the record. The review report in `docs/` is
   likewise a historical artifact.

## Task List

### Phase 0: make planning artifacts trackable

- [ ] **T0 — Un-ignore the task checklist** (`XS`, 1 file)
  - Add `!tasks/todo.md` to `.gitignore` (the existing `todo.md` pattern ignores
    it at any depth).
  - Acceptance: `tasks/todo.md` is visible to git; `tasks/plan.md` already is.
  - Verify: `git check-ignore -v tasks/todo.md` exits 1; `git status` shows both.
  - Deps: none.

### Phase 1: layout + discovery

- [ ] **T1 — Move unit suites** (`S`, 5 moves + 2 import edits)
  - `git mv` `t_core`, `t_parser`, `t_io`, `t_response`, `t_pollfd` into
    `tests/unit/`.
  - Update `import helpers/pairs` → `import ../helpers/pairs` in `t_io`,
    `t_response`.
  - Acceptance: files compile from the new path; no logic changes.
  - Verify: `nim c --hints:off --threads:on --outdir:bin tests/unit/t_core.nim`
    (and the other four).
  - Deps: none.

- [ ] **T2 — Move fixture-based integration suites** (`S`, 5 moves + 5 import edits)
  - `git mv` `t_http`, `t_modes`, `t_limits`, `t_slowlap`, `t_shutdown` into
    `tests/integration/`; `helpers/fixture` → `../helpers/fixture`.
  - Acceptance: compiles from the new path; fixture still builds (it uses the
    repo root and `tests/fixture_server.nim`, both unchanged).
  - Verify: `nim c --hints:off --threads:on --outdir:bin tests/integration/t_http.nim`.
  - Deps: none.

- [ ] **T3 — Move self-hosted and stress suites** (`S`, 3 moves + 2 import edits)
  - `git mv` `t_stop`, `t_stream` into `tests/integration/`;
    `helpers/rawclient` → `../helpers/rawclient` in `t_stream`.
  - `git mv` `t_stress` into `tests/stress/`; `helpers/fixture` →
    `../helpers/fixture`.
  - Keep `tests/support_stream.nim` at the root (it is compiled by path from
    `getCurrentDir()`); no change needed.
  - Acceptance: compiles from the new path.
  - Verify: `nim c --hints:off --threads:on --outdir:bin tests/integration/t_stream.nim`.
  - Deps: none.

- [ ] **T4 — Add the discovery runner** (`S`, 1 file)
  - Create `scripts/run-tests.sh` implementing decision #6.
  - `check` errors on: unknown layer directory containing `t_*.nim`, a
    `tests/t_*.nim` left at the root, or an empty `unit`/`integration` layer.
  - Acceptance: all modes exit 0 on the current tree; `check` fails (non-zero,
    clear message) for a scratch `tests/t_zz_scratch.nim`; `all` excludes stress.
  - Verify: `bash scripts/run-tests.sh check`, `list`, `unit`, `integration`,
    `stress`, `one http`.
  - Files: `scripts/run-tests.sh` (new, `chmod +x`).
  - Deps: T1–T3.

### Checkpoint A — discovery works

- [ ] `bash scripts/run-tests.sh check` passes.
- [ ] `list` reports 5 unit, 7 integration, 1 stress.
- [ ] `unit`, `integration`, and `stress` all green (macOS host).
- [ ] Scratch file `tests/t_zz_scratch.nim` makes `check` fail; moving it to
      `tests/unit/` makes it appear in `list` and `unit`; delete it afterwards.
- [ ] `git status` shows renames plus the new script only.

### Phase 2: one source of truth at every call site

- [ ] **T5 — Rewire `justfile`** (`XS`, 1 file)
  - `test-unit` → `bash scripts/run-tests.sh unit`
  - `test-integration` → `bash scripts/run-tests.sh integration`
  - `test` → `test-unit test-integration` (unchanged shape)
  - `test-one name` → `bash scripts/run-tests.sh one {{name}}`
  - `stress` → `bash scripts/run-tests.sh stress`
  - Remove the now-unused `nim := ...` variable; keep `examples` as is.
  - Acceptance: no suite filenames remain in `justfile`.
  - Verify: `just test-unit`, `just test-integration`, `just test`,
    `just test-one http`, `just stress`.
  - Deps: T4.

- [ ] **T6 — Rewire `stagecoach.nimble`** (`XS`, 1 file) — fixes Required #2
  - `task test` → `exec "bash scripts/run-tests.sh all"`; update its description
    to mention layers.
  - `task stress` → `exec "bash scripts/run-tests.sh stress"`.
  - Acceptance: the hard-coded `for t in [...]` list is gone; `nimble test` runs
    the same suites as `just test`, including `t_slowlap`.
  - Verify: `nimble test` (green; output includes `t_slowlap`).
  - Deps: T4.

- [ ] **T7 — Rewire the Docker Linux runner** (`S`, 1 file) — fixes Required #1
  - In `scripts/linux-test.sh` `test)`, replace the `for t in ...` loop with
    `bash scripts/run-tests.sh <layer>` after `setup_stagelane`.
  - Optional layer argument: `just linux-test unit` → `scripts/run-tests.sh unit`
    (default `all`), validated against the runner's modes before interpolation.
  - Update the stale comment ("mirror justfile test targets").
  - Acceptance: the Docker path can no longer omit a suite; `slowlap` runs there.
  - Verify: `just linux-test` (or `scripts/linux-test.sh test`) on a host with a
    working Docker daemon; if unavailable, verify via CI and record that in the
    PR.
  - Deps: T4, T5.

### Checkpoint B — every entry point enumerates the same set

- [ ] `grep -rn "t_core\|t_http\|t_slowlap\|t_pollfd" justfile stagecoach.nimble scripts .github` → empty.
- [ ] `just test`, `nimble test`, and the Docker `test` path all invoke
      `scripts/run-tests.sh`.
- [ ] `just test` and `nimble test` report the same suite count as `list`.
- [ ] Required findings #1 and #2 closed.

### Phase 3: docs that cannot drift

- [ ] **T8 — Rewrite README testing docs** (`S`, 1 file) — fixes Required #3
  - `## Testing`: commands (`just test`, `just test-unit`,
    `just test-integration`, `just test-one http`, `just stress`,
    `nimble test`) with one-line descriptions, no suite enumerations.
  - `Layers`: describe `tests/unit/`, `tests/integration/`, `tests/stress/` by
    what they cover, and state the "drop a `t_<name>.nim` in the layer
    directory" rule.
  - `## Running Linux tests on macOS (Docker)`: note it runs every discovered
    suite, and that `just linux-test unit` narrows it.
  - Acceptance: README contains no suite inventory; statements match the
    runner's behavior.
  - Verify: read the section end to end; `grep -n "t_[a-z]" README.md` shows no
    inventory (only `test-one http` example and support-file paths).
  - Deps: T4–T7.

- [ ] **T9 — Update AGENT.md testing conventions** (`XS`, 1 file)
  - `tests/t_<name>.nim` → `tests/<layer>/t_<name>.nim`; replace "Register a new
    suite in both `justfile` and `stagecoach.nimble`; the lists differ" with the
    directory-discovery rule and "never add suite lists to build files or docs".
  - Keep the guidance on *which* layer/suite a regression belongs to.
  - Acceptance: AGENT.md no longer documents a drift-prone procedure.
  - Verify: grep for "both `justfile`" → none; read § Testing conventions.
  - Deps: T8.

### Checkpoint C — docs match reality

- [ ] No file outside `tests/` contains a suite inventory.
- [ ] README and AGENT.md agree on the layout and runner.
- [ ] Required finding #3 closed.

### Phase 4: nits and hardening

- [ ] **T10 — Explicit bench env** (`XS`, 1 file) — nit #5
  - `scripts/linux-test.sh` bench: pass values, not flag-only names:
    `-e REQUESTS="${REQUESTS:-20000}" -e CONCURRENCY="${CONCURRENCY:-200}"`.
  - Acceptance: bench works with vars exported, unset, or overridden.
  - Verify: `REQUESTS=1000 CONCURRENCY=10 just linux-bench` (Docker) or
    `bash -n scripts/linux-test.sh` if Docker is unavailable.
  - Deps: T7 (same file; land after).

- [ ] **T11 — Multi-stage `hey` in the Docker image** (`S`, 1 file) — nit #6
  - Add `FROM golang:1.22-alpine AS hey` + `go install
    github.com/rakyll/hey@v0.1.4`, then `COPY --from=hey /go/bin/hey
    /usr/local/bin/hey`; drop `golang-go` from the apt list.
  - Keep `build-essential clang python3 curl gdb valgrind procps git
    ca-certificates` (gdb/valgrind back `SYS_PTRACE`).
  - Acceptance: image builds; `hey` runs; no Go toolchain in the final image.
  - Verify: `just linux-build` then `just linux-bench`; `docker run --rm
    stagecoach-linux which go` fails.
  - Deps: none.

- [ ] **T12 — De-flake `t_slowlap`** (`S`, 1 file) — nit #8
  - Replace `sleep(200)` with bounded polling on the fixture's existing
    `/stats` `inflightNow` (already exposed by `tests/fixture_server.nim`).
  - Widen the read margin to `slowMs + 5000`; keep `quickRequests > 200` and all
    cross-wiring assertions.
  - Acceptance: suite passes 5 consecutive runs; still fails if the
    slow-connection re-read invariant is broken.
  - Verify: `for i in 1 2 3 4 5; do bash scripts/run-tests.sh one slowlap; done`.
  - Deps: T4.

### Checkpoint D — full verification

- [ ] `bash scripts/run-tests.sh check` passes.
- [ ] `just test` green; `just stress` green; `just examples` green.
- [ ] `nimble test` green and includes `t_slowlap`.
- [ ] Linux path: `just linux-test` green, or explicitly recorded as
      CI-verified when no Docker daemon is available.
- [ ] `git status` shows only intended changes; commits are atomic (layout →
      runner → call sites → docs → nits).
- [ ] Findings #1, #2, #3, #5, #6, #8 addressed; #4/#7/#9 recorded below.

## Non-code follow-up (finding #4, change sizing)

The 0.2 window is already merged; it cannot be split retroactively. Record the
recommendation where it affects future work rather than rewriting history:

- Land this fix as small atomic commits in the order above, so it models the
  desired size.
- In the 0.2 PR/release description, note that future hardening + infra windows
  ship as stacked PRs (infra → hardening → tests) rather than one 3.3k-line
  change.
- No source task; do not re-open the merged history.

## Out of scope

- **Finding #7 (module growth):** `httprequest.nim` (518), `httpresponse.nim`
  (295), `socketio.nim` (216), `stagedispatcher.nim` (365) stay as they are.
  Splitting them is a behavior-risking refactor with no review finding against
  it; revisit only if a module crosses ~1000 lines or a change needs the seam.
- **Finding #9:** `deps/stagelane` modifications are the applied PollFd patch
  and are intentionally ignored by git. No action.
- **CI matrix changes:** CI already calls `just test-unit` /
  `just test-integration`, so it inherits discovery automatically. No workflow
  edit needed (stress stays out of PR CI).
- **`specs/` and `docs/code-review-flint.md`:** historical; paths there describe
  the tree at the time and are not rewritten.

## Risks and mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| A new test lands in the wrong directory | Wrong layer or silently unrunnable | `check` rejects `t_*.nim` at the `tests/` root and unknown layer dirs; every mode runs `check` first |
| Moving files breaks helper imports | Compile failure | Import edits are part of each move task; every moved suite is compiled in its task |
| `scripts/run-tests.sh` not executable after checkout | `just`/nimble call fails | Call it as `bash scripts/run-tests.sh` everywhere; keep `chmod +x` for direct use |
| Docker path runs as non-root `dev` with mounted tree | Permission/cwd issues | Script `cd`s to repo root; existing volume layout already writes `bin/` |
| Multi-stage `hey` build needs module proxy | `linux-build` fails | Pin `HEY_VERSION`; fall back to the current Go-in-image install if the proxy is unavailable |
| `t_slowlap` change weakens the regression | False green | Keep `quickRequests > 200`, cross-wiring assertions, and confirm the suite still fails under a deliberate local break before committing |
| `nimble test` re-resolves stagelane | Slow/flaky in CI | CI keeps using `just`; `nimble test` only wraps the runner, dependency setup is unchanged |

## Open questions

None — resolved before implementation: directory layout (user choice), keep the
`test-unit`/`test-integration` recipes as derived filters, and include T11 + T12.
