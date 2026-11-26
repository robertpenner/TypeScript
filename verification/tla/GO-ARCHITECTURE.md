# Idiomatic Go Concurrency Architecture for TypeScript 7 Tooling (`tsc/internal`)

Branch: `tla-tier2-investigation` (upstream base `e0fce98`)
Companion reports: [`FINDINGS.md`](./FINDINGS.md) (Tier 1), [`ANALYSIS.md`](./ANALYSIS.md) (Tier 1 root-cause analysis), [`FINDINGS-TIER2.md`](./FINDINGS-TIER2.md) (Tier 2 findings), [`ROADMAP.md`](./ROADMAP.md) (verification roadmap)

## Overview

Formal verification with TLA+ and deterministic Go `-race` reproducers has confirmed **22 concurrency and state-machine defects** across `tsc/internal` (17 in Tier 1 across 9 components, plus 5 in Tier 2 Target 1 across `fswatch` and `execute/build`), alongside active Target 2 audit leads in `project.Session` and `OwnerCache`.

These failures share a structural theme. TypeScript 7 runs a Go compiler and language server whose concurrency needs split cleanly into two different modes, yet `tsc/internal` applies fine-grained shared-memory locking (`collections.SyncMap`, per-entry `sync.Mutex`, standalone `atomic.Bool` flags, and unbounded `go func()` calls) across stateful I/O orchestration where Go favors single-owner loops, coalescing reconcilers, and explicit lifecycle ownership.

This document synthesizes the verified defect patterns into a concrete target concurrency architecture in idiomatic Go.

---

## 1. Two Distinct Concurrency Modes in TypeScript Tooling

TypeScript tooling combines two workloads with opposite concurrency requirements:

1. **Data plane (CPU-bound compilation):** parsing, binding, type-checking, declaration emit, and build DAG execution over immutable snapshots and ASTs. Here, read-only sharing, bounded worker pools, and narrow pool mutexes (such as `project.checkerPool`) work well in Go.
2. **Control plane (long-lived stateful orchestration and I/O):** LSP request dispatch and cancellation, `project.Session` snapshot side effects (file watches, diagnostics publishing, ATA, content-mapper registrations), OS filesystem watching and debouncing, child-process content-mapper lifecycles, API snapshot handle tables, and `tsc -b -w` watch cycles.

Almost every defect found so far sits in the control plane or in shared mutable caches bridging the two layers:

- `tsc/internal/project/session.go` coordinates 14 separate sync primitives plus `background.Queue`, whose `Enqueue` spawns an unbounded, unordered goroutine per task.
- `tsc/internal/fswatch/watcher.go` and `debounce.go` split watch registration, callback delivery, OS subscriptions, and debouncing across five independent mutexes (`w.mu`, `dw.mu`, `b.mu`, `debounce.mu`, `debounce.latchMu`).
- `tsc/internal/project/dirty/syncmap.go` layers per-entry mutexes, `proxyFor` forwarding, and `lockedEntry` wrappers on top of `collections.SyncMap`, yielding 5 distinct bugs in 320 lines.

In idiomatic Go, control-plane state machines are owned by **one goroutine** (an event loop or level-triggered reconciler) or **one coarse mutex** with explicit lifecycle states, while the data plane stays immutable and parallel.

---

## 2. Defect-to-Pattern Summary

