# TLA+ Formal Verification Findings Log (`TypeScript/tsc/internal`)

Running log of concurrency and state-machine investigations in TypeScript 7 (`tsc/internal`), verified using official `tla2tools.jar` (TLC2 2.19) and deterministic Go reproducers (`go test -race` / `testing/synctest`).

All TLA+ specs, TLC configurations, and Go reproducers live in this directory ([`specs/`](./specs/), [`reproducers/`](./reproducers/), and [`scripts/`](./scripts/)). Tool binaries (`/tmp/tla2tools.jar`) and TLC state directories (`/tmp/tlc-states/`) stay under `/tmp` so the repository stays clean. See [`ANALYSIS.md`](./ANALYSIS.md) for severity triage and structural root-cause analysis.

---

## Summary Table

| # | Package / Component | Finding | TLC Verification | Go Reproducer (`-race`) | Call-Site Reachability |
|---|---|---|---|---|---|
| 1a | `project/dirty/syncmap.go` | `SyncMapEntry.Delete()` silently drops deletion on raced clean handle | Violated (`NoLostDelete`, 10 states) | **Confirmed** (`FAIL` in 0.00s) | Public `dirty.SyncMap` API; used by `snapshotFSBuilder`, `ProjectCollectionBuilder`, `configFileRegistryBuilder` |
| 1b | `project/dirty/syncmap.go` | `SyncMap.Delete(key)` + concurrent `SyncMapEntry.Change()` causes nil-pointer panic in `Clone()` | Violated (`NoNilClonePanic`, 6 states) | **Confirmed** (`panic: nil pointer dereference`) | Public `dirty.SyncMap` API (`m.Delete` stores zero `value`, `dirty: false`) |
| 1c | `project/dirty/syncmap.go` | `SyncMapEntry.ChangeIf()` / `DeleteIf()` TOCTOU across `proxyFor` runs `apply`/`delete` when `cond` is false | Violated (`NoChangeIfTOCTOU`, 12 states) | **Confirmed** (`FAIL` in 0.00s) | Heavy production use (`projectcollectionbuilder.go`, `configfileregistrybuilder.go`, `autoimport/registry.go`) |
| 1d | `project/dirty/syncmap.go` | `SyncMapEntry.Change()` mutates an already-deleted dirty entry | Violated (`NoMutateDeleted`, 9 states) | **Confirmed** (`FAIL` in 0.00s) | Public `dirty.SyncMap` API |
| 1e | `project/dirty/syncmap.go` | `SyncMapEntry.Locked()` + `v.Change()` followed by `v.Delete()` or `v.Change()` bypasses `proxyFor` lock (lost delete + data race) | Violated (`NoDataRace`, 15 states; `NoLostDelete`) | **Confirmed** (lost delete + `WARNING: DATA RACE` in 0.00s) | Same pattern used in `snapshotfs.go:286` (`Locked { Change; Delete }`) |
| 2a | `project/refcountcache.go` | `AcquireOrError` failure + `DisableDeletion: true` returns zero value (`nil`) without error to concurrent waiters | Violated (`NoZeroValReturned`, 7 states) | **Confirmed** (`FAIL` in 0.01s) | `DisableDeletion: true` used in `fourslash/fourslash.go` |
| 2b | `project/refcountcache.go` | `Ref()` resurrection branch ignores `loaded` and overwrites a live concurrent entry's value | Violated (`NoLiveValueOverwrite`, 16 states) | **Confirmed** (`FAIL` in 0.01s) | `Ref()` called in `project.go` during `UpdateProgram` cloning |
| 2c | `project/refcountcache.go` | `Ref()` racing a failing `AcquireOrError` resurrects a zero-value (`nil`) entry into the live cache | Violated (`QuiescentConsistency`, 15 states) | **Confirmed** (`FAIL` in 0.01s) | `ContentMappedParseCache` uses both `AcquireOrError` and `Ref` |
| 2-neg | `project/refcountcache.go` | Negative result: unconditional `c.entries.Delete(identity)` in `Deref` does NOT delete a different live entry under balanced refcounts | **Verified safe** (42,461,756 distinct states, 0 errors) | N/A | Safe under balanced refcounting; still fragile against double-`Deref` |
| 3 | `project/session.go` | `EnqueuePublishGlobalDiagnostics` / `publishGlobalDiagnostics` drops global diagnostics arriving before `defer globalDiagPublishPending.Store(false)` | Violated (`NoLostGlobalDiagnostics`, 7 states) | **Confirmed** (`FAIL` in 0.00s) | Directly reachable in live LSP push-diagnostics sessions |
| 4a | `lsp/lspwatcher/lspwatcher.go` | `UnwatchFiles(id)` racing `WatchFiles(id)` returns `nil`, then `WatchFiles` resurrects `id` with leaked OS subscriptions | Violated (`NoResurrectedWatch`, 4 states) | **Confirmed** (`FAIL` in 0.00s) | Public `lspwatcher.Watcher` contract; `lsp/server.go` guards via `s.watchers` |
| 4b | `lsp/lspwatcher/lspwatcher.go` | `handleTerminated()` unconditionally clears/closes `w.subscription` without checking subscription identity, killing newer live watches | Violated (`NoKilledNewerSub`, 6 states) | **Confirmed** (`FAIL` in 0.01s) | Reachable in production on rapid delete/recreate of watched directories |
| 5 | `fswatch/debounce.go` | `debounce.add()` + `trigger()` racing `fireCallbacks()` between `d.mu.Unlock()` and `d.latchReset()` permanently loses callback invocation | Violated (`NoLostTrigger`, 8 states) | **Confirmed** (`FAIL` in 0.19s) | Directly reachable via `newDirWatch` (`watcher.go:849`) + `dw.notify()` (`watcher.go:953`) sharing one per-backend `debounce` |
| 6a | `contentmapper/hostimpl.go` | `projectLease.Transform()` unlocks `h.mu` after `openProjectLocked`, allowing concurrent `Refresh()` to close the project handle before `MethodTransform` | Violated (`NoTransformOnClosedHandle`, 4 states) | **Confirmed** (`FAIL` in 0.04s) | Public `contentmapper.Project` API; `Refresh()` and `Transform()` both take `lifecycleMu.RLock()` |
| 6b | `contentmapper/hostimpl.go` | `projectLease.Transform()` racing `projectLease.Close()` spawns an orphaned child process with `refs == 0` in `h.conns` and sends `MethodTransform` to an unopened handle | Violated (`NoOrphanedZeroRefConn`, 4 states) | **Confirmed** (`FAIL` in 0.00s) | `h.connForLocked()` creates `mapperConn{refs: 0}` unconditionally when `h.conns[id]` was deleted by `release()` |
| 7 | `execute/tsc/extendedconfigcache.go` & `project/ownercache.go` | Two-goroutine AB-BA deadlock on cyclic tsconfig `extends` (`a.json <-> b.json`) despite single-goroutine `resolutionStack` cycle guard | **Deadlock** (`ExtendedConfigDeadlock`, 3 states) | **Confirmed** (`FAIL` permanent deadlock in 0.30s) | Directly reachable in parallel `tsc --build` and LSP config parsing whenever two projects enter a cycle from different configs |
| 8 | `lsp/server.go` | `readLoop` intercepts `$/cancelRequest` before `dispatchLoop` pops the request from `requestQueue` into `pendingClientRequests`, silently dropping cancellation | Violated (`NoDroppedCancellation`, 7 states) | **Confirmed** (`FAIL` on attempt 1 in 0.02s, full end-to-end `LSPClient`) | Directly reachable in production LSP sessions during fast typing / queued requests |
| 9a | `api/session.go` | `getSnapshotData()` returns `*snapshotData` without retaining `refCount`, allowing concurrent `handleRelease()` / `Close()` to dispose `sd.snapshot` mid-query | Violated (`NoUseAfterDeref`, 4 states) | **Confirmed** (`FAIL` in 0.00s) | Called by 480+ API query handlers running concurrently on `ipc.AsyncConn` |
| 9b | `api/session.go` | `registerSnapshot()` inserts snapshots into `s.snapshots` after `Session.Close()` has cleared the map, permanently leaking retained `*project.Snapshot` | Violated (`NoLeakAfterClose`, 6 states) | **Confirmed** (`FAIL` in 0.00s) | Reachable when `createSnapshot` finishes concurrently with `Session.Close()` |
| 10-neg | `project/checkerpool.go` | Negative result (bounded): slot exclusion, semaphore accounting, timer cleanup, and discard behavior | 26.9M+ distinct states (depth 17) / 14.5M+ distinct states (depth 28), 0 errors | N/A | Core pool invariants held under modeled interleavings |

