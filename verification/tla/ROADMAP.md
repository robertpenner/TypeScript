# TLA+ Formal Verification Roadmap (`tsc/internal`)

Branch: `tla-tier2-investigation` (base `3421f17`)
Worktree: `/workspaces/robertpenner/TypeScript-tla-tier2`
Companion reports: [`FINDINGS.md`](./FINDINGS.md) (Tier 1), [`ANALYSIS.md`](./ANALYSIS.md) (Tier 1 architecture analysis), [`FINDINGS-TIER2.md`](./FINDINGS-TIER2.md) (Tier 2 findings), [`GO-ARCHITECTURE.md`](./GO-ARCHITECTURE.md) (target Go concurrency architecture)

## Overview

This roadmap tracks systematic TLA+ formal verification of concurrent protocols across TypeScript 7's Go implementation (`tsc/internal`). It separates ongoing bug discovery from remediation so two workstreams can run in parallel without merge conflicts:

- **Remediation worktree (Tier 1):** fixes the verified Tier 1 defects (`robertpenner/TypeScript#1` through `#5`) directly in `tsc/internal` using red-to-green regression tests.
- **Discovery worktree (`tla-tier2-investigation`, Tier 2+):** audits unmodeled concurrent subsystems, writes TLA+ specs and deterministic `go test -race` reproducers under `verification/tla/`, and leaves `tsc/` unmodified. All Tier 2 outputs append to `FINDINGS-TIER2.md`, `scripts/run-tlc-tier2.sh`, and `scripts/run-repros-tier2.sh`, using `/tmp/tlc-states-tier2` for TLC state files so Tier 1 files stay untouched.

## Per-Target Verification Standard

Every target goes through the same six steps before closing:

1. **Audit synchronization domains:** enumerate mutexes, `sync.RWMutex`, `sync.Once`, `sync.WaitGroup`, `atomic` fields, channels, timers, and spawned goroutines; trace every transition that releases a lock or crosses two synchronization domains.
2. **Extract a minimal TLA+ specification:** model only the state variables and interleaving points present in the Go code under `verification/tla/specs/<Component>/`.
3. **Model-check with official `tla2tools.jar` (TLC2 2.19):** confirm safety invariant violations (TLC exit 12) with minimal counterexample traces, or record bounded verified-safe negative results so false leads are not revisited.
4. **Check upstream novelty:** search `microsoft/TypeScript` issues and PRs so known upstream work is credited and not duplicated.
5. **Confirm with deterministic Go `-race` reproducers:** place standalone tests under `verification/tla/reproducers/` and verify them via `./verification/tla/scripts/run-repros-tier2.sh` (which copies into a temporary `_test.go` file and cleans up `tsc/` on exit).
6. **Document and commit:** record findings, counterexample lengths, reproducer verdicts, and negative checks in `FINDINGS-TIER2.md`, then commit each target as one thematic chunk on `tla-tier2-investigation`.

## Program Phases

### Phase 1: Tier 1 Baseline (Discovery Complete; Remediation In Progress)

Covered 10 components across 8 packages (`tsc/internal` pinned at `e0fce98`):

- **Findings:** 17 verified defects across 9 components (`ExtendedConfigDeadlock`, `LspServerCancel`, `ApiSessionSnapshot`, `SessionGlobalDiag`, `FSWatchDebounce`, `LspWatcher`, `DirtySyncMap`, `ContentMapperHost`, `RefCountCache`).
- **Verified-safe negative checks:** `project.checkerPool` (26.9M+ TLC states) and balanced `RefCountCache.Deref` (42.4M+ TLC states).
- **Status:** Complete for discovery. Top production fixes are underway in the sibling remediation worktree; do not edit Tier 1 specs, `FINDINGS.md`, `run-tlc.sh`, or `run-repros.sh` on this branch.

---

### Phase 2: Tier 2 Investigation (Active on `tla-tier2-investigation`)

Tier 2 targets the highest-risk concurrent protocols outside Tier 1: file-watch orchestration, `tsc -b -w`, project session lifecycle, LSP server orchestration, async IPC, and auto-import indexing.

#### Target 1: `execute/build`, `execute/watchmanager`, and `fswatch` (Complete, commit `0fb5e65`)