| Verified Defect / Audit Cluster | Current Mechanism | Idiomatic Go Replacement |
|---|---|---|
| `SessionGlobalDiag` (Tier 1); Target 2 `updateWatches`, `publishProgramDiagnostics` | Unbounded `go func()` in `background.Queue.Enqueue` + separate `atomic.Bool` latch reset in `defer` | **Level-triggered coalescing reconciler**: `atomic.Pointer[Snapshot]` + 1-buffered `chan struct{}` feeding one serial goroutine owning `applied` state |
| `FSWatchDebounce` (Tier 1); `FSWatchLifecycle` 3 invariants (Tier 2); `LspWatcher` 2 defects (Tier 1) | 3 to 5 independent mutexes unlocked across OS watch registration, callback teardown, and debounce timer | **Single-owner event loop** (`select` over commands, identity-tagged OS events, and `time.Timer`), or one mutex with generation/pointer identity checks |
| `ApiSessionSnapshot` 2 defects (Tier 1); `ContentMapperHost` 2 defects (Tier 1) | Returning unretained pointers (`getSnapshotData`) or dropping `h.mu` before child-process RPC without checking closed/handle state | **Scoped lease / borrow API** (`withSnapshot` or mandatory `Acquire`/`Release` handle checking `closed` under the same lock) |
| `RefCountCache` 3 defects (Tier 1); Target 2 `OwnerCache.Release` blind delete | Implicit lifecycle via `refCount <= 0 && !DisableDeletion` and unconditional `entries.Delete(key)` | **Explicit lifecycle enum** (`pending`/`ready`/`failed`/`deleted`) + `sync.Map.CompareAndDelete(key, entry)` (or pointer-checked delete under one mutex) |
| `DirtySyncMap` 5 defects (Tier 1) | Two-level `SyncMap` + per-entry `sync.Mutex` + `proxyFor` forwarding + `lockedEntry` | **Fixed-shard map** (`[N]shard`, each one `sync.Mutex` + plain `map[K]*entry`) or single mutex where contention is low |
| `ExtendedConfigDeadlock` (Tier 1; upstream `#64833`, `#65300`) | Holding `entry[A].mu` across recursive `GetExtendedConfig(B)` | **Speculative lock-free parse** outside the entry lock using goroutine-local `resolutionStack`, then publish immutable result (or single-lock cycle-aware wait graph) |
| `LspServerCancel` (Tier 1) | `readLoop` enqueues into `requestQueue`; `dispatchLoop` later inserts into `pendingClientRequests` | **Wire-order registration**: create `context.WithCancel` and register `id -> cancel` in `readLoop` before `requestQueue.Put` |
| `BuildOrchestratorWatch` 2 defects (Tier 2) | Reusing `*BuildTask` across watch cycles (stale closed `done`/`built` channels and unreset `downStream` slice) | **Immutable per-cycle execution state**: separate persistent config/build-info caches from fresh per-cycle task structs with fresh channels and edges |

---

## 3. Five Idiomatic Go Patterns for `tsc/internal`

### Pattern A: Level-Triggered Coalescing Reconcilers (`project.Session`, `background.Queue`)

**Observed failure mode:** `background.Queue.Enqueue` (`tsc/internal/project/background/queue.go:20`) is a `sync.WaitGroup` wrapper that immediately spawns `go func() { fn(ctx) }()`. Every snapshot transition fires independent goroutines carrying edge-triggered diffs (`oldSnapshot -> newSnapshot`) for watches, diagnostics, and content-mapper registrations. Those goroutines race and complete out of order. `updateContentMapperRegistrations` added its own serialization mutex and `registeredContentMapperSnapshotID` monotonic check, while `updateWatches` and `publishProgramDiagnostics` remain unserialized. Separately, `publishGlobalDiagnostics` guards enqueueing with `globalDiagPublishPending` (`atomic.Bool`) reset in `defer`, dropping global diagnostics that arrive while an RPC is in flight.

**Idiomatic Go design:** Replace fire-and-forget edge-triggered tasks with a **level-triggered reconciler** per external side-effect sink. Producers store the latest immutable desired state and perform a non-blocking send to a 1-buffered notification channel; a single reconciler goroutine compares `desired` against its private `applied` state and converges:

```go
// Producer (called during snapshot update or diagnostic invalidation):
s.latestSnapshot.Store(snap)
select {
case s.watchNotify <- struct{}{}:
default:
}

// Single reconciler goroutine (owns `applied` without a mutex):
func (s *Session) runWatchReconciler(ctx context.Context) {
	var applied watchState
	for {
		select {
		case <-ctx.Done():
			return
		case <-s.watchNotify:
			desired := s.latestSnapshot.Load()
			applied = s.reconcileWatches(ctx, applied, desired)
		}
	}
}
```

