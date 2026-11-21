# Implementation Plan: CI status badges per platform

## Overview

Add GitHub Actions status badges to the README, one per platform/backend
entry of the CI matrix (Ubuntu io_uring, Ubuntu readiness, macOS).

## Architecture Decisions

- GitHub badges are per workflow file, not per matrix job. A single matrix
  workflow can only show one aggregate badge.
- The test steps move into a reusable workflow (`test-matrix.yml`,
  `workflow_call`) so they are defined once. Each platform gets a thin caller
  workflow (`ci-ubuntu-ring.yml`, `ci-ubuntu-readiness.yml`, `ci-macos.yml`),
  and each caller has its own badge.
- The old `ci.yml` is removed so tests do not run twice.
- Badges link to each workflow's Actions page and track `branch=main`.

## Task List

### Phase 1: CI split

- [x] Task 1: Create reusable `test-matrix.yml` with the existing steps,
  parameterized by `runner` and `backend`.
- [x] Task 2: Create the three caller workflows and delete `ci.yml`.

### Checkpoint: CI split
- [x] All workflow files parse as valid YAML.
- [ ] Workflows run green on GitHub (requires push to `main` or a PR).

### Phase 2: Badges

- [x] Task 3: Add the badge row to `README.md`.

### Checkpoint: Complete
- [x] Badge row present, one entry per matrix platform.
- [ ] Badges render with a real status after the first run on `main`.

## Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Badge shows "no status" until the workflow runs on `main` | Low | Expected; check after the first push. |
| Reusable workflow `inputs` misused in a step `if` | Med | Verify with the first CI run; the Linux ring step is the one that depends on it. |
| Renamed workflow files break old badge links | Low | Badge URLs use the new file names only. |

## Open Questions

- None. Changes are uncommitted; commit and push when ready.