- **Audited files:** `tsc/internal/fswatch/watcher.go`, `tsc/internal/fswatch/debounce.go`, `tsc/internal/execute/build/orchestrator.go`, `tsc/internal/execute/build/buildtask.go`, `tsc/internal/execute/watchmanager/`, `tsc/internal/contentmapper/hostimpl.go`.
- **Verified defects (5 TLC violations, 3 confirmed Go `-race` reproducers, all novel upstream):**
  - `FSWatchLifecycle` (3 invariants): concurrent `WatchDirectories` and `watch.Close` across `w.mu`, `dw.mu`, and `b.mu` yields live watches with destroyed `debounce == nil`, torn-down OS subscriptions, and registry eviction.
  - `BuildOrchestratorWatch` (2 invariants): unresolved projects (`task.resolved == nil`) in `tsc -b -w` retain closed `done`/`built` channels across watch cycles, causing a `-race` data race on `task.result`, SIGSEGV in `(*BuildTask).report`, and `panic: close of closed channel`; config reloads (`GenerateGraphReusingOldTasks`) clear `task.upStream` on reused tasks without clearing `task.downStream`, leaking stale `*BuildTask` graphs unboundedly.
- **Verified-safe negative checks:** `computeScheduleOrder` / `waitOnUpstream` DAG scheduling; `contentmapper` lease `sync.Once` close.

#### Target 2: `project` Session, Watch Registry, Caches, and ATA (Complete)

`tsc/internal/project` has the highest synchronization density in `tsc/internal` (44 sync primitives across 16 non-test files, 14 in `session.go` alone).

- **Audited files:** `session.go`, `watch.go`, `ownercache.go`, `snapshot.go`, `snapshotfs.go`, `overlayfs.go`, `project.go`, `checkerpool.go`, `background/queue.go`, `ata/ata.go` (excluding `SessionGlobalDiag` and `DirtySyncMap` covered in Tier 1).
- **Verified defects (4 TLA+ specs, 7 TLC violations, 7 confirmed Go `-race` reproducers, all novel upstream):**
  1. `OwnerCacheRelease` (`InvNoAddOwnerPanic`): `OwnerCache.Release` blindly deletes `identity` from `c.entries` without verifying map-entry identity or prior owner membership; duplicate `Release` calls from `Snapshot.dispose` (when two configs extend the same base config) can evict a newly acquired live entry, causing `Clone` -> `OwnerCache.AddOwner` to panic with `entry not found`.
  2. `SessionWatchProtocol` (3 invariants: `InvNoLeakedClientWatch`, `InvActiveWatcherCovered`, `InvLiveWatcherNotStolen`): unserialized `backgroundQueue` watch updates leak client watches on add/remove RPC inversion; concurrent `Acquire` + partial-failure rollback leaves live projects unwatched with stuck refcount 1; removing (or retrying) a failed/rolled-back watcher does not check `IsPending` and double-releases shared globs, calling `UnwatchFiles` on another live project's watch.
  3. `SessionProgramDiag` (`InvFinalDiagnosticsMatchLatest`): unserialized `publishProgramDiagnostics` on `backgroundQueue` lets an older snapshot overwrite a newer snapshot's cleared `tsconfig.json` diagnostics with stale errors.
  4. `SessionInferredOptions` (2 invariants: `InvNoLostOverlay`, `InvNoNilSnapshotClone`): `DidChangeCompilerOptionsForInferredProjects` skips `s.snapshotUpdateMu`, causing a live Go `-race` data race on `s.compilerOptionsForInferredProjects`, stale-overlay overwrite against concurrent `DidOpenFile`, and a nil-pointer dereference panic in `oldSnapshot.Clone` when racing with or called after `Session.Close()`.
- **Verified-safe negative checks:** `publishProgramDiagnostics` vs `checkerPool.Discard()`; `updateContentMapperRegistrations` (`contentMapperRegistrationMu` + monotonic `snapshot.ID()` guard); `background.Queue` `Enqueue`/`Close` `WaitGroup` protocol.

#### Target 3: `lsp` Server Lifecycle, Queueing, and Progress (In Progress)