---

## Detailed Findings

### 1. `dirty.SyncMap` (`tsc/internal/project/dirty/syncmap.go`)

**Spec:** [`specs/DirtySyncMap/DirtySyncMap.tla`](./specs/DirtySyncMap/DirtySyncMap.tla)
**Reproducer:** [`reproducers/dirty_syncmap_repro_test.go`](./reproducers/dirty_syncmap_repro_test.go)

#### 1a. `SyncMapEntry.Delete()` silently loses deletion on raced clean handle
- **Location:** `tsc/internal/project/dirty/syncmap.go:136-156`
- **Root cause:** When a clean handle `e` (`!e.dirty`) loses `e.m.dirty.LoadOrStore(e.key, e)` to an existing dirty `entry`, lines 149-152 lock `entry.mu` and execute `e.delete = true` instead of `entry.delete = true`, and never set `e.proxyFor = entry`. The canonical `entry` in `m.dirty` keeps `delete == false`. `m.Load(key)` continues returning the entry and `m.Finalize()` retains the key.
- **TLC counterexample (`NoLostDelete`, 10 states):** `w1` and `w2` load clean handles `e1`, `e2` from `base`; `w1` runs `e1.Change(...)` placing `e1` in `m.dirty`; `w2` runs `e2.Delete()` which locks `e1.mu`, sets `e2.delete = true`, and leaves `e1.delete = false`.
- **Go reproducer:** `TestReproDirtySyncMapLostDelete` fails deterministically (`key 'k' still exists in SyncMap after e2.Delete()`).