Why this works in Go:
- **No lost wakeups:** If a new snapshot or global diagnostic arrives while the reconciler is blocked in an LSP RPC, the 1-element channel buffer holds a pending token and triggers one follow-up iteration immediately on return.
- **No out-of-order overwrites:** Only one goroutine sends watch or diagnostic updates for a given sink, and it always reads the newest snapshot.
- **Automatic coalescing:** Rapid edits collapse many intermediate snapshots into one reconciliation pass, eliminating unbounded goroutine churn and rollback races between concurrent `Acquire`/`Release` calls.

---

### Pattern B: Single-Owner Event Loops for Stateful I/O and Timers (`fswatch`, `lspwatcher`, `contentmapper`)

**Observed failure mode:** `fswatch` unlocks `w.mu`, `dw.mu`, `b.mu`, `debounce.mu`, and `debounce.latchMu` between dependent steps of `WatchDirectories`, `watch.Close`, `add`/`trigger`, and `fireCallbacks`. Concurrent open/close cycles return live `Watch` handles with `debounce == nil`, torn-down OS subscriptions, or evicted registry entries, and newly added watches lose their first debounce trigger. In `lspwatcher`, dropping `w.mu` around subscription setup lets `WatchFiles` resurrect an unwatched ID, and `handleTerminated` closes `w.subscription` without checking whether a newer subscription replaced it.

**Idiomatic Go design:** Place the watch table, callback sets, OS subscriptions, and debounce `time.Timer` inside **one owner goroutine** running a `select` loop:

- External callers send typed commands (`cmdWatch`, `cmdUnwatch`, `cmdClose`) carrying a reply channel.
- OS filesystem callbacks and termination notifications send events tagged with the specific subscription pointer or a monotonic generation ID.
- The debounce timer fires inside the same `select` loop.

Inside that loop, `add`, `trigger`, `fireCallbacks`, `unwatch`, `watchRemove`, and `handleTerminated` serialize naturally with zero nested mutexes. Stale termination events fail the `ev.sub == state.sub` (or `ev.gen == state.gen`) check and are discarded harmlessly. Where a synchronous read path is needed without channel hops, keep **one mutex** owning the entire state machine, never unlock in the middle of a transition without a state guard, and carry explicit subscription identity into every asynchronous callback.

---

### Pattern C: Scoped Leases, Explicit State Enums, and Identity-Checked Deletion (`api.Session`, `contentmapper.host`, `RefCountCache`, `OwnerCache`)

**Observed failure modes:**
- `api.Session.getSnapshotData` (`tsc/internal/api/session.go:703`) looks up `*snapshotData` under `RLock` and returns it unretained to 480+ handlers, racing `handleRelease` and `Close` even though `retainSnapshotData` exists right below it. `registerSnapshot` inserts entries after `Close` clears `s.snapshots`.
- `contentmapper.projectLease.Transform` drops `h.mu` after `openProjectLocked` and before `connFor`/`MethodTransform`, racing `Refresh` (closed handle) and `Close` (spawning an orphaned `mapperConn{refs: 0}` child process).
- `RefCountCache` encodes `initializing`, `live`, `failed`, and `deleted` implicitly via `refCount <= 0 && !DisableDeletion`, returning zero (`nil`) cache hits under `DisableDeletion: true` and letting `Ref` overwrite live values or resurrect `nil`.
- `OwnerCache.Release` (`tsc/internal/project/ownercache.go:78`) calls `c.entries.Delete(identity)` unconditionally without verifying map-entry pointer identity, so a duplicate release can evict a newly acquired live entry.

