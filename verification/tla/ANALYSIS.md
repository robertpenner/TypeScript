# Architectural Analysis: Concurrency & State-Machine Defects in `tsc/internal`

## Executive Summary

We modeled 10 concurrent components across 8 Go packages in TypeScript 7 (`tsc/internal`, pinned at `e0fce98` on `microsoft/TypeScript` `main`) using official TLA+ (`tla2tools.jar` / TLC). Model checking uncovered **17 distinct concurrency and state-machine defects across 9 components**, and every defect is backed by a minimal 3- to 16-state TLC counterexample and a deterministic Go reproducer confirmed under `go test -race -timeout=15s` (19/19 reproducer tests failing as predicted against unmodified `tsc/internal` code).

Six of those defects affect normal production paths:
- A permanent two-goroutine AB-BA deadlock on cyclic tsconfig `extends` in both `execute/tsc` and `project` (`ExtendedConfigCache`).
- Silently dropped `$/cancelRequest` notifications in `lsp.Server` whenever a request is still sitting in `requestQueue` behind edits.
- Use-after-deref across 480+ concurrent `api.Session` read handlers (plus a post-close snapshot leak).
- Lost global-diagnostics push notifications in `project.Session`, lost file-watch triggers for newly registered watches in `fswatch.debounce`, and stale termination callbacks closing live watches in `lspwatcher`.

The remaining defects live in shared concurrent primitives (`dirty.SyncMap`, `RefCountCache`, `contentmapper.host`, and `lspwatcher.Watcher`), including a live `-race` data race, a nil-pointer panic, silently dropped deletions, TOCTOU conditional writes, orphaned child processes, and zero-value cache resurrection.

Every defect traces back to the same underlying design pattern: splitting one logical state transition across multiple synchronization domains (two mutexes, `collections.SyncMap` plus per-entry `sync.Mutex`, an `atomic.Bool` plus a mutex, or an unlocked I/O/RPC window) without carrying explicit lifecycle state or object identity across the gap. By contrast, `project.checkerPool` passed 26.9M+ TLC states with zero violations because one mutex owns all mutable state, blocking happens only on bounded semaphores outside the lock, and re-entry validates object identity. Existing Go tests in all 8 packages missed these bugs because they tested single-operation races rather than cross-operation interleavings.

---

## 1. Severity and Production Reachability Triage

Not every verified defect carries the same operational risk. Separating directly reachable production failures from core-primitive / API-contract hazards clarifies fix priority.

### Tier A: Direct Production Impact (Deadlock, Lost Cancellation, Use-After-Deref, Lost Events)

1. **Permanent AB-BA deadlock on cyclic tsconfig `extends`** (`tsc/internal/execute/tsc/extendedconfigcache.go`, `tsc/internal/project/ownercache.go`, `tsc/internal/tsoptions/tsconfigparsing.go`)
   - **Impact:** Permanent hang in parallel `tsc --build` or LSP config parsing whenever two projects enter a cyclic `extends` pair (`a.json <-> b.json`) from opposite ends.
   - **Why it matters:** `tsconfigparsing.go` already includes a `resolutionStack` check and `extendedconfigcache_test.go` already has a regression test for single-goroutine mutual cycles. The existing guard prevents self-deadlock on one goroutine while leaving two-goroutine AB-BA deadlock wide open.

2. **Silently dropped `$/cancelRequest` in LSP** (`tsc/internal/lsp/server.go:994-1064`)
   - **Impact:** Directly hits interactive editing. Whenever `dispatchLoop` is occupied with preceding edits (`textDocument/didChange`), queued requests sit in `s.requestQueue` invisible to `readLoop`'s `cancelRequest` lookup in `s.pendingClientRequests`. Every `$/cancelRequest` arriving during that queue residency is silently discarded, and the server later executes the stale request to completion with an uncanceled context.

3. **API snapshot use-after-deref across 480+ handlers, plus post-close leak** (`tsc/internal/api/session.go:703-743`, `1865-1891`, `5789-5810`)
   - **Impact:** `ipc.AsyncConn` executes incoming requests in parallel goroutines. `getSnapshotData` looks up `*snapshotData` under `snapshotsMu.RLock()` and unlocks without retaining `sd.refCount` (unlike `retainSnapshotData` immediately below it). A concurrent `handleRelease` or `Close` can drop `refCount` to zero and call `sd.snapshot.Deref()`, tearing down the checker pool, parse cache, and extended config cache while an active query reads `sd.snapshot`. Separately, `Close` clears `s.snapshots` without marking the session closed, so an in-flight `registerSnapshot` leaks a retained `*project.Snapshot`.

4. **Lost global-diagnostics push notification** (`tsc/internal/project/session.go:1998-2024`)
   - **Impact:** `publishGlobalDiagnostics` resets `globalDiagPublishPending` in a `defer` on function return rather than before draining `TakeNewGlobalDiagnostics()`. Any global diagnostic accumulated while `PublishDiagnostics` RPC is in flight sees `CompareAndSwap(false, true) == false` and is stranded unpublished until an unrelated future trigger.