`tsc/internal/lsp` has 12 sync primitives across `server.go`, `dynamic_queue.go`, and `progress.go` (excluding `$/cancelRequest` queue residency covered in Tier 1 `LspServerCancel`).

- **Scope:**
  - `lsp/server.go`: `initialize` / `initialized` / `shutdown` / `exit` state transitions, concurrent request dispatch vs shutdown teardown, `watchers` map lifecycle, `pendingServerRequests` correlation, and `client` callback ordering.
  - `lsp/dynamic_queue.go`: `Put`, `Pop`, and close/shutdown signaling under concurrent producers and consumers.
  - `lsp/progress.go`: progress token creation, `ProgressStart` / `ProgressFinish` refcounting, delay timer cancellation, and teardown races.

#### Target 4: `ipc` Async Transport and `ls/autoimport` Registry (Queued)

- **Scope:**
  - `tsc/internal/ipc/conn_async.go`, `conn_sync.go`, `transport.go`: concurrent request multiplexing, response correlation, cancellation and close races, write serialization, and shutdown draining.
  - `tsc/internal/ls/autoimport/registry.go`, `index.go`, `extract.go`: concurrent `Clone` / cache warming (`warmAutoImportCache`), dirty bucket transitions, and shared cache stats or node_modules bucket mutation.

---

### Phase 3: Tier 3 Backlog (Compiler Internals, API Surface, and Core Primitives)

Selected from a repository-wide synchronization census of `tsc/internal` (excluding generated files and tests):

1. **`tsc/internal/api/session.go` (beyond snapshot lookup):** 18 sync sites covering API request dispatch, handle tables, API-supplied filesystem layers, and `Close` teardown outside the Tier 1 `ApiSessionSnapshot` scope.
2. **`tsc/internal/compiler/` (`program.go`, `fileloader.go`, `checkerpool.go`):** 23 sync sites across 5 files covering parallel file loading, lazy program caches, and compiler checker-pool coordination.
3. **`tsc/internal/core/` (`workgroup.go`, `bfs.go`):** 10 sync sites covering `WorkGroup`, `ThrottleGroup` (used by ATA and compiler), panic/error propagation, and parallel BFS termination.
4. **`tsc/internal/execute/incremental/` and `tsc/internal/tsoptions/parsedcommandline.go`:** 17 combined sync sites covering build-info caching and lazy parsed-command-line initialization.
5. **`tsc/internal/contentmapper/hostimpl.go` (remaining lifecycle paths):** server restart, mapper crash recovery, and `Close` outside `projectLease.Transform`.

## Handoff From Discovery to Remediation

At the end of Phase 2 (or after any high-severity Target 2/3/4 milestone):

1. **Triage findings:** classify each verified defect as Tier A (direct production crash, deadlock, leak, or silent stale state) or Tier B (core primitive or exported-API contract violation), matching the structure of `ANALYSIS.md`.
2. **Track remediation issues:** file or update issues on `robertpenner/TypeScript` linking the TLA+ spec, TLC counterexample trace, and Go `-race` reproducer for each cluster of related defects.
3. **Convert reproducers to regression tests:** when a fix branch starts, port each standalone reproducer from `verification/tla/reproducers/` into the target Go package as a permanent `-race` test, verify red-to-green, and add a fixed-model TLA+ `.cfg` proving the invariant holds across the state space.
4. **Upstream reporting (optional, user-directed):** open focused upstream issues or PRs on `microsoft/TypeScript` only for verified novel defects with clean minimal reproducers.

## Out of Scope

- **No `tsc/` edits on `tla-tier2-investigation`:** keeps discovery cleanly separable from fix branches and prevents conflicts with Tier 1 work.
- **No overlap with Tier 1 specs:** `ExtendedConfigDeadlock`, `LspServerCancel`, `ApiSessionSnapshot`, `SessionGlobalDiag`, `FSWatchDebounce`, `LspWatcher`, `DirtySyncMap`, `ContentMapperHost`, `RefCountCache`, and `CheckerPool` are owned by Tier 1 unless a genuinely distinct protocol in the same package is modeled under a new spec name.
- **No generated or test-only code:** skip `diagnostics/loc_generated.go`, `testutil/projecttestutil/clientmock_generated.go`, and `vfs/vfsmock/mock_generated.go`.