#### 1b. `SyncMap.Delete(key)` + concurrent `SyncMapEntry.Change()` panics with nil-pointer dereference
- **Location:** `tsc/internal/project/dirty/syncmap.go:253-263` (`SyncMap.Delete`) and `102-122` (`changeLocked`)
- **Root cause:** `m.Delete(key)` inserts `&SyncMapEntry{m: m, key: key, original: m.base[key], delete: true}` into `m.dirty`, leaving `value` as the zero value (`nil` for pointer `V`) and `dirty: false`. When a concurrent clean handle calls `Change` or `ChangeIf`, `changeLocked` loads that entry (`loaded == true`), checks `if !entry.dirty` (true), and calls `entry.value.Clone()` on `nil`, panicking.
- **Secondary bug:** `FinalizeWith` (`syncmap.go:300-303`) invokes `hooks.OnDelete(key, entry.value)` with zero (`nil`) instead of `entry.original` whenever `m.Delete(key)` created the tombstone. Callers such as `snapshotFSBuilder.Finalize` (`snapshotfs.go:281`) dereference `deletedFile.realpathPath` without a nil check.
- **TLC counterexample (`NoNilClonePanic`, 6 states):** `w1` loads clean `e1`; `w2` runs `m.Delete(k)`; `w1` runs `e1.Change(...)` and panics on `Clone()`.
- **Go reproducer:** `TestReproDirtySyncMapDeleteThenChangeNilPanic` deterministically catches `runtime error: invalid memory address or nil pointer dereference`.

#### 1c. `SyncMapEntry.ChangeIf()` / `DeleteIf()` TOCTOU across `proxyFor`
- **Location:** `tsc/internal/project/dirty/syncmap.go:124-134` (`ChangeIf`), `173-182` (`DeleteIf`), `29-35` (`lockedEntry.ChangeIf`)
- **Root cause:** A clean handle evaluates `cond(e.value)` against its stale `base[key]` snapshot while holding only `e.mu`, then calls `e.changeLocked(apply)` (or `e.deleteLocked()`). If another goroutine has already inserted and mutated the dirty entry in `m.dirty`, `changeLocked` proxies to that entry and executes `apply(entry.value)` without re-evaluating `cond(entry.value)`.
- **TLC counterexample (`NoChangeIfTOCTOU`, 12 states):** `w1` and `w2` load clean handles with `data == 1`; `w1` mutates dirty entry to `data == 2`; `w2` runs `ChangeIf(data == 1, apply)`, passes `cond` on stale clean `e2`, proxies to `e1`, and mutates `e1` despite `data == 2`.
- **Go reproducer:** `TestReproDirtySyncMapChangeIfTOCTOU` fails deterministically (`ChangeIf ran apply when actual value was "updated" (cond required "initial")`).

#### 1d. `SyncMapEntry.Change()` mutates an already-deleted dirty entry
- **Location:** `tsc/internal/project/dirty/syncmap.go:102-122`
- **Root cause:** `changeLocked` copies `e.delete = entry.delete` when proxying, but never skips `Clone()` or `apply(entry.value)` when `entry.delete` is true.
- **TLC counterexample (`NoMutateDeleted`, 9 states):** `w1` and `w2` load clean handles; `w2` runs `e2.Delete()`; `w1` runs `e1.Change(apply)` and executes `apply` on the deleted entry.
- **Go reproducer:** `TestReproDirtySyncMapMutatesDeletedEntry` fails deterministically.