5. **Lost filesystem debounce trigger for newly registered watches** (`tsc/internal/fswatch/debounce.go:51-119`, `tsc/internal/fswatch/watcher.go:849, 953`)
   - **Impact:** All `dirWatch` instances on a backend share one `debounce` loop. A newly registered watch calling `add()` and `trigger()` between `d.mu.Unlock()` and `d.latchReset()` in `fireCallbacks()` is omitted from the callback snapshot and has its notification cleared by `latchReset()`, stranding the event indefinitely until another watch triggers.

6. **Stale termination callback closing a newer live directory watch** (`tsc/internal/lsp/lspwatcher/lspwatcher.go:366-380`)
   - **Impact:** On rapid delete-and-recreate of a watched directory, a delayed `ErrWatchTerminated` callback runs `handleTerminated()` and unconditionally clears and closes `w.subscription` without verifying subscription identity, destroying a newer live subscription installed by concurrent recovery.

### Tier B: Core Primitive and Exported-API Defects

7. **`dirty.SyncMap` (5 defects in one 320-line primitive)** (`tsc/internal/project/dirty/syncmap.go`)
   - **Impact:** Confirmed Go `-race` data race inside `Locked { Change; Change }`, silent lost deletes in `SyncMapEntry.Delete` (line 151 writes `e.delete = true` instead of `entry.delete = true`) and `Locked { Change; Delete }`, nil-pointer panic on `m.Delete` racing `e.Change`, `ChangeIf`/`DeleteIf` TOCTOU across `proxyFor`, and mutating deleted entries. `dirty.SyncMap` is a shared concurrent CoW primitive used by `snapshotFSBuilder`, `ProjectCollectionBuilder`, `configFileRegistryBuilder`, and `autoimport/registry`.

8. **`contentmapper.host` closed-handle RPC and leaked zero-ref child process** (`tsc/internal/contentmapper/hostimpl.go:568-584`, `620-640`, `679-699`, `792-881`)
   - **Impact:** `projectLease.Transform` releases `h.mu` after `openProjectLocked` and before `transformLocked` / `connFor`. Racing `Refresh` closes the project handle before `MethodTransform` is sent; racing `Close` deletes `h.conns[id]` and closes the child process, causing `connForLocked` to allocate a fresh `mapperConn{refs: 0}` and spawn an orphaned child process that is never released until `host.Close()`.

9. **`RefCountCache` failure and resurrection defects** (`tsc/internal/project/refcountcache.go:60-137`)
   - **Impact:** Under `DisableDeletion: true` (used in `fourslash`), a failed `AcquireOrError` deletes the entry with `refCount = 0` while waiting `AcquireExisting` / `loadOrStoreNewLockedEntry` callers skip the `<= 0` check and return `(nil, true)`. Separately, `Ref`'s resurrection branch discards `loaded` and overwrites a live concurrent entry's value, and when racing a failing `AcquireOrError` resurrects a live `nil` entry into the cache.

10. **`lspwatcher.Watcher.WatchFiles` vs `UnwatchFiles` resurrection** (`tsc/internal/lsp/lspwatcher/lspwatcher.go:147-206`)
    - **Impact:** Currently shielded from `lsp.Server` by `s.watchers.Has(id)` in `tsc/internal/lsp/server.go:331`, but violates `lspwatcher.Watcher`'s own exported concurrent API by resurrecting an unwatched ID with live backend subscriptions.

---

## 2. Four Recurring Structural Root Causes

Every defect across all 9 buggy components stems from one of four structural mechanisms where a logical state transition is split across synchronization domains without preserving explicit lifecycle states or object identity:

### Pattern 1: One Logical Transition Split Across Two Synchronization Domains
- **Instances:** `Session.globalDiagPublishPending` (`atomic.Bool`) vs `checkerPool.mu`; `fswatch.debounce.mu` vs `debounce.latchMu`; `lsp.Server.requestQueue` vs `pendingClientRequestsMu`.
- **Mechanism:** One operation observes or modifies domain A (taking a flag, snapshotting callbacks, or checking a cancellation map) while a concurrent actor modifies domain B (setting `globalDiagChanged`, registering a callback and triggering, or enqueuing a request), leaving a window where signals are lost or wiped.
- **Fix principle:** Keep the signal latch and the state it guards under the same lock, or use a single state machine owning both (for example: clear `globalDiagPublishPending` or use a 3-state `idle / running / rerun` state before scanning; merge `debounce.mu` and `latchMu` or re-check/reset before snapshotting; track canceled request IDs or register `pendingClientRequests` in `readLoop` before `requestQueue.Put`).

