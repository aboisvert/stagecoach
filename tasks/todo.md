# Task List: CI status badges per platform

Plan: [`plan.md`](plan.md).

## Task 1: Reusable test workflow

**Description:** Move the existing CI steps into `.github/workflows/test-matrix.yml`
as a `workflow_call` workflow, parameterized by `runner` and `backend`.

**Acceptance criteria:**
- [x] Steps match the previous `ci.yml` matrix job.
- [x] `STAGECOACH_TEST_BACKEND` comes from `inputs.backend`.
- [x] The Linux ring backend-override step is gated on `inputs.backend`.

**Verification:**
- [x] YAML parses.
- [ ] Green run on GitHub.

**Dependencies:** None.

## Task 2: Platform caller workflows

**Description:** Add `ci-ubuntu-ring.yml`, `ci-ubuntu-epoll.yml`,
`ci-macos.yml`, each calling the reusable workflow. Delete `ci.yml`.

**Acceptance criteria:**
- [x] One caller per former matrix entry, with the same runner and backend.
- [x] `ci.yml` removed.

**Verification:**
- [x] YAML parses.
- [ ] Each caller shows a run on GitHub.

**Dependencies:** Task 1.

## Task 3: README badges

**Description:** Add a centered badge row under the title, linking to each caller workflow.

**Acceptance criteria:**
- [x] Three badges, one per caller, each with alt text.
- [ ] Badges show real status on `main`.

**Verification:**
- [x] Markdown diff reviewed.
- [ ] Rendered badges checked on GitHub.

**Dependencies:** Task 2.

## Checkpoint: Complete
- [ ] Changes committed and pushed.
- [ ] All three workflows green on `main`.
- [ ] Badges render with status.