#### 1e. `SyncMapEntry.Locked()` loses proxy lock after first `v.Change()` (data race + lost delete)
- **Location:** `tsc/internal/project/dirty/syncmap.go:25-44`, `85-122`, `158-171`
- **Root cause:** When a clean handle `e` enters `e.Locked(fn)`, `e.proxyFor` is `nil`, so `fn(&lockedEntry{e: e})` runs holding only `e.mu`. Inside `fn`:
  1. The first `v.Change(f1)` calls `e.changeLocked(f1)`, loses `LoadOrStore` to `entry`, locks `entry.mu`, sets `e.proxyFor = entry`, `e.value = entry.value`, `e.dirty = true`, runs `f1(entry.value)`, and **unlocks `entry.mu`** on return.
  2. Any subsequent `v.Change(f2)` inside the same `Locked(fn)` calls `e.changeLocked(f2)` directly (skipping the `e.proxyFor` check in `SyncMapEntry.Change`), hits `if e.dirty { apply(e.value); return }`, and mutates the shared `entry.value` **without holding `entry.mu`** while another goroutine holds `entry.mu` (Go data race).
  3. Any subsequent `v.Delete()` inside the same `Locked(fn)` calls `e.deleteLocked()`, hits `if e.dirty { e.delete = true; return }`, and sets `e.delete = true` without updating `entry.delete`, silently losing the deletion. (Note: `snapshotfs.go:286-293` uses this exact `Locked { Change; if ... { Delete } }` pattern.)
- **TLC counterexample (`NoDataRace`, 15 states; `NoLostDelete`):** Confirmed by TLC.
- **Go reproducer:** Both `TestReproDirtySyncMapLockedProxyLostDelete` (`FAIL` in 0.00s) and `TestReproDirtySyncMapLockedProxyDataRace` (`WARNING: DATA RACE` under `go test -race` in 0.00s) reproduce deterministically.

---

### 2. `RefCountCache` (`tsc/internal/project/refcountcache.go`)

**Spec:** [`specs/RefCountCache/RefCountCache.tla`](./specs/RefCountCache/RefCountCache.tla)
**Reproducer:** [`reproducers/project_repro_test.go`](./reproducers/project_repro_test.go)

#### 2a. `AcquireOrError` failure + `DisableDeletion: true` returns zero value without error
- **Location:** `tsc/internal/project/refcountcache.go:67`, `89-93`, `132`
- **Root cause:** When `produce()` returns an error in `AcquireOrError`, lines 90-91 unconditionally set `entry.refCount = 0` and call `c.entries.Delete(identity)` regardless of `c.Options.DisableDeletion`. Any concurrent `AcquireExisting` (line 67) or `loadOrStoreNewLockedEntry` (line 132) that loaded the speculative entry before `Delete` checks `if entry.refCount <= 0 && !c.Options.DisableDeletion`, which evaluates to `false` when `DisableDeletion == true`. The waiter increments `refCount` and returns the uninitialized zero value (`nil`) as a cache hit.
- **TLC counterexample (`NoZeroValReturned`, 7 states):** Confirmed in <1s.
- **Call sites:** `fourslash/fourslash.go` constructs caches with `RefCountCacheOptions{DisableDeletion: true}`.

#### 2b. `Ref()` resurrection branch overwrites a concurrently acquired live entry's value
- **Location:** `tsc/internal/project/refcountcache.go:106-113`
- **Root cause:** When `Ref(identity)` observes `entry.refCount <= 0`, it calls `newEntry, _ := c.loadOrStoreNewLockedEntry(identity)` (discarding `loaded`) and unconditionally executes `newEntry.value = entry.value`. If another goroutine already inserted and populated a new live `newEntry` (`loaded == true`), `Ref` overwrites `newEntry.value` with the dead entry's value, violating value/pointer coherence across active holders.
- **TLC counterexample (`NoLiveValueOverwrite`, 16 states):** Confirmed in 1s.

#### 2c. `Ref()` racing a failing `AcquireOrError` resurrects a zero-value (`nil`) entry
- **Location:** `tsc/internal/project/refcountcache.go:89-93`, `106-113`
- **Root cause:** If `Ref(identity)` loads a speculative entry inserted by `AcquireOrError` whose `produce()` subsequently fails (leaving `entry.value == zero` and setting `entry.refCount = 0`), `Ref` enters the resurrection branch and stores `newEntry.value = entry.value` (zero/`nil`) into a brand-new live entry with `refCount = 1`. Subsequent `Acquire` calls return `nil`.
- **TLC counterexample (`QuiescentConsistency`, 15 states):** Confirmed in 1s.