### Pattern 2: Lock Dropped Around I/O or RPC Without Identity or Lifecycle Re-Validation
- **Instances:** `lspwatcher.WatchFiles` (re-acquires `w.mu` and checks only `w.closed`, not whether `id` still exists); `lspwatcher.handleTerminated` (never checks `w.subscription == deadSub`); `contentmapper.projectLease.Transform` (drops `h.mu` before `connFor` and `MethodTransform`); `api.Session.getSnapshotData` (returns unretained `*snapshotData`) and `registerSnapshot` (never checks `closed`).
- **Mechanism:** Releasing a lock for slow work breaks atomicity; when the goroutine resumes, it assumes the target entry, subscription, lease, or session is still in the phase it observed earlier.
- **Fix principle:** Retain an explicit ref/pin before unlocking (as `api.Session.retainSnapshotData` already does for snapshot derivation), carry the specific generation or object identity across the unlocked window (`handleTerminated(sub io.Closer)` checking `w.subscription == sub`), and re-validate entry/session state on lock re-acquisition.

### Pattern 3: Two-Level `collections.SyncMap` + Per-Entry `sync.Mutex` Without an Explicit Entry State Machine
- **Instances:** `dirty.SyncMap` (clean / dirty / deleted / proxied represented by `dirty`, `delete`, `proxyFor`, and `value` across `SyncMapEntry` and `lockedEntry`); `RefCountCache` (initializing / failed / live / deleted represented by `refCount <= 0 && !DisableDeletion`).
- **Mechanism:** Independent booleans permit unreachable-looking combinations that concurrent cross-operation interleavings actually hit: `{delete: true, dirty: false, value: nil}` (`m.Delete` + `e.Change`), `{dirty: true, proxyFor: e1}` bypassing `e1.mu` inside `Locked`, or `{refCount: 0, DisableDeletion: true}` returning a failed speculative entry.
- **Fix principle:** Make entry lifecycle state explicit (an enum such as `pending / ready / failed / deleted`, or immutable resolved forwarding in `dirty.SyncMap` where `Locked` resolves/pins the canonical dirty entry on entry and `Delete` always routes through `deleteLocked` with a non-nil original/tombstone separation).

### Pattern 4: Per-Key Locks Held Across Recursive Cache Calls
- **Instances:** `execute/tsc/extendedconfigcache.go` and `project/ownercache.go` (`ExtendedConfigCache`).
- **Mechanism:** Holding `entry[A].mu` while recursively calling `GetExtendedConfig(B)` allows two goroutines entering a cycle from `A` and `B` to form an AB-BA lock cycle that local `resolutionStack` checks cannot observe.
- **Fix principle:** Do not hold `entry.mu` across recursive `ParseExtendedConfig` calls (parse speculatively or track in-flight work with a cycle-aware wait/graph or lock-free singleflight that detects cross-goroutine dependency cycles, or compute without holding the entry lock and store on completion).

---

## 3. Why `project.checkerPool` Passed (Contrast Case)

`CheckerPool.tla` explored 26.9M+ distinct states (3 workers, depth 17) and 14.5M+ distinct states (2 workers, depth 28) with **zero invariant violations**. Comparing `checkerpool.go` against the 9 buggy components shows why:

1. **Single lock domain:** One mutex (`p.mu`) owns `checkers`, `heldBy`, `fileAssociations`, `requestAssociations`, `lastReleased`, `cleanupTimer`, `discarded`, and `globalDiagChanged`.
2. **Bounded waiting outside the lock:** Goroutines wait only on `diagSem` / `querySem` / `persistentSem` outside `p.mu`.
3. **Identity checks on re-entry:** `disposeCheckerLocked` asserts `p.checkers[index] == c`; persistent cancellation checks `p.persistentChecker == c`.
4. **Atomic read-and-reset:** `TakeNewGlobalDiagnostics()` reads and resets `p.globalDiagChanged` under `p.mu` in a single critical section (the lost-notification bug only appeared one layer up in `Session`, where `globalDiagPublishPending` split the latch out of that lock).

---

## 4. Value of TLA+ Alongside Existing Go Testing

Every one of the 8 affected packages already has unit tests, `-race` runs, and in several cases dedicated concurrency tests (`TestSyncMapProxyFor`, `TestExtendedConfigCacheExtendsCircularity`, `TestRefCountCacheAcquireExistingRacesFinalRelease`). Those tests checked the races the authors anticipated (`Change` vs `Change`, single-goroutine mutual `extends`, `AcquireExisting` vs `Deref` with `DisableDeletion: false`).

TLC found defects in the **cross-product of operations** that hand-written tests rarely combine:
- `m.Delete` vs `e.Change` (6 states)
- `Locked { Change; Change }` vs `e1.Change` (15 states, live `-race` failure)
- `Ref` vs failed `AcquireOrError` (15 states)
- `AcquireExisting` vs failed `AcquireOrError` under `DisableDeletion: true` (7 states)
- `add + trigger` vs `fireCallbacks` between `mu.Unlock()` and `latchReset()` (8 states)
- `readLoop` `$/cancelRequest` vs `requestQueue` residency ahead of `dispatchLoop` (7 states)
- Two goroutines entering cyclic `extends` from opposite ends (3 states)

Equally important, exhaustive checking ruled out a plausible false-positive hypothesis (`RefCountCache.Deref` unconditional `c.entries.Delete(identity)` passed 42,461,756 distinct states under balanced refcounting), preventing unnecessary churn.