**Idiomatic Go design:**
1. **Make scoped borrowing the only way to access managed resources:** Delete unretained lookup helpers. Expose `withSnapshot(id, func(*project.Snapshot) error) error` (or return a retained lease struct whose `Release()` runs in `defer`) that checks `s.closed` and increments `refCount` under one mutex before unlocking. Apply the same call-scoped refcount to `contentmapper.projectLease.Transform` so `Refresh` and `Close` wait for or reject in-flight RPCs consistently and `connForLocked` never spawns a connection for a closed lease.
2. **Use an explicit entry lifecycle enum:** Represent cache entry phases as a typed enum (`entryPending`, `entryReady`, `entryFailed`, `entryDeleted`) guarded by the entry lock. Waiters inspect the state enum directly; a failed entry never passes as ready regardless of `DisableDeletion`, and `Ref` never copies or resurrects from a non-ready entry.
3. **Delete only by pointer identity:** Use Go 1.20+'s `sync.Map.CompareAndDelete(key, entry)` (or `if m[key] == entry { delete(m, key) }` under a mutex). A stale handle or duplicate `Release` then becomes a no-op if a new `*entry` has already replaced it under `key`.

---

### Pattern D: Sharded Maps and Lock-Free Speculative Parsing (`dirty.SyncMap`, `ExtendedConfigCache`)

**Observed failure modes:**
- `dirty.SyncMap` (`tsc/internal/project/dirty/syncmap.go`) attempts lock-free reads plus per-entry locking with `proxyFor` forwarding and `lockedEntry`. Five independent defects emerged from stale clean handles aliasing dirty entries and `Locked` bypassing `proxyFor.mu` after the first `Change` (producing a live `-race` data race, nil-pointer panic, lost deletes, and `ChangeIf`/`DeleteIf` TOCTOU).
- `ExtendedConfigCache` (`tsc/internal/execute/tsc/extendedconfigcache.go` and `tsc/internal/project/ownercache.go`) holds `entry[A].mu` while recursively calling `GetExtendedConfig(B)`. Two goroutines entering a mutual `extends` cycle from opposite ends form an AB-BA lock cycle invisible to goroutine-local `resolutionStack` checks.

**Idiomatic Go design:**
- **Fixed-shard map for copy-on-write builders (`dirty.SyncMap`):** Replace the two-level `SyncMap` + per-entry `sync.Mutex` + `proxyFor` protocol with a fixed array of shards (for example, 32 or 64 shards, each holding one `sync.Mutex` and a plain Go `map[K]*entry`), or a single mutex if profiling shows low contention. Every `Change`, `ChangeIf`, `Delete`, `DeleteIf`, and `Locked` call acquires `shard(key).mu`, resolves the single canonical entry directly, evaluates `cond` and `apply` under that one lock, and releases it. Clean-handle aliasing, `LoadOrStore` races, and `proxyFor` lock escape cease to exist.
- **Speculative lock-free parsing for recursive caches (`ExtendedConfigCache`):** Never hold a per-key mutex across recursive lookups into the same cache. Parse the config file outside the entry lock using the goroutine's local `resolutionStack`, then publish the immutable result via `LoadOrStore` (the design in upstream PR `microsoft/TypeScript#65302` for `OwnerCache`). `tsconfig.json` files are small, so rare duplicate parses on a simultaneous cold miss are inexpensive, and cross-goroutine deadlock is eliminated. If expensive recursive work ever requires strict single-flight deduplication, track in-flight calls and wait-for edges under a single mutex so cycle detection runs across goroutines before blocking.

---

### Pattern E: Wire-Order Registration and Fresh Per-Cycle State (`lsp.Server`, `tsc -b -w`)

**Observed failure modes:**
- In `lsp.Server` (`tsc/internal/lsp/server.go:994-1064`), `readLoop` pushes requests onto `requestQueue`, and `dispatchLoop` later pops them and inserts them into `pendingClientRequests`. A `$/cancelRequest` handled by `readLoop` during queue residency misses `pendingClientRequests` and is silently discarded.
- In `execute/build` (`tsc/internal/execute/build/orchestrator.go`, `buildtask.go`), watch cycles mutate `*BuildTask` in place. Unresolved tasks (`task.resolved == nil`) skip channel re-creation, causing the next cycle's reporter goroutine to unblock immediately on a closed `done` channel (triggering a `-race` data race on `task.result`, a nil-pointer SIGSEGV, and `panic: close of closed channel`). Config reloads also reset `task.upStream` while leaving `task.downStream` intact, leaking replaced `*BuildTask` graphs unboundedly.