#### 2-neg. Unconditional `c.entries.Delete(identity)` in `Deref` (Negative Result)
- **Result:** Exhaustively checked `NoWrongEntryDeleted` and `NoDerefMiss` across **42,461,756 distinct states** (151.7M generated, 3 workers, concurrent `Ref` enabled, balanced refcounts): **0 violations**. Because `entry.refCount` only drops to `<= 0` after all holders dereference `entry`, `entry` remains the current map entry while `entry.mu` is held during deletion. (Unconditional `Delete` remains fragile only if a caller double-dereferences.)

---

### 3. `Session.EnqueuePublishGlobalDiagnostics` (`tsc/internal/project/session.go`)

**Spec:** [`specs/SessionGlobalDiag/SessionGlobalDiag.tla`](./specs/SessionGlobalDiag/SessionGlobalDiag.tla)
**Reproducer:** [`reproducers/project_repro_test.go`](./reproducers/project_repro_test.go)

- **Location:** `tsc/internal/project/session.go:1998-2024`
- **Root cause:** `publishGlobalDiagnostics` resets `s.globalDiagPublishPending` via `defer s.globalDiagPublishPending.Store(false)` on function exit rather than before scanning projects (contradicting the comment on line 197: *"It is reset when the task runs"*). Any global diagnostic accumulated in `checkerPool` after `TakeNewGlobalDiagnostics()` / `GetProjectDiagnostics()` and before `PublishDiagnostics` RPC returns calls `EnqueuePublishGlobalDiagnostics()`, sees `CompareAndSwap(false, true) == false`, drops the enqueue, and is stranded unpublished once `defer` clears the flag.
- **TLC counterexample (`NoLostGlobalDiagnostics`, 7 states):** Reaches quiescent state `workerPC = "idle"`, `publishPending = FALSE`, `globalDiagChanged = TRUE`, `producedCount = 2`, `publishedCount = 1`.

---

### 4. `lspwatcher.Watcher` (`tsc/internal/lsp/lspwatcher/lspwatcher.go`)

**Spec:** [`specs/LspWatcher/LspWatcher.tla`](./specs/LspWatcher/LspWatcher.tla)
**Reproducer:** [`reproducers/lspwatcher_repro_test.go`](./reproducers/lspwatcher_repro_test.go)

#### 4a. `WatchFiles(id)` vs `UnwatchFiles(id)` resurrects unwatched ID and leaks OS watches
- **Location:** `tsc/internal/lsp/lspwatcher/lspwatcher.go:147-182`, `193-206`
- **Root cause:** `WatchFiles` inserts `w.watches[id] = nil`, unlocks `w.mu`, calls `newWatch.reconcile(false)`, re-locks `w.mu`, checks only `if w.closed`, and appends `w.watches[id] = append(w.watches[id], newWatch)` without verifying that `id` is still present in `w.watches`. If `UnwatchFiles(id)` runs while `reconcile` is in flight, `UnwatchFiles` deletes `id` and returns `nil`, and `WatchFiles` immediately resurrects `w.watches[id]` with live backend subscriptions.
- **TLC counterexample (`NoResurrectedWatch`, 4 states):** Confirmed in <1s.
- **Call-site note:** In `tsc/internal/lsp/server.go:300-339`, `Server.UnwatchFiles` checks `s.watchers.Has(id)` which is only added after `WatchFiles` returns, preventing this race from `Server` alone, though it violates `lspwatcher.Watcher`'s own exported concurrency contract.

#### 4b. Stale `handleTerminated()` closes a newer live subscription
- **Location:** `tsc/internal/lsp/lspwatcher/lspwatcher.go:366-380`
- **Root cause:** `targetCallback` invokes `w.handleTerminated()` on `ErrWatchTerminated` without passing the terminated subscription handle. `handleTerminated()` acquires `w.mu` and unconditionally clears and closes `w.subscription`. If a concurrent `reconcile()` (e.g., from an ancestor watch or another recovery) already installed a fresh live subscription, the stale callback destroys the live watch.
- **TLC counterexample (`NoKilledNewerSub`, 6 states):** Confirmed in <1s.

---

### 5. `fswatch.debounce` (`tsc/internal/fswatch/debounce.go`)

