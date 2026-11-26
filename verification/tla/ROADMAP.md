# TLA+ Formal Verification Roadmap (`tsc/internal`)

Branch: `tla-tier2-investigation` (base `3421f17`)
Worktree: `/workspaces/robertpenner/TypeScript-tla-tier2`
Companion reports: [`FINDINGS.md`](./FINDINGS.md) (Tier 1), [`ANALYSIS.md`](./ANALYSIS.md) (Tier 1 architecture analysis), [`FINDINGS-TIER2.md`](./FINDINGS-TIER2.md) (Tier 2 findings), [`ANALYSIS-TIER2.md`](./ANALYSIS-TIER2.md) (Tier 2 root-cause analysis), [`FINDINGS-TIER3.md`](./FINDINGS-TIER3.md) (Tier 3 findings), [`ANALYSIS-TIER3.md`](./ANALYSIS-TIER3.md) (Tier 3 and cross-tier synthesis), [`GO-ARCHITECTURE.md`](./GO-ARCHITECTURE.md) (target Go concurrency architecture)

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

### Phase 2: Tier 2 Investigation (Complete on `tla-tier2-investigation`)

Tier 2 covered the highest-risk concurrent protocols outside Tier 1 across 4 targets: file-watch orchestration, `tsc -b -w`, project session lifecycle, LSP server orchestration, sync/async IPC, and auto-import indexing. Across all 4 targets, Tier 2 produced **11 TLA+ specifications**, **23 verified TLC invariant violations (all exit 12)**, and **21 confirmed `go test -race` reproducers**, all novel upstream.

#### Target 1: `execute/build`, `execute/watchmanager`, and `fswatch` (Complete, commit `0fb5e65`)

- **Audited files:** `tsc/internal/fswatch/watcher.go`, `tsc/internal/fswatch/debounce.go`, `tsc/internal/execute/build/orchestrator.go`, `tsc/internal/execute/build/buildtask.go`, `tsc/internal/execute/watchmanager/`, `tsc/internal/contentmapper/hostimpl.go`.
- **Verified defects (5 TLC violations, 3 confirmed Go `-race` reproducers, all novel upstream):**
  - `FSWatchLifecycle` (3 invariants): concurrent `WatchDirectories` and `watch.Close` across `w.mu`, `dw.mu`, and `b.mu` yields live watches with destroyed `debounce == nil`, torn-down OS subscriptions, and registry eviction.
  - `BuildOrchestratorWatch` (2 invariants): unresolved projects (`task.resolved == nil`) in `tsc -b -w` retain closed `done`/`built` channels across watch cycles, causing a `-race` data race on `task.result`, SIGSEGV in `(*BuildTask).report`, and `panic: close of closed channel`; config reloads (`GenerateGraphReusingOldTasks`) clear `task.upStream` on reused tasks without clearing `task.downStream`, leaking stale `*BuildTask` graphs unboundedly.
- **Verified-safe negative checks:** `computeScheduleOrder` / `waitOnUpstream` DAG scheduling; `contentmapper` lease `sync.Once` close.

#### Target 2: `project` Session, Watch Registry, Caches, and ATA (Complete, commit `31968c9`)

`tsc/internal/project` has the highest synchronization density in `tsc/internal` (44 sync primitives across 16 non-test files, 14 in `session.go` alone).

