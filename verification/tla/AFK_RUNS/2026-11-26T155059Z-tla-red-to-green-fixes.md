# AFK Run — Red-to-Green TLA+ Verified Fixes for TypeScript 7 (#1, #2–#5)

**Status:** completed

**Branch:** `tla-concurrency-verification` (TLA+ models, scripts, run log) + 4 clean per-ticket fix branches off `main` (`e0fce98`)

**Pull request:**
- PR #6 (`fix/session-global-diag-push`, `8f416ad`, `Closes #4`): https://github.com/robertpenner/TypeScript/pull/6
- PR #7 (`fix/lsp-queued-cancel`, `34b04f3`, `Closes #2`): https://github.com/robertpenner/TypeScript/pull/7
- PR #8 (`fix/api-snapshot-lifecycle`, `ff6ab1b`, `Closes #3`): https://github.com/robertpenner/TypeScript/pull/8
- PR #9 (`fix/dirty-syncmap-lifecycle`, `d991656`, `Closes #5`): https://github.com/robertpenner/TypeScript/pull/9

**Started:** 2026-11-26 15:50:59 UTC

**Goal:** Prove end-to-end red-to-green TLA+ verified fixes for 4 novel concurrency bugs tracked under `robertpenner/TypeScript#1` (`#4`, `#2`, `#3`, `#5`): each gets a TLC-verified green model (0 errors), a minimal Go fix with `-race` regression tests on a clean branch off `main` (`e0fce98`), a draft PR on `robertpenner/TypeScript`, and an upstream bug-report + PR draft comment (respecting `microsoft/TypeScript/CONTRIBUTING.md`).

**Execution:** sequential (`#4` -> `#2` -> `#3` -> `#5`), followed by fresh-context series code review and repair of all 4 findings.

**Verified integration head:** PR #6 `8f416ad`, PR #7 `34b04f3`, PR #8 `ff6ab1b`, PR #9 `d991656` (all off `e0fce98`); `tla-concurrency-verification` holds all green TLA+ models and this run log.

### Slice progress

| Issue | Slice | Status | Blocked by / reason | Integration commit | Verification |
| --- | --- | --- | --- | --- | --- |
| #4 | Fix lost global-diagnostics push notification (`project/session.go`) | integrated/verified | | `8f416ad` (PR #6) | TLC `SessionGlobalDiag_Fixed.cfg` 0 errors (72 distinct states, safety + liveness); `go test -race ./internal/project/...` 5/5 pkgs pass; `gofmt` + `go vet` clean |
| #2 | Fix dropped `$/cancelRequest` for queued LSP requests (`lsp/server.go`) | integrated/verified | | `34b04f3` (PR #7) | TLC `LspServerCancel_Fixed.cfg` 0 errors (30 distinct states, deadlock-free); `go test -race ./internal/lsp/...` 3/3 pkgs pass; `gofmt` + `go vet` clean |
| #3 | Fix `api.Session` snapshot use-after-deref & post-close leak (`api/session.go`, `api/module_resolution.go`) | integrated/verified | | `ff6ab1b` (PR #8) | TLC `ApiSessionSnapshot_Fixed.cfg` 0 errors (36 distinct states, deadlock-free); `go test -race ./internal/api/...` 4/4 pkgs pass; `gofmt` + `go vet` clean |
| #5 | Redesign `dirty.SyncMap` entry lifecycle (`project/dirty/syncmap.go`) | integrated/verified | | `d991656` (PR #9) | TLC `DirtySyncMapFixed.cfg` 0 errors (4,164 distinct states 2w; 261,232 distinct states 3w, deadlock-free, 6 invariants); `go test -race ./internal/project/... ./internal/ls/autoimport/...` 6/6 pkgs pass; `gofmt` + `go vet` clean |

### Verification evidence

