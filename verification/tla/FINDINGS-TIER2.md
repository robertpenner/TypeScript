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