**Idiomatic Go design:**
- **Register cancellation at ingress (`readLoop`):** Create `ctx, cancel := context.WithCancel(baseCtx)` and insert `id -> cancel` into `pendingClientRequests` in `readLoop` **before** calling `requestQueue.Put`. Because `readLoop` is the sole reader of the JSON-RPC stream, registration happens-before any later `$/cancelRequest` for that ID, and `dispatchLoop` can short-circuit already-canceled queued requests on pop (`ctx.Err() != nil`).
- **Allocate fresh per-cycle execution structs in `tsc -b -w`:** Closed channels in Go cannot be reset. Keep long-lived cached state (parsed configs, build-info caches) separate from a per-cycle `cycleTask` struct allocated fresh for every `DoCycle` with new `done`/`built` channels and fresh `upStream`/`downStream` edges.

---

## 4. Reference Pattern Already Proven Inside `tsc/internal`: `project.checkerPool`

`CheckerPool.tla` explored 26.9M+ distinct states (depth 17) and 14.5M+ distinct states (depth 28) with zero violations. `tsc/internal/project/checkerpool.go` already demonstrates how the Go pattern works cleanly in this codebase:

1. **One mutex (`p.mu`) owns all mutable state** (`checkers`, `heldBy`, file and request associations, `lastReleased`, `cleanupTimer`, `discarded`, and `globalDiagChanged`).
2. **Blocking happens only outside `p.mu`** on bounded semaphores (`diagSem`, `querySem`, `persistentSem`).
3. **Re-entry validates pointer identity** (`p.checkers[index] == c`, `p.persistentChecker == c`).
4. **Read-and-reset is atomic** (`TakeNewGlobalDiagnostics` reads and clears `p.globalDiagChanged` under `p.mu`).

The lost-notification defect (`SessionGlobalDiag`) only appeared one layer above `checkerPool`, when `Session` moved `globalDiagPublishPending` into an `atomic.Bool` outside `p.mu`.

---

## 5. Engineering Guardrails for Go Concurrency in `tsc/internal`

Two properties of Go explain why these 22 bugs survived normal unit tests and CI `-race` runs:

1. **Go's `-race` detector checks memory synchronization only.** Twenty of the 22 verified defects are data-race-free logical races (deadlocks, lost wakeups, TOCTOU across two mutexes, orphaned child processes, double-closed channels, stale overwrites). `-race` caught only 2 (`dirty.SyncMap.Locked` and `BuildOrchestratorWatch` on `task.result`).
2. **Go does not tie locks to fields in the type system.** Porting imperative multi-step object mutations from single-threaded TypeScript 5 by adding per-field mutexes and `go func()` calls expands the cross-operation state space faster than hand-written tests can cover.

Practical rules for reviewing and refactoring concurrent code in `tsc/internal`:

- **One owner per state machine:** Prefer one goroutine loop (for I/O, timers, and ordered RPC side effects) or one mutex (for in-memory pools like `checkerPool`). Treat structs accumulating three or more mutexes, or pairing an `atomic.Bool` latch with a `sync.Mutex`, as candidates for consolidation.
- **No unbounded `go func()` for ordered side effects:** Route external updates (watchers, diagnostics, registrations) through level-triggered reconcilers with 1-buffered channels.
- **Inspect every lock release:** Any code that unlocks across I/O, RPC, or recursion needs either a retained scoped handle, an identity/generation check on re-entry, or speculative lock-free computation.
- **Use `CompareAndDelete` and explicit state enums in concurrent caches:** Avoid encoding four lifecycle phases in boolean/counter combinations or deleting map keys without checking entry identity.
- **Pair `testing/synctest` with TLA+ for multi-goroutine protocols:** Follow `AGENTS.md`'s guidance to write deterministic in-memory concurrency tests with Go's `testing/synctest` (virtual clocks and `synctest.Wait()`), and use small TLA+ models whenever a component crosses two locks, spawns background goroutines, or manages async resource lifecycles.