- Starting baseline `3421f17`: `run-tlc.sh` 21/21 expected verdicts, `run-repros.sh` 19/19 reproducers confirmed.
- Slice #4 (`fix/session-global-diag-push` `8f416ad`, base `e0fce98`, PR #6):
  - TLC `SessionGlobalDiag_Fixed.cfg`: 0 errors (98 generated, 72 distinct states) verifying `NoLostGlobalDiagnostics`, `NoOutOfOrderPublish`, `EventuallyAllPublished`.
  - TDD: `TestSessionEnqueuePublishGlobalDiagnosticsDuringInFlightPublish` failed before fix (`stillUnpublished is true`), passed after fix (`0.00s`).
  - `go -C ./tsc test -race -timeout=120s -count=1 ./internal/project/...`: 5/5 packages passed (`project`, `ata`, `background`, `dirty`, `logging`).
  - `gofmt -l` and `go vet ./internal/project/...`: clean.
- Slice #2 (`fix/lsp-queued-cancel` `d9f6671` -> `34b04f3`, base `e0fce98`, PR #7):
  - TLC `LspServerCancel_Fixed.cfg`: 0 errors (45 generated, 30 distinct states, deadlock checking enabled) verifying `NoDroppedCancellation`, `NoLeakedPendingEntries`, `CanceledRequestRespondsCancelled`.
  - TDD: `TestCancelRequestWhileQueuedInRequestQueue` failed before fix (`-32602 != -32800`), passed after fix (`0.00s`), alongside `TestCancelActiveRequestCancelsContext`.
  - Post-review hardening (`34b04f3`): guarded `pendingClientRequests` deletion/lookup by `cur.req == req` pointer identity.
  - `go -C ./tsc test -race -timeout=120s -count=1 ./internal/lsp/...`: 3/3 packages passed (`lsp`, `lsproto`, `lspwatcher`).
  - `gofmt -l` and `go vet ./internal/lsp/...`: clean.
- Slice #3 (`fix/api-snapshot-lifecycle` `6b0b79b` -> `8b598f6` -> `ff6ab1b`, base `e0fce98`, PR #8):
  - TLC `ApiSessionSnapshot_Fixed.cfg`: 0 errors (69 generated, 36 distinct states, deadlock checking enabled) verifying `NoUseAfterDeref`, `NoLeakAfterClose`, `NoNegativeSnapRef`, `QuiescentClean`.
  - Post-review fixes (`8b598f6`, `ff6ab1b`): returned release callback from `moduleResolverForRequest` so `handleResolveModuleName` and `handleResolveTypeReferenceDirective` keep `sd.snapshot` pinned across resolution; set `s.closed = true` before `releaseLanguageServerRefs()` in `Close()` and rejected closed sessions before `APIUpdate` in `handleGetCurrentLanguageServerSnapshot`.
  - `go -C ./tsc test -race -timeout=180s -count=1 ./internal/api/...`: 4/4 packages passed (`api`, `encoder`, `requestfilesystem`, `wasmreactor`), including `TestGetSnapshotDataRetainsAcrossRelease`, `TestGetSnapshotDataRetainsAcrossSessionClose`, and `TestRegisterSnapshotAfterCloseRejectsAndDerefs`.
  - `gofmt -l` and `go vet ./internal/api/...`: clean.
- Slice #5 (`fix/dirty-syncmap-lifecycle` `083885d` -> `d991656`, base `e0fce98`, PR #9):
  - TLC `DirtySyncMapFixed.cfg`: 0 errors across 4,164 distinct states (2 workers) and 261,232 distinct states (3 workers) with deadlock checking enabled on all 6 invariants (`NoNilClonePanic`, `NoDataRace`, `NoMutateBase`, `NoMutateDeleted`, `NoChangeIfTOCTOU`, `NoLostDelete`).
  - All 6 original reproducer tests (`dirty_syncmap_repro_test.go`) passed under `-race` on `083885d`.
  - Post-review fix (`d991656`): avoided double `cond` evaluation on uncontended `ChangeIf`, `DeleteIf`, and `lockedEntry.ChangeIf` (re-checking `cond` only when `LoadOrStore` lost to another canonical entry), plus regression test asserting `calls == 1`.
  - `go -C ./tsc test -race -timeout=120s -count=1 ./internal/project/... ./internal/ls/autoimport/...`: 6/6 packages passed (`dirty`, `project`, `ata`, `background`, `logging`, `autoimport`), including `TestSyncMapEntryLifecycleSafety`.
  - `gofmt -l` and `go vet ./internal/project/dirty/...`: clean.

