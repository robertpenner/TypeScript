# AFK Run — Red-to-Green TLA+ Verified Fixes for TypeScript 7 (#1, #2–#5)

**Status:** active

**Branch:** `tla-concurrency-verification` (TLA+ models, run log) + per-ticket fix branches off `main` (`e0fce98`) in sibling worktree `/workspaces/robertpenner/TypeScript-fixes`

**Pull request:** per-ticket draft PRs on `robertpenner/TypeScript` against `main` (recorded below as each slice lands; no unsolicited PRs against `microsoft/TypeScript`)

**Started:** 2026-11-26 15:50:59 UTC

**Goal:** Prove end-to-end red-to-green TLA+ verified fixes for 4 novel concurrency bugs tracked under `robertpenner/TypeScript#1` (`#4`, `#2`, `#3`, `#5`): each gets a TLC-verified green model (0 errors), a minimal Go fix with `-race` regression tests on a clean branch off `main` (`e0fce98`), a draft PR on `robertpenner/TypeScript`, and an upstream bug-report + PR draft comment.

**Execution:** sequential (`#4` -> `#2` -> `#3` -> `#5`).

**Verified integration head:** `8f416ad` (`fix/session-global-diag-push`); `tla-concurrency-verification` updated alongside each slice.

### Slice progress

| Issue | Slice | Status | Blocked by / reason | Integration commit | Verification |
| --- | --- | --- | --- | --- | --- |
| #4 | Fix lost global-diagnostics push notification (`project/session.go`) | integrated/verified | | `8f416ad` (PR #6) | TLC `SessionGlobalDiag_Fixed.cfg` 0 errors (72 distinct states, safety + liveness); `go test -race ./internal/project/...` 5/5 pkgs pass; `gofmt` + `go vet` clean |
| #2 | Fix dropped `$/cancelRequest` for queued LSP requests (`lsp/server.go`) | integrated/verified | | `d9f6671` (PR #7) | TLC `LspServerCancel_Fixed.cfg` 0 errors (30 distinct states, deadlock-free); `go test -race ./internal/lsp/...` 3/3 pkgs pass; `gofmt` + `go vet` clean |
| #3 | Fix `api.Session` snapshot use-after-deref & post-close leak (`api/session.go`) | in-progress | | | |
| #5 | Redesign `dirty.SyncMap` entry lifecycle (`project/dirty/syncmap.go`) | ready | | | |

### Verification evidence

- Starting baseline `3421f17`: `run-tlc.sh` 21/21 expected verdicts, `run-repros.sh` 19/19 reproducers confirmed.
- Slice #4 (`fix/session-global-diag-push` `8f416ad`, base `e0fce98`, PR #6):
  - TLC `SessionGlobalDiag_Fixed.cfg`: 0 errors (98 generated, 72 distinct states) verifying `NoLostGlobalDiagnostics`, `NoOutOfOrderPublish`, `EventuallyAllPublished`.
  - TDD: `TestSessionEnqueuePublishGlobalDiagnosticsDuringInFlightPublish` failed before fix (`stillUnpublished is true`), passed after fix (`0.00s`).
  - `go -C ./tsc test -race -timeout=120s -count=1 ./internal/project/...`: 5/5 packages passed (`project`, `ata`, `background`, `dirty`, `logging`).
  - `gofmt -l` and `go vet ./internal/project/...`: clean.
- Slice #2 (`fix/lsp-queued-cancel` `d9f6671`, base `e0fce98`, PR #7):
  - TLC `LspServerCancel_Fixed.cfg`: 0 errors (45 generated, 30 distinct states, deadlock checking enabled) verifying `NoDroppedCancellation`, `NoLeakedPendingEntries`, `CanceledRequestRespondsCancelled`.
  - TDD: `TestCancelRequestWhileQueuedInRequestQueue` failed before fix (`-32602 != -32800`), passed after fix (`0.00s`), alongside `TestCancelActiveRequestCancelsContext`.
  - `go -C ./tsc test -race -timeout=120s -count=1 ./internal/lsp/...`: 3/3 packages passed (`lsp`, `lsproto`, `lspwatcher`).
  - `gofmt -l` and `go vet ./internal/lsp/...`: clean.

### Recovery

Not resumed (fresh run).

### Publication at stop or handoff

**Published head:** `3421f17` on `origin/tla-concurrency-verification` (in progress).

**Unverified checkpoint:** none.

**Remaining local work:** none.

### Final series review

**Base/head:** pending.

**Contracts:** `robertpenner/TypeScript#1`, `#2`, `#3`, `#4`, `#5`, `verification/tla/ANALYSIS.md`.

**Evidence:** pending.

**Findings:** pending.

**Remaining blockers:** pending.