**Spec:** [`specs/FSWatchDebounce/FSWatchDebounce.tla`](./specs/FSWatchDebounce/FSWatchDebounce.tla)
**Reproducer:** [`reproducers/fswatch_debounce_repro_test.go`](./reproducers/fswatch_debounce_repro_test.go)

- **Location:** `tsc/internal/fswatch/debounce.go:51-119`, called from `tsc/internal/fswatch/watcher.go:849, 953`
- **Root cause:** `fireCallbacks()` snapshots `d.callbacks` under `d.mu`, releases `d.mu`, and **then** calls `d.latchReset()` under `d.latchMu`. If a new directory watch calls `d.add(dw, cb)` (`watcher.go:849`) and receives an event calling `d.trigger()` (`watcher.go:953`) between `d.mu.Unlock()` and `d.latchReset()`:
  1. `cb` was not in the snapshotted `cbs` slice.
  2. `d.trigger()` sees `d.notified == true`, so it does not reopen/close a fresh `waitCh`.
  3. `d.latchReset()` sets `d.notified = false` and installs a new open `waitCh`, wiping the pending trigger.
  4. `loop()` parks indefinitely on `latchWait()`, and `cb` is never invoked until an unrelated event arrives on another watch.
- **TLC counterexample (`NoLostTrigger`, 8 states):** Confirmed in <1s.

---

### 6. `contentmapper.host` (`tsc/internal/contentmapper/hostimpl.go`)

**Spec:** [`specs/ContentMapperHost/ContentMapperHost.tla`](./specs/ContentMapperHost/ContentMapperHost.tla)
**Reproducer:** [`reproducers/contentmapper_repro_test.go`](./reproducers/contentmapper_repro_test.go)

#### 6a. `projectLease.Transform()` vs `projectLease.Refresh()` sends `MethodTransform` on a closed handle
- **Location:** `tsc/internal/contentmapper/hostimpl.go:792-811` (`Transform`), `679-699` (`Refresh`), `568-584` (`transformLocked`)
- **Root cause:** `Transform()` acquires `lifecycleMu.RLock()` and `h.mu`, calls `openProjectLocked()` to open `entry.projectHandle`, **unlocks `h.mu`**, and calls `h.transformLocked(mapper, request, handle)`. Because `Refresh()` also takes only `lifecycleMu.RLock()` and `h.mu`, `Refresh()` runs in that unlocked window, sends `MethodCloseProject(handle)`, and clears `entry.opened = false` before `Transform` sends `MethodTransform(handle)`.
- **TLC counterexample (`NoTransformOnClosedHandle`, 4 states):** Confirmed in <1s.
- **Go reproducer:** `TestReproContentMapperTransformVsRefreshClosedHandle` reproduces (`unknown or closed project handle ":0" on conn #1` in 0.04s).

#### 6b. `projectLease.Transform()` vs `projectLease.Close()` spawns an orphaned `refs == 0` child process
- **Location:** `tsc/internal/contentmapper/hostimpl.go:792-811` (`Transform`), `821-881` (`release`), `620-640` (`connForLocked`)
- **Root cause:** When `Close()` runs in the unlocked window between `Transform`'s `p.host.mu.Unlock()` and `h.transformLocked()` -> `h.connFor()`, `release()` deletes the project, decrements `connEntry.refs` to `0`, deletes `h.conns[identity]`, and closes the child process. `Transform` then calls `h.connForLocked(mapper)`, which sees `h.conns[identity] == nil`, allocates a fresh `&mapperConn{}` with **`refs: 0`**, dials a brand-new child process that has no owner to ever release it until `host.Close()`, and sends `MethodTransform(handle)` to a process that never received `MethodOpenProject`.
- **TLC counterexample (`NoOrphanedZeroRefConn`, 4 states):** Confirmed in <1s.
- **Go reproducer:** `TestReproContentMapperTransformVsCloseOrphanProcess` reproduces (`dialCount=2`, `leakedRefs=0`, `unknown or closed project handle ":0" on conn #2` in 0.00s).

---

### 7. `ExtendedConfigCache` (`tsc/internal/execute/tsc/extendedconfigcache.go` & `tsc/internal/project/ownercache.go`)

**Spec:** [`specs/ExtendedConfigDeadlock/ExtendedConfigDeadlock.tla`](./specs/ExtendedConfigDeadlock/ExtendedConfigDeadlock.tla)
**Reproducer:** [`reproducers/extendedconfig_deadlock_repro_test.go`](./reproducers/extendedconfig_deadlock_repro_test.go)