- **Audited files:** `session.go`, `watch.go`, `ownercache.go`, `snapshot.go`, `snapshotfs.go`, `overlayfs.go`, `project.go`, `checkerpool.go`, `background/queue.go`, `ata/ata.go` (excluding `SessionGlobalDiag` and `DirtySyncMap` covered in Tier 1).
- **Verified defects (4 TLA+ specs, 7 TLC violations, 7 confirmed Go `-race` reproducers, all novel upstream):**
  1. `OwnerCacheRelease` (`InvNoAddOwnerPanic`): `OwnerCache.Release` blindly deletes `identity` from `c.entries` without verifying map-entry identity or prior owner membership; duplicate `Release` calls from `Snapshot.dispose` (when two configs extend the same base config) can evict a newly acquired live entry, causing `Clone` -> `OwnerCache.AddOwner` to panic with `entry not found`.
  2. `SessionWatchProtocol` (3 invariants: `InvNoLeakedClientWatch`, `InvActiveWatcherCovered`, `InvLiveWatcherNotStolen`): unserialized `backgroundQueue` watch updates leak client watches on add/remove RPC inversion; concurrent `Acquire` + partial-failure rollback leaves live projects unwatched with stuck refcount 1; removing (or retrying) a failed/rolled-back watcher does not check `IsPending` and double-releases shared globs, calling `UnwatchFiles` on another live project's watch.
  3. `SessionProgramDiag` (`InvFinalDiagnosticsMatchLatest`): unserialized `publishProgramDiagnostics` on `backgroundQueue` lets an older snapshot overwrite a newer snapshot's cleared `tsconfig.json` diagnostics with stale errors.
  4. `SessionInferredOptions` (2 invariants: `InvNoLostOverlay`, `InvNoNilSnapshotClone`): `DidChangeCompilerOptionsForInferredProjects` skips `s.snapshotUpdateMu`, causing a live Go `-race` data race on `s.compilerOptionsForInferredProjects`, stale-overlay overwrite against concurrent `DidOpenFile`, and a nil-pointer dereference panic in `oldSnapshot.Clone` when racing with or called after `Session.Close()`.
- **Verified-safe negative checks:** `publishProgramDiagnostics` vs `checkerPool.Discard()`; `updateContentMapperRegistrations` (`contentMapperRegistrationMu` + monotonic `snapshot.ID()` guard); `background.Queue` `Enqueue`/`Close` `WaitGroup` protocol.

#### Target 3: `lsp` Server Lifecycle, Progress Actor, and Watch Registry (Complete, commit `ed2bf53`)

`tsc/internal/lsp` has 12 sync primitives across `server.go`, `dynamic_queue.go`, and `progress.go` (excluding `$/cancelRequest` queue residency covered in Tier 1 `LspServerCancel`).

- **Audited files:** `server.go`, `progress.go`, `logger.go`, `dynamic_queue.go`, `lsproto/baseproto.go`.
- **Verified defects (3 TLA+ specs, 7 TLC violations, 7 confirmed Go `-race` reproducers, all novel upstream):**
  1. `LspProgressLocale` (2 invariants: `InvNoLocaleDataRace`, `InvProgressEndsWhenIdle`): `serverProgressReporter.localize` reads `r.server.locale` without `localeMu.RLock()` (live Go `-race` data race with `Server.SetLocale`); `projectLoadingProgress.run` keys its ref-counted `loading` map by the localized string, so a locale change between `ProgressStart` and `ProgressFinish` leaks the old entry and permanently suppresses `WorkDoneProgressEnd`.
  2. `LspServerLifecycle` (3 invariants: `InvNoPreInitNilSessionPanic`, `InvNoPostShutdownNilSnapshotPanic`, `InvNoDuplicateInitializedPanic`): document request registrars (`registerLanguageServiceDocumentRequestHandler`, `WithAutoImports`, `MultiProjectReference`) omit the `s.session == nil` guard (crashing `dispatchLoop` on pre-`initialized` requests); `handleShutdown` closes `s.session` (`snapshot = nil`) without rejecting subsequent requests or draining in-flight async handlers (crashing `dispatchLoop` on post-`shutdown` requests); `handleInitialized` closes `s.initComplete` without a `sync.Once`/idempotency guard (crashing `dispatchLoop` with `panic: close of closed channel` on duplicate `initialized`).
  3. `LspWatchRegistry` (2 invariants: `InvTimedOutWatchCanBeUnwatched`, `InvNoDuplicateUnwatch`): `Server.WatchFiles` only adds `id` to `s.watchers` after `sendClientRequest` succeeds, so a timed-out request installed by a slow client can never be unwatched (`"no file watcher exists with ID ..."`); `Server.UnwatchFiles` checks `s.watchers.Has(id)` before the unlocked RPC and deletes afterward, letting concurrent calls send duplicate `client/unregisterCapability` RPCs.