### Recovery

Not resumed (fresh run). Temporary sibling worktree `/workspaces/robertpenner/TypeScript-fixes` was cleanly removed after all 4 fix branches were verified and pushed.

### Publication at stop or handoff

**Published head:**
- `origin/fix/session-global-diag-push`: `8f416ad` (PR #6)
- `origin/fix/lsp-queued-cancel`: `34b04f3` (PR #7)
- `origin/fix/api-snapshot-lifecycle`: `ff6ab1b` (PR #8)
- `origin/fix/dirty-syncmap-lifecycle`: `d991656` (PR #9)
- `origin/tla-concurrency-verification`: updated with all 4 green TLA+ models, `run-tlc.sh` (25/25), and this run log.

**Unverified checkpoint:** none.

**Remaining local work:** none.

### Final series review

**Base/head:** base `e0fce98` against PR #6 `8f416ad`, PR #7 `d9f6671` (repaired -> `34b04f3`), PR #8 `6b0b79b` (repaired -> `ff6ab1b`), PR #9 `083885d` (repaired -> `d991656`).

**Contracts:** `robertpenner/TypeScript#1`, `#2`, `#3`, `#4`, `#5`, `verification/tla/ANALYSIS.md`.

**Evidence:** Fresh-context `code-review` subagent reviewed materialized diffs under `/tmp/tla-ts-verification/series-review/` with `provenance.txt`.

**Findings:**
1. PR #6 (`8f416ad`): no actionable findings.
2. PR #7 (non-blocking): unconditional `delete(s.pendingClientRequests, *req.ID)` could delete a reused ID's queued entry. **Resolved** in `34b04f3` by checking `cur.req == req` before deletion and lookup; `./internal/lsp/...` `-race` re-verified (3/3 packages).
3. PR #8 (blocking): `moduleResolverForRequest` deferred `release()` before returning a `module.Resolver` capturing `Host: sd.snapshot`. **Resolved** in `8b598f6` by returning `(module.Resolver, func(), error)` and deferring `release()` in both callers.
4. PR #8 (non-blocking): `Session.Close()` ran `releaseLanguageServerRefs()` before setting `s.closed = true`. **Resolved** in `8b598f6` + `ff6ab1b` by setting `s.closed = true` first and checking `s.closed` before `APIUpdate` in `handleGetCurrentLanguageServerSnapshot`; `./internal/api/...` `-race` re-verified (4/4 packages).
5. PR #9 (blocking): `ChangeIf`, `DeleteIf`, and `lockedEntry.ChangeIf` evaluated `cond` twice on uncontended `true` calls. **Resolved** in `d991656` by only re-evaluating `cond` when `c != e` (lost `LoadOrStore` race), with a new single-evaluation regression test; `./internal/project/... ./internal/ls/autoimport/...` `-race` re-verified (6/6 packages).

**Remaining blockers:** none.

**Completed:** 2026-11-26 16:35:04 UTC

**Duration:** 44m 5s

**Final verification:** `./verification/tla/scripts/run-tlc.sh` — 25/25 expected SANY + TLC verdicts matched (all 4 green models 0 errors, plus all red models); per-PR `go test -race` + `gofmt` + `go vet` passed on every final pushed head (`8f416ad`, `34b04f3`, `ff6ab1b`, `d991656`). Hosted CI checks on fork draft PRs: checked below (not configured/skipped on draft PRs).

**Result:** All 4 slices (`#4`, `#2`, `#3`, `#5`) integrated and verified end-to-end red-to-green with TLC-verified fixed models, `-race`-verified Go fixes and regression tests, fork draft PRs (`#6`–`#9`), and upstream bug-report drafts. Zero halted or blocked tickets.

**Pre-existing unrelated failure(s):** none encountered in the tested packages.