- **Location:** `tsc/internal/execute/tsc/extendedconfigcache.go:27-46`, `tsc/internal/project/ownercache.go:36-44`, `tsc/internal/tsoptions/tsconfigparsing.go` (`!slices.Contains(resolutionStack, extendedConfigPath)`)
- **Root cause:** `tsoptions` bypasses `extendedConfigCache.GetExtendedConfig` when `extendedConfigPath` appears in the current goroutine's `resolutionStack` to avoid single-goroutine self-deadlock on per-entry mutexes. When two goroutines enter a mutual cycle (`a.json` extends `b.json`, `b.json` extends `a.json`) from opposite ends (`tsconfig1.json -> a.json` and `tsconfig2.json -> b.json`), Goroutine 1 holds `entry[a].mu` with stack `[tsconfig1, a]` and calls `GetExtendedConfig(b)`, while Goroutine 2 holds `entry[b].mu` with stack `[tsconfig2, b]` and calls `GetExtendedConfig(a)`. Both pass their local stack checks and permanently deadlock on `entry[b].mu` / `entry[a].mu`. The same lock-across-recursive-parse structure exists in both `tsc.ExtendedConfigCache` (parallel `tsc --build`) and `project.ExtendedConfigCache` (`OwnerCache`).
- **TLC counterexample (`ExtendedConfigDeadlock`, 3 states):** `LockRoot(w1)` -> `LockRoot(w2)` -> `Deadlock reached` in <1s.
- **Go reproducer:** `TestReproExtendedConfigCacheABBADeadlock` deterministically reproduces the permanent AB-BA deadlock in 0.30s using a 2-goroutine barrier on `vfs.FS.ReadFile`.

---

### 8. `lsp.Server` Dropped `$/cancelRequest` (`tsc/internal/lsp/server.go`)

**Spec:** [`specs/LspServerCancel/LspServerCancel.tla`](./specs/LspServerCancel/LspServerCancel.tla)
**Reproducer:** [`reproducers/lsp_cancel_repro_test.go`](./reproducers/lsp_cancel_repro_test.go)

- **Location:** `tsc/internal/lsp/server.go:994-1016` (`readLoop`, `cancelRequest`), `1025-1064` (`dispatchLoop`)
- **Root cause:** `readLoop` enqueues normal client requests into `s.requestQueue` (an unbounded FIFO slice queue) without adding them to `s.pendingClientRequests`. Only `dispatchLoop` populates `s.pendingClientRequests` after dequeuing a request. However, `readLoop` intercepts `$/cancelRequest` immediately (bypassing `s.requestQueue`) and calls `s.cancelRequest(params.Id)`, which looks up `s.pendingClientRequests[*id]`. If the target request is still sitting in `s.requestQueue` (for instance, behind in-flight `didChange` notifications during typing), the lookup misses and the cancellation is silently discarded. `dispatchLoop` later dequeues the request and runs it to completion with an uncanceled context.
- **TLC counterexample (`NoDroppedCancellation`, 7 states):** Confirmed in <1s.
- **Go reproducer:** `TestReproLspServerDroppedCancelInQueue` (using `lsptestutil.NewLSPClient` end-to-end) reproduces on attempt 1 in 0.02s: `$/cancelRequest(1)` is dropped and the server executes hover and returns a normal hover result instead of `RequestCancelled`.

---

### 9. `api.Session` Snapshot Lifecycle (`tsc/internal/api/session.go`)

**Spec:** [`specs/ApiSessionSnapshot/ApiSessionSnapshot.tla`](./specs/ApiSessionSnapshot/ApiSessionSnapshot.tla)
**Reproducer:** [`reproducers/api_session_repro_test.go`](./reproducers/api_session_repro_test.go)

#### 9a. `getSnapshotData()` vs `handleRelease()` use-after-deref
- **Location:** `tsc/internal/api/session.go:703-711` (`getSnapshotData`), `714-723` (`retainSnapshotData`), `725-743` (`releaseSnapshot`)
- **Root cause:** Unlike `retainSnapshotData`, `getSnapshotData` (called by 480+ concurrent API handlers running on `ipc.AsyncConn`) reads `s.snapshots[handle]` under `s.snapshotsMu.RLock()` and unlocks without incrementing `sd.refCount`. A concurrent `handleRelease(handle)` or `Session.Close()` can drop `sd.refCount` to `0`, remove `sd`, and invoke `sd.snapshot.Deref()` (disposing `checkerPool`, dereferencing `parseCache`, and releasing `extendedConfigCache`) while the query handler is actively using `sd.snapshot`.
- **TLC counterexample (`NoUseAfterDeref`, 4 states):** Confirmed in <1s.
- **Go reproducer:** `TestReproApiSessionGetSnapshotDataUseAfterDeref` fails deterministically in 0.00s.