- **Verified-safe negative checks:** `pendingServerRequests` lock-protected channel close/delete; `handleInitialized` calling `sendClientRequest` while `readLoop` routes responses independently; `projectLoadingProgress.stopDelay` setting `delay = nil`.

#### Target 4: `ipc` Sync/Async Transport and `ls/autoimport` Registry (Complete, commit `616a404`)

- **Audited files:** `tsc/internal/ipc/conn_sync.go`, `conn_async.go`, `transport.go`, `tsc/internal/ls/autoimport/registry.go`, `specifiers.go`, `view.go`, `extract.go`, `tsc/internal/project/session.go` (`GetLanguageServiceWithAutoImports`, `warmAutoImportCache`), `tsc/internal/binder/binder.go`.
- **Verified defects (2 TLA+ specs, 4 TLC violations, 4 confirmed Go `-race` reproducers, all novel upstream):**
  1. `IpcSyncConn` (2 invariants: `NoCrossCallResponseSwap`, `NoOrphanedResponsePoison`): `SyncConn.Call` uses `method` as the request ID and drops `c.reading` / unlocks `c.mu` on incoming notifications, allowing a concurrent caller for the same method to send a request and silently swap responses with `err == nil` (persists after `microsoft/TypeScript#64639`); `Call` also writes the request onto the pipe before checking `ctx.Err()`, so a cancelled call leaves an orphaned response that kills `SyncConn.Run()` with `ipc: unexpected response message in sync connection`.
  2. `AutoImportRegistry` (2 invariants: `CleanSessionBucketIsComplete`, `LiveBucketExportsHaveEntrypoints`): `buildProjectBucket` omits `result.err = ctx.Err()` after `wg.Wait()` and `Session.GetLanguageServiceWithAutoImports` adopts the snapshot without checking `ctx.Err()`, permanently committing a 0-export clean project bucket into `Session.snapshot`; `Registry.entrypoints` is keyed solely by `ResolvedPath` across all `node_modules` buckets, so dropping a symlinked workspace package from one bucket deletes the shared entrypoint for another untouched bucket, bypassing `"exports"` condition checks and leaking an illegal relative path into `dist/`.
- **Verified-safe negative checks:** `ipc.AsyncConn` monotonic ID + `pendingMu`/`writeMu` teardown; `binder.BindSourceFile` `file.BindOnce` guard; `warmAutoImportCache` `ctx.Err()` check before adoption.

---

### Phase 3: Tier 3 Investigation (Complete on `tla-tier2-investigation`)

Phase 3 audited all remaining unmodeled packages in `tsc/internal` with concurrency primitives (`api`, `contentmapper`, `compiler`, `core`, `execute/incremental`, `ls`, `checker`, `project/logging`, `ast`, `tsoptions`). Across all remaining packages, Tier 3 produced **3 TLA+ specifications**, **7 verified TLC invariant violations (all exit 12)**, **4 exhaustive fixed-model TLC proofs (exit 0)**, and **7 confirmed `go test -race` reproducers**, all novel upstream:

