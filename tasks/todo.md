# Task List: review findings + directory-based test discovery

Plan: [`plan.md`](plan.md). Layout: `tests/unit/`, `tests/integration/`,
`tests/stress/`; shared support (`helpers/`, `fixture_server.nim`,
`support_stream.nim`) stays at `tests/` root.

Status: implemented and verified on macOS (Nim 2.2.12). Docker was unavailable
on this host (daemon not running), so the Linux/Docker path is rewired but not
executed locally; CI runs `just test-unit` + `just test-integration`.

## Phase 0

- [x] **T0** Un-ignore `tasks/todo.md` in `.gitignore` (`!tasks/todo.md`).

## Phase 1 — layout + discovery

- [x] **T1** Unit suites moved to `tests/unit/`; `../helpers/pairs` imports fixed.
- [x] **T2** Fixture suites moved to `tests/integration/`; `../helpers/fixture` imports fixed.
- [x] **T3** `t_stop`, `t_stream` moved to `tests/integration/`; `t_stress` moved to `tests/stress/`; imports fixed.
- [x] **T4** `scripts/run-tests.sh` added: `all|unit|integration|stress|one <name>|list|check`; `check` rejects root-level suites, unknown layers, and empty unit/integration; `stress` builds with `-d:release`.

### Checkpoint A

- [x] `check` green; `list` = 5 unit / 7 integration / 1 stress.
- [x] `unit`, `integration`, `stress` green on macOS.
- [x] Root-level scratch suite fails `check`; in `tests/unit/` it is discovered; scratch deleted.

## Phase 2 — single source of truth

- [x] **T5** `justfile` delegates to the runner; no suite names, no `nim` var.
- [x] **T6** `stagecoach.nimble` `test`/`stress` delegate to the runner; hard-coded list deleted. **(Required #2)**
- [x] **T7** `scripts/linux-test.sh` delegates to the runner; optional layer argument; stale comment removed. **(Required #1)**
  - Not executed locally (no Docker daemon); CI covers the same runner.

### Checkpoint B

- [x] No suite inventory in `justfile`, `stagecoach.nimble`, `scripts/`, `.github/`.
- [x] `just test` and `nimble test` run the same 12 discovered suites.
- [x] Required #1 and #2 closed.

## Phase 3 — docs that cannot drift

- [x] **T8** README § Testing / Layers / Docker rewritten: commands, layer descriptions, directory-discovery rule; no suite enumerations. **(Required #3)**
- [x] **T9** AGENT.md § Testing conventions: layer directories + auto-discovery; "register in both files" removed.

### Checkpoint C

- [x] No suite inventory outside `tests/` (remaining `t_*` mentions are "where to add a regression" guidance).
- [x] README and AGENT.md agree on the layout.
- [x] Required #3 closed.

## Phase 4 — nits

- [x] **T10** `scripts/linux-test.sh` bench passes explicit `-e REQUESTS=... -e CONCURRENCY=...` values. **(nit #5)**
  - Verified by `bash -n` and argument validation; Docker run not possible locally.
- [x] **T11** Dockerfile: multi-stage `hey` build; `golang-go` dropped from the runtime image. **(nit #6)**
  - Build not executed locally (no Docker daemon); CI/next `just linux-build` verifies.
- [x] **T12** `t_slowlap` waits on `/stats` `inflightNow` instead of `sleep(200)`; read margin `slowMs + 5000`; assertions unchanged. **(nit #8)**
  - 5 consecutive green runs.

### Checkpoint D — done

- [x] `scripts/run-tests.sh check`, `just test` (exit 0), `just stress`, `just examples`, `nimble test` all green.
- [ ] Linux/Docker path executed locally — blocked: Docker daemon unavailable; CI verifies on push.
- [x] Findings #1, #2, #3, #5, #6, #8 addressed; #4/#7/#9 recorded in `plan.md`.

## Recorded, no code change

- [x] Finding #4 (change sizing): future hardening/infra windows ship as stacked PRs; note in the 0.2 release description. No history rewrite.
- [x] Finding #7 (module growth): accepted; revisit only near ~1000 lines.
- [x] Finding #9 (`deps/stagelane`): expected patch state; no action.