#### 9b. `Session.Close()` vs `registerSnapshot()` post-close snapshot leak
- **Location:** `tsc/internal/api/session.go:1865-1891` (`registerSnapshot`), `5789-5810` (`Close`)
- **Root cause:** `Close()` clears `s.snapshots` (`clear(s.snapshots)`) and derefs all current entries without recording a `closed` flag. Any concurrent `createSnapshot` that finishes and calls `registerSnapshot()` after `Close()` unlocks `s.snapshotsMu` inserts its retained `*project.Snapshot` into the emptied map, leaking it permanently.
- **TLC counterexample (`NoLeakAfterClose`, 6 states):** Confirmed in <1s.
- **Go reproducer:** `TestReproApiSessionRegisterSnapshotAfterCloseLeak` fails deterministically in 0.00s.

---

### 10. `project.checkerPool` (`tsc/internal/project/checkerpool.go`) — Negative Result (So Far)

**Spec:** [`specs/CheckerPool/CheckerPool.tla`](./specs/CheckerPool/CheckerPool.tla)

- Checked `NoDoubleUse`, `NoSlotPanic`, `NoDisposeMismatch`, `NoSemUnderflow`, `NoReusedCanceled`, `NoTimerAfterDiscard`, `SemAccounting`, and `NoDanglingFileAssoc` across 26.9M+ distinct states (3 workers, depth 17) and 14.5M+ distinct states (2 workers, depth 28): **0 violations**.
- Note: `GetChecker` blocks unconditionally on `diagSem`/`querySem` without selecting on `ctx.Done()`, which is a liveness/cancellation responsiveness consideration worth reviewing separately with callers.

---

## Architectural Synthesis (Shared Root Cause)

Every verified bug across all 9 families (17 distinct defects across 7 packages) stems from one of four concrete structural mechanisms where a logical state transition is split across synchronization domains without preserving explicit lifecycle phases or object identity across the gap:

1. **Multi-domain split with reset-after-read or bypass:** `Session.globalDiagPublishPending` (`atomic.Bool` cleared via `defer` after scanning `checkerPool.mu`), `fswatch.debounce` (`d.mu` callback snapshot separated from `d.latchMu` reset), `lsp.Server` (`$/cancelRequest` checking `pendingClientRequestsMu` while requests sit in `requestQueue`).
2. **Lock-drop around I/O, RPC, or recursion without re-validating entry identity/state:** `lspwatcher.Watcher.WatchFiles` (re-acquires `w.mu` without checking `id` still exists), `lspwatcher.watch.handleTerminated` (closes `w.subscription` without checking subscription identity), `contentmapper.projectLease.Transform` (drops `h.mu` before `transformLocked` / `connFor`, racing `Refresh` and `Close`), `api.Session.getSnapshotData` & `registerSnapshot` (drops `snapshotsMu` without retaining or checking `closed`).
3. **Two-level `SyncMap` + per-entry `sync.Mutex` without explicit entry lifecycle/proxy invariants:** `dirty.SyncMap` (clean-to-dirty promotion via `proxyFor` bypassed inside `Locked`, broken in `Delete`, unchecked in `ChangeIf`/`DeleteIf`, nil-valued tombstone from `m.Delete`), `RefCountCache` (failed speculative `AcquireOrError` entry misclassified under `DisableDeletion`, `Ref` resurrection ignoring `loaded` and copying zero values).
4. **Per-key mutex held across recursive cache calls without global lock ordering:** `ExtendedConfigCache` (both `execute/tsc` and `project/ownercache`) relying on per-goroutine `resolutionStack` cycle detection, which cannot prevent multi-goroutine AB-BA deadlocks.

By contrast, `project.checkerPool` passed 26.9M+ TLC states because a single mutex owns all mutable state, waiting happens only on bounded semaphores outside the mutex, re-entry validates pointer identity (`p.persistentChecker == c`), timers re-check full state under lock, and `TakeNewGlobalDiagnostics()` clears its flag atomically while reading.

---

## Remaining Targets (Optional Deepening)

- [ ] `project/session.go` full lock-order graph & `pendingFileChanges` / `pendingATAChanges` / debounce generation counters.
- [ ] `execute/build/orchestrator.go` worker starvation on upstream waits and watch-mode rebuild races.
- [ ] `execute/watcher.go` and `project/snapshotfs.go` (`sourceBackedReplacements` non-thread-safe `collections.Set` mutations vs concurrent callers).