1. **`ApiSessionLifecycle` (`tsc/internal/api/session.go`, 3 violations + 1 fixed proof, 3/3 reproducers):**
   - `NoPostCloseLspRefLeak`: `Session.Close()` releases LSP references under `languageServerUpdateMu` without setting a closed guard, allowing a concurrent `handleGetCurrentLanguageServerSnapshot` to leak open projects, files, or synthetic programs into the shared LSP `project.Session` permanently.
   - `NoPostCloseLeaseLeak`: `registerSourceFileLease` inserts into `s.sourceFileLeases` under `sourceFileLeasesMu` without checking whether `releaseSourceFileLeases()` already ran, pinning `*ast.SourceFile` refcounts in `parseCache`.
   - `NoPostCloseBatchPageLeak`: `paginateBatchResponses` stores continuation pages into `s.batchResponsePages` with no closed check against `s.batchResponsePages.Clear()` in `Close()`.
   - Additional code-audit finding: `Session.Close()` never stops an active `s.cpuProfiler` on mid-profile disconnect.
2. **`ContentMapperTransformClose` (`tsc/internal/contentmapper/hostimpl.go`, 2 violations + 1 fixed proof, 2/2 reproducers):**
   - `NoNilProjectDeref`: `host.Close()` sets `h.projects = nil`, causing `host.Project` to return `nil`, and `host.Transform` panics dereferencing `project` (still present after `microsoft/TypeScript#65492`).
   - `NoLeakedConnRef`: `host.Project` does not deduplicate repeated `*Mapper` pointers in `spec.Mappers` (unlike `host.Acquire`), overwriting `lease.entries[mapper]` and permanently leaking `h.projects` entries and `connEntry.refs`.
3. **`CompilerFilesParserDepth` (`tsc/internal/compiler/filesparser.go`, 2 violations + 2 fixed proofs, 2/2 reproducers):**
   - `LoadedFileStartsSubtasks`: `filesParser.start()` mutates `data.lowestDepth` and `data.startedSubTasks` before checking `if task.elideOnDepth && currentDepth > w.maxDepth { return }`, silently dropping transitive imports and references when an elided `node_modules` JS arrival reaches a file before a non-elided arrival at the same depth (missed in `microsoft/TypeScript#64632`).
   - `LowestNonElidedDepthReached`: an elided arrival at depth `d` (`> maxDepth`) lowers `data.lowestDepth` from a deeper non-elided depth without restarting subtasks, blocking a later non-elided arrival at depth `d` from restarting them.
- **Verified-safe / clean-audit packages (7 packages):** `core` (`workgroup.go`, `bfs.go`), `execute/incremental`, `ls` (outside `autoimport`), `checker`, `project/logging`, `ast`, and `tsoptions`.

### Cross-Tier Rollup (Phases 1 through 3 Complete)

| Phase | Specs | Verified Defects | Go `-race` Reproducers | Trigger `-race` | Race-Free Protocol Bugs | Epic & Tickets |
|---|---|---|---|---|---|---|
| Tier 1 | 10 (9 buggy + `CheckerPool`) | 17 | 19 | 1 | 16 | `robertpenner/TypeScript#1` (`#2`–`#5`) |
| Tier 2 | 11 | 23 | 21 | 3 | 20 | `robertpenner/TypeScript#10` (`#11`–`#19`) |
| Tier 3 | 3 | 7 | 7 | 0 | 7 | `robertpenner/TypeScript#20` (`#21`–`#23`) |
| **Total** | **24** | **47** | **47** | **4 (8.5%)** | **43 (91.5%)** | **3 epics, 16 tickets** |

## Handoff From Discovery to Remediation

Phase 2 and Phase 3 discovery findings are triaged into clustered remediation tickets on `robertpenner/TypeScript` under parent epics `robertpenner/TypeScript#10` (Tier 2: 9 tickets, 23 defects) and `robertpenner/TypeScript#20` (Tier 3: 3 tickets, 7 defects):

