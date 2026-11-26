# TLA+ Formal Verification Findings — Tier 2 Investigation

Branch: `tla-tier2-investigation` (base `3421f17`)
Tooling: Official `tla2tools.jar` (TLC2 Version 2.19) + Go 1.27.1 (`go test -race`)

Run all Tier 2 TLC checks:
```bash
./verification/tla/scripts/run-tlc-tier2.sh
```

Run all Tier 2 Go `-race` reproducers:
```bash
./verification/tla/scripts/run-repros-tier2.sh
```

## Summary Table

| # | Spec | Target Code | Invariant / Failure | TLC Verdict | Go `-race` Reproducer | Upstream Status |
|---|---|---|---|---|---|---|
| 1 | `FSWatchLifecycle` | `tsc/internal/fswatch/watcher.go` | `LiveWatchHasDebounce` — concurrent `WatchDirectories` + `watch.Close()` returns a live `Watch` (`err == nil`) whose `dw.debounce` was destroyed (`nil`); all future events silently dropped | Exit 12 (8 states, 40 generated / 28 distinct) | `TestReproFSWatchLifecycleDeadDebounceAndOrphanedWatch` (`FAIL`) | Novel (note `microsoft/TypeScript#64459` tracks publishing `fswatch`) |
| 2 | `FSWatchLifecycle` | `tsc/internal/fswatch/watcher.go` | `LiveWatchHasOSSubscription` — `watch.Close()` calls `impl.watchRemove(dw)` after a concurrent `WatchDirectories` already saw `dw` subscribed in `watchAddMany`, tearing down the OS subscription while the new watch is live | Exit 12 (7 states, 40 generated / 28 distinct) | TLC counterexample (same 3-lock TOCTOU family as #1) | Novel |
| 3 | `FSWatchLifecycle` | `tsc/internal/fswatch/watcher.go` | `LiveWatchInRegistry` — `removeDirWatch` deletes `dw` from `w.dirWatches` and destroys its debounce while or after a concurrent `WatchDirectories` holds `dw` live | Exit 12 (8 states, 40 generated / 28 distinct) | `TestReproFSWatchLifecycleDeadDebounceAndOrphanedWatch` (`FAIL`) | Novel |
| 4 | `BuildOrchestratorWatch` | `tsc/internal/execute/build/orchestrator.go`, `buildtask.go` | `NoChannelDoubleClose` — in `tsc -b -w` with an unresolved project (`task.resolved == nil`) alongside a valid project, editing a source file skips recreating `task.done`/`task.built`, causing a data race on `task.result`, a SIGSEGV in `(*BuildTask).report`, and `panic: close of closed channel` in `unblockDownstream` | Exit 12 (6 states, 11 generated / 10 distinct) | `TestReproBuildWatchUnresolvedProjectDoubleClosePanic` (`DATA RACE` + `SIGSEGV`/panic crash) | Novel |
| 5 | `BuildOrchestratorWatch` | `tsc/internal/execute/build/orchestrator.go` | `DownstreamNoStaleOrDuplicates` — `createBuildTasks` resets `task.upStream = nil` on reused non-dirty tasks during config reload (`GenerateGraphReusingOldTasks`), but never resets `task.downStream`; `setupBuildTask` appends new downstream tasks on every reload, retaining stale replaced `*BuildTask` pointers unboundedly | Exit 12 (6 states, 10 generated / 9 distinct) | `TestReproBuildWatchDownstreamUnboundedDuplicationAndStaleRetention` (`FAIL`) | Novel |
| 6 | `OwnerCacheRelease` | `tsc/internal/project/ownercache.go`, `snapshot.go` | `InvNoAddOwnerPanic` — `OwnerCache.Release` deletes `identity` from `c.entries` without verifying map-entry identity or prior owner membership; when two configs in a snapshot extend the same base config, `Snapshot.dispose` calls `Release` twice, letting a delayed 2nd `Release` evict a newly inserted live entry and causing the next `Clone` to hit `panic("OwnerCache.AddOwner: entry not found")` | Exit 12 (9 states, 39 generated / 26 distinct) | `TestReproOwnerCacheReleaseBlindDeleteCausesAddOwnerPanic` (`FAIL`) | Novel (distinct from `microsoft/TypeScript#65302` cyclic-extends deadlock) |
| 7 | `SessionWatchProtocol` | `tsc/internal/project/session.go`, `watch.go` | `InvNoLeakedClientWatch` — `backgroundQueue.Enqueue` runs `updateWatches` concurrently across snapshots; `S1->S2` can run `Release` + `UnwatchFiles(id)` before `S0->S1` completes `WatchFiles(id)`, permanently leaking an active client watch with no registry entry | Exit 12 (4 states, 13 generated / 11 distinct) | `TestReproSessionWatchLeakedClientWatchOnAddRemove` (`FAIL`) | Novel |
| 8 | `SessionWatchProtocol` | `tsc/internal/project/session.go`, `watch.go` | `InvActiveWatcherCovered` — while `T1` is blocked in `WatchFiles(G)` after `Acquire` (`0->1`), `T2` calls `Acquire(G)` (`1->2`, `isNew=false`), skips `WatchFiles`, and clears pending; when `T1` fails and rolls back `Release(G)` (`2->1`), `T2` is left live and non-pending with refcount 1 and zero client watches | Exit 12 (5 states, 17 generated / 13 distinct) | `TestReproSessionWatchConcurrentAcquireFailStrandsLiveProject` (`FAIL`) | Novel |
| 9 | `SessionWatchProtocol` | `tsc/internal/project/session.go`, `watch.go` | `InvLiveWatcherNotStolen` — when a watcher whose `WatchFiles` failed and rolled back (`IsPending == true`) is later removed (or retried), `updateWatch` still runs `if oldWatcher != nil { s.watches.Release(...) }`, double-releasing the shared glob and calling `UnwatchFiles` on another live project's watch | Exit 12 (3 states, 3 generated / 3 distinct) | `TestReproSessionWatchFailedThenRemovedStealsLiveWatch` (`FAIL`) | Novel |
| 10 | `SessionProgramDiag` | `tsc/internal/project/session.go` | `InvFinalDiagnosticsMatchLatest` — `publishProgramDiagnostics` runs on `backgroundQueue` without snapshot-order serialization or a staleness check; an older snapshot's `PublishDiagnostics(tsconfig, [err])` arriving after a newer snapshot's `PublishDiagnostics(tsconfig, [])` permanently restores stale diagnostics | Exit 12 (3 states, 6 generated / 5 distinct) | `TestReproSessionProgramDiagOutOfOrderStaleOverwrite` (`FAIL`) | Novel |
| 11 | `SessionInferredOptions` | `tsc/internal/project/session.go` | `InvNoLostOverlay` — `DidChangeCompilerOptionsForInferredProjects` skips `s.snapshotUpdateMu`, writes `s.compilerOptionsForInferredProjects` unsynchronized (Go `-race` DATA RACE), and reads `s.fs.Overlays()` unlocked; concurrent `DidOpenFile` can install a newer snapshot that `DidChangeCompilerOptionsForInferredProjects` then overwrites with stale overlays | Exit 12 (5 states, 19 generated / 14 distinct) | `TestReproSessionDidChangeInferredOptionsDataRace` (`DATA RACE`) | Novel |
| 12 | `SessionInferredOptions` | `tsc/internal/project/session.go` | `InvNoNilSnapshotClone` — because `DidChangeCompilerOptionsForInferredProjects` skips `s.snapshotUpdateMu` and `updateSnapshot` does not guard `oldSnapshot == nil`, calling it concurrently with or after `Session.Close()` (which sets `s.snapshot = nil`) panics with a nil pointer dereference in `oldSnapshot.Clone` | Exit 12 (4 states, 9 generated / 7 distinct) | `TestReproSessionDidChangeInferredOptionsNilSnapshotPanic` (`FAIL`, caught nil deref panic) | Novel |

## Target #1: `execute/build`, `execute/watchmanager`, and `fswatch`

### 1. `FSWatchLifecycle` (`tsc/internal/fswatch/watcher.go`)

**Protocol:** `watcher.WatchDirectories` (`watcher.go:539-578`) and `watch.Close` (`watcher.go:629-643`) coordinate across three separate mutexes that are each acquired and released independently:
1. `w.mu` protecting `w.dirWatches` (`getOrCreateDirWatch` at lines 413-456, `removeDirWatch` at lines 458-466),
2. `dw.mu` protecting `dw.callbacks` and `dw.debounce` (`addCallback`, `unwatch` at lines 1158-1167, `unref` at lines 1169-1176),
3. `b.mu` protecting `b.subscriptions` and OS watch handles (`watchAddMany` at lines 730-775, `watchRemove` at lines 777-795).

Because `watch.Close()` unlocks `dw.mu` between `dw.unwatch`, `impl.watchRemove(dw)`, `dw.unref(w)`, and `w.removeDirWatch(dw)` — and `WatchDirectories` unlocks `w.mu` between `getOrCreateDirWatch`, `dw.addCallback`, and `impl.watchAddMany` — three distinct safety violations arise on concurrent close + re-watch of the same directory:
- **Dead debounce (`LiveWatchHasDebounce`):** H1 calls `unwatch` (`last=true`) -> `watchRemove` -> `unref` (sees `len(callbacks)==0`), H2 calls `getOrCreateDirWatch` (returns `dw1`), H1 calls `removeDirWatch` (`delete(w.dirWatches, dir)` and `dw1.destroyDebounce()` setting `dw1.debounce = nil`), then H2 calls `addCallback` + `watchAddMany`. `WatchDirectory` returns a live `Watch` with `err == nil`, yet `dw1.notify()` sees `dw1.debounce == nil` and silently drops every future event.
- **OS watch torn down while live (`LiveWatchHasOSSubscription`):** H2 calls `getOrCreateDirWatch` (`dw1`), H1 calls `unwatch` (`last=true`), H2 calls `addCallback` + `watchAddMany` (sees `dw1` already in `b.subscriptions`, returns `nil`), then H1 calls `watchRemove` (unsubscribes `dw1` from the OS) and `unref` (sees H2's callback, skips `removeDirWatch`). H2 holds a live `Watch` with no OS subscription.
- **Orphaned live watch (`LiveWatchInRegistry`):** Same TOCTOU window lets `removeDirWatch` evict `dw1` from `w.dirWatches` and destroy `dw1.debounce` after H2 has already attached its callback or returned to the caller.

### 2. `BuildOrchestratorWatch` (`tsc/internal/execute/build/orchestrator.go`, `buildtask.go`)

**Protocol:** Watch-mode `DoCycle` (`orchestrator.go:916-945`) inspects file events in `checkTasksForEventChanges` (`orchestrator.go:595-750`), optionally rebuilds the graph via `GenerateGraphReusingOldTasks` (`orchestrator.go:283-305`), and runs `buildOrClean` -> `buildOrCleanOrder` (`orchestrator.go:986-1025`), which spawns a reporter goroutine waiting on `<-task.done` concurrently with `rangeTasks` executing `buildOrCleanProject` (`orchestrator.go:1060-1080`).

Two defects occur in real `tsc -b -w` sessions:
- **Unresolved project stale closed channels (`NoChannelDoubleClose`):** In `checkTasksForEventChanges` (`orchestrator.go:609-611`), `if task.resolved == nil { continue }` returns early before lines 723-724 (`task.built = make(chan struct{}); task.done = make(chan struct{})`). When a watch build has a missing/unresolved project alongside a valid project, editing a source file in the valid project sets `needsUpdate = true, needsConfigUpdate = false`. `buildOrClean` runs on every task in `order`, including the unresolved task whose `done` and `built` channels are still closed from cycle 1. The reporter goroutine (`orchestrator.go:996`) immediately returns from `<-task.done` and races with `buildOrCleanProject` (`orchestrator.go:1062`) on `task.result` (triggering `-race` DATA RACE and a nil-pointer SIGSEGV in `(*BuildTask).report`), while `buildOrCleanProject`'s deferred `unblockDownstream()` (`buildtask.go:113`) attempts `close(t.done)` on the already-closed channel.
- **Unbounded stale `downStream` accumulation (`DownstreamNoStaleOrDuplicates`):** During a config reload in watch mode (`GenerateGraphReusingOldTasks` -> `createBuildTasks`), reused non-dirty tasks reset `task.upStream = nil` (`orchestrator.go:220`) but never clear `task.downStream`. `setupBuildTask` (`orchestrator.go:277`) then executes `task.downStream = append(task.downStream, downStream)`. Every reload of a downstream `tsconfig.json` appends a new `*BuildTask` to the reused upstream task's `downStream` slice without removing the replaced `*BuildTask` pointers, retaining old `BuildTask`/`ParsedCommandLine`/`buildInfoEntry` graphs indefinitely and running `updateDownstream` against stale tasks.

### Target #1 Negative / Verified-Safe Checks

- `computeScheduleOrder` + `rangeTasks` + `waitOnUpstream`: topological depth ordering assigns strictly increasing schedule indices along DAG edges (and cycles record `o.errors` and skip execution), so the fixed worker pool cannot deadlock waiting on upstream `built` channels.
- `createBuildTasks` concurrent `existing.contentMapperProject.Close()`: both `projectLease.Close()` (`contentmapper/hostimpl.go:692`) and `retainedProject.Close()` (`contentmapper/hostimpl.go:841`) wrap teardown in `sync.Once`.
- `fswatch/debounce.go` (`fireCallbacks` vs `latchReset`): already modeled and reproduced in Tier 1 (`FSWatchDebounce.tla`).
- `parseCache.go`: `defer newEntry.mu.Unlock()` evaluates the receiver at defer time, so reassigning `newEntry = entry` does not leak or mismatch locks.

## Target #2: `project` Session, Watch Registry, Caches, and Inferred Options

### 3. `OwnerCacheRelease` (`tsc/internal/project/ownercache.go`, `snapshot.go`)

**Protocol:** `OwnerCache.Release(identity, owner)` (`ownercache.go:79-91`) loads `entry` from `c.entries` (`sync.Map`), locks `entry.mu`, executes `delete(entry.owners, owner)`, and if `len(entry.owners) == 0` calls `c.entries.Delete(identity)` unconditionally (not `CompareAndDelete` and without checking whether `owner` was actually in `entry.owners`). In `Snapshot.dispose()` (`snapshot.go:797-804`), every config in `ConfigFileRegistry.configs` iterates its `ExtendedSourceFiles()` and calls `extendedConfigCache.Release(extFile, s.id)`.

**Defect (`InvNoAddOwnerPanic`):** In any monorepo where at least two `tsconfig.json` files extend the same base `tsconfig.base.json`, disposing snapshot `S1` calls `Release(K, S1)` twice. If `S1`'s 2nd `Release` loads old entry `E1` and pauses before `E1.mu.Lock()`, while `S2.dispose()` empties `E1` and removes `K` from `c.entries`, and `S3` acquires `K` inserting a new live entry `E2`, then `S1`'s 2nd `Release` acquires `E1.mu`, sees `len(E1.owners) == 0`, and blindly calls `c.entries.Delete(K)`, deleting `E2`. When `S3` is cloned into `S4`, `Snapshot.Clone` calls `extendedConfigCache.AddOwner(K, S4)` (`snapshot.go:728-735`), which panics with `OwnerCache.AddOwner: entry not found` (`ownercache.go:63`).

### 4. `SessionWatchProtocol` (`tsc/internal/project/session.go`, `watch.go`)

**Protocol:** `Session.updateSnapshot` enqueues `updateWatches(oldSnapshot, newSnapshot)` onto `s.backgroundQueue` (`session.go:1428-1455`). `background.Queue.Enqueue` (`background/queue.go:33-49`) launches an independent goroutine per task with no serialization between consecutive snapshots (unlike `updateContentMapperRegistrations`, which holds `s.contentMapperRegistrationMu` and checks `snapshot.ID()`). Inside `updateWatch` (`session.go:1510-1595`), `watchRegistry.Acquire`/`Release` (`watch.go:53-81`) update refcounts under `r.mu`, then invoke `s.client.WatchFiles`/`UnwatchFiles` unlocked.

Three independent safety invariants fail:
- **Leaked client watch on concurrent add/remove (`InvNoLeakedClientWatch`):** Task `T1` (`S0 -> S1`) acquires glob `G` under ID `id1` and enters `WatchFiles(id1)`. Before `WatchFiles(id1)` completes, `S1 -> S2` closes the project and task `T2` calls `Release(G)` (`1 -> 0`) + `UnwatchFiles(id1)`. When `T1`'s `WatchFiles(id1)` completes afterward, the client holds a permanent watch for `id1` while `watchRegistry` has no record of it.
- **Live project permanently unwatched after concurrent `Acquire` + rollback (`InvActiveWatcherCovered`):** `T1` (project `p1`) acquires shared glob `G` (`0 -> 1`, `isNew=true`) and blocks in `WatchFiles(id1)`. Concurrently, `T2` (project `p2`) acquires `G` (`1 -> 2`, `isNew=false`), skips `WatchFiles`, and clears `p2` from `pending`. `T1`'s `WatchFiles(id1)` then fails (e.g., timeout) and rolls back `Release(G)` (`2 -> 1`, not removed), marking only `p1` pending. `p2` is live and non-pending, `watchRegistry[G].count == 1` (preventing any future project from registering `G`), and the client has zero active watches for `G`.
- **Removing a failed/rolled-back watcher steals a live project's watch (`InvLiveWatcherNotStolen`):** Project `p1` fails `WatchFiles(G)`, rolls back its `Acquire(G)` (`1 -> 0`), and is marked pending. Project `p2` opens and registers `G` (`0 -> 1`, client holds `p2`'s watch ID). When `p1` is later closed (or retried), `updateWatch(ctx, p1Watch, nil)` does not check `IsPending(p1)` before executing `if oldWatcher != nil { s.watches.Release(watcher) }`, so `p1` double-releases `G` (`1 -> 0`) and invokes `UnwatchFiles` on `p2`'s live watcher IDs while `p2` is still open.

### 5. `SessionProgramDiag` (`tsc/internal/project/session.go`)

**Protocol:** `Session.updateSnapshot` enqueues `publishProgramDiagnostics(oldSnapshot, newSnapshot)` on `s.backgroundQueue` (`session.go:1428-1455`, `1902-1965`) with no serialization mutex and no snapshot-ID staleness check.

**Defect (`InvFinalDiagnosticsMatchLatest`):** Task `T1` (`S0 -> S1`, opened configured project with a `tsconfig.json` diagnostic) starts `PublishDiagnostics(tsconfig.json, [err])` and pauses in flight while `S1 -> S2` (project closed or fixed) runs task `T2` and completes `PublishDiagnostics(tsconfig.json, [])`. When `T1` finishes afterward, it overwrites the cleared diagnostics on the client with stale errors (`publish len sequence: [0 1]`).

### 6. `SessionInferredOptions` (`tsc/internal/project/session.go`)

**Protocol:** Every other snapshot mutator in `Session` holds `s.snapshotUpdateMu` around `flushChanges` and `updateSnapshot`. `Session.DidChangeCompilerOptionsForInferredProjects` (`session.go:500-506`) skips `s.snapshotUpdateMu` completely: it assigns `s.compilerOptionsForInferredProjects = options` unsynchronized, calls `s.UpdateSnapshot(ctx, s.fs.Overlays(), SnapshotChange{...})` reading `s.fs.Overlays()` unlocked, and `updateSnapshot` (`session.go:1393-1425`) swaps `s.snapshot` without holding `s.snapshotUpdateMu` or checking `oldSnapshot == nil`.

Two defects follow:
- **Data race and stale-overlay overwrite (`InvNoLostOverlay`):** Two concurrent calls to `DidChangeCompilerOptionsForInferredProjects` trigger a live Go `-race` `WARNING: DATA RACE` on `s.compilerOptionsForInferredProjects` (`session.go:501`). Running concurrently with `DidOpenFile` lets `DidChangeCompilerOptionsForInferredProjects` capture pre-open overlays, clone an older snapshot, and overwrite `s.snapshot` after `DidOpenFile` already committed the new overlay.
- **Nil-pointer panic against `Close()` (`InvNoNilSnapshotClone`):** `Session.Close()` (`session.go:1725-1734`) sets `s.snapshot = nil` under `s.snapshotUpdateMu`. Because `DidChangeCompilerOptionsForInferredProjects` skips `s.snapshotUpdateMu` and `updateSnapshot` does not check `oldSnapshot == nil`, any concurrent or post-close call panics with a nil-pointer dereference in `oldSnapshot.Clone`.

### Target #2 Negative / Verified-Safe Checks

- `publishProgramDiagnostics` vs `Snapshot.dispose` (`checkerPool.Discard`): `publishProgramDiagnostics` reads diagnostics from `newSnapshot` asynchronously, and even if `newSnapshot` is disposed while `publishProgramDiagnostics` runs, `checkerPool.Discard()` leaves `GetGlobalDiagnostics()` / `GetConfigFileParsingDiagnostics()` safe without panicking on a disposed pool.
- `updateContentMapperRegistrations` (`session.go:1596-1626`): properly serialized with `s.contentMapperRegistrationMu` and guarded by `snapshot.ID() < s.registeredContentMapperSnapshotID` (unlike `updateWatches` and `publishProgramDiagnostics`, which lack equivalent protection).
- `background.Queue` (`tsc/internal/project/background/queue.go`): `Enqueue` holds `q.mu` while checking `q.closed` and calling `q.wg.Add(1)`, and `Close` sets `q.closed = true` under `q.mu` before `q.wg.Wait()`, preventing `WaitGroup` add-during-wait panics.