- **Tier 3 (all 3 tickets have exit-0 fixed TLC proofs ready):**
  - `robertpenner/TypeScript#23`: `compiler.filesParser` `elideOnDepth` guard ordering (`CompilerFilesParserDepth`, Findings #6–#7)
  - `robertpenner/TypeScript#21`: `contentmapper.host` `Transform` nil-project dereference after `Close` and duplicate `Mapper` leak (`ContentMapperTransformClose`, Findings #4–#5)
  - `robertpenner/TypeScript#22`: `api.Session` post-close leaks across LSP refs, source file leases, batch pages, and unstopped `cpuProfiler` (`ApiSessionLifecycle`, Findings #1–#3)
- **Tier 2 Wave 1 (unrecovered panics, SIGSEGV, silent wire corruption):**
  - `robertpenner/TypeScript#16`: `lsp.Server` lifecycle panics (`LspServerLifecycle`, Findings #15–#17)
  - `robertpenner/TypeScript#12`: `tsc -b -w` unresolved-project double-close panic/SIGSEGV and stale downstream leak (`BuildOrchestratorWatch`, Findings #4–#5)
  - `robertpenner/TypeScript#13`: `OwnerCache.Release` blind delete `AddOwner` panic (`OwnerCacheRelease`, Finding #6)
  - `robertpenner/TypeScript#18`: `ipc.SyncConn` notification response swap and cancel response orphan (`IpcSyncConn`, Findings #20–#21)
- **Tier 2 Wave 2 (`-race` data races, cache poisoning, watch & diagnostics correctness):**
  - `robertpenner/TypeScript#15`: `project.Session` out-of-order program diagnostics and unsynchronized `DidChangeCompilerOptionsForInferredProjects` (`SessionProgramDiag` + `SessionInferredOptions`, Findings #10–#12)
  - `robertpenner/TypeScript#19`: `ls/autoimport` cancelled `buildProjectBucket` clean-commit poisoning and cross-bucket `Registry.entrypoints` clobber (`AutoImportRegistry`, Findings #22–#23)
  - `robertpenner/TypeScript#17`: `lsp.Server` progress locale data race/stuck spinner and watch registry timeout/duplicate unwatch (`LspProgressLocale` + `LspWatchRegistry`, Findings #13–#14, #18–#19)
  - `robertpenner/TypeScript#14`: `project.Session` watch protocol leaks, rollback stranding, and live-watch theft (`SessionWatchProtocol`, Findings #7–#9)
  - `robertpenner/TypeScript#11`: `FSWatchLifecycle` 3-lock TOCTOU (`FSWatchLifecycle`, Findings #1–#3)

Remediation workflow for each ticket:

1. **Triage findings:** classify each verified defect as Tier A (direct production crash, deadlock, leak, or silent stale state) or Tier B (core primitive or exported-API contract violation), matching the structure of `ANALYSIS.md`.
2. **Track remediation issues:** file or update issues on `robertpenner/TypeScript` linking the TLA+ spec, TLC counterexample trace, and Go `-race` reproducer for each cluster of related defects.
3. **Convert reproducers to regression tests:** when a fix branch starts, port each standalone reproducer from `verification/tla/reproducers/` into the target Go package as a permanent `-race` test, verify red-to-green, and add a fixed-model TLA+ `.cfg` proving the invariant holds across the state space.
4. **Upstream reporting (optional, user-directed):** open focused upstream issues or PRs on `microsoft/TypeScript` only for verified novel defects with clean minimal reproducers.

## Out of Scope

- **No `tsc/` edits on `tla-tier2-investigation`:** keeps discovery cleanly separable from fix branches and prevents conflicts with Tier 1 work.
- **No overlap with Tier 1 specs:** `ExtendedConfigDeadlock`, `LspServerCancel`, `ApiSessionSnapshot`, `SessionGlobalDiag`, `FSWatchDebounce`, `LspWatcher`, `DirtySyncMap`, `ContentMapperHost`, `RefCountCache`, and `CheckerPool` are owned by Tier 1 unless a genuinely distinct protocol in the same package is modeled under a new spec name.
- **No generated or test-only code:** skip `diagnostics/loc_generated.go`, `testutil/projecttestutil/clientmock_generated.go`, and `vfs/vfsmock/mock_generated.go`.
