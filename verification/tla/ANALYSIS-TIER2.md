# Architectural Analysis: Tier 2 Concurrency & State-Machine Defects in `tsc/internal`

Branch: `tla-tier2-investigation` (pinned against `microsoft/TypeScript` `main` at `e0fce98`)
Companion reports: [`FINDINGS-TIER2.md`](./FINDINGS-TIER2.md) (Tier 2 ledger), [`ANALYSIS.md`](./ANALYSIS.md) (Tier 1 analysis), [`GO-ARCHITECTURE.md`](./GO-ARCHITECTURE.md) (target Go architecture), [`ROADMAP.md`](./ROADMAP.md) (verification roadmap)
Remediation tracking: `robertpenner/TypeScript#10` (parent epic), `robertpenner/TypeScript#11` through `#19` (clustered fix tickets)

## Summary

Phase 2 modeled 11 concurrent protocols across 6 Go packages (`fswatch`, `execute/build`, `project`, `lsp`, `ipc`, and `ls/autoimport`) using official TLA+ (`tla2tools.jar` / TLC2 2.19). Model checking verified **23 distinct safety invariant violations** (all TLC exit 12, minimal counterexamples of 3 to 12 states), backed by **21 deterministic `go test -race` reproducers** failing against unmodified `tsc/internal` code. All 23 defects are novel upstream on `microsoft/TypeScript` (including two `ipc.SyncConn` bugs that persist after `microsoft/TypeScript#64639` and an `OwnerCache.Release` panic distinct from `microsoft/TypeScript#65302`).

Combining Phase 1 (17 defects, 19 reproducers) and Phase 2 (23 defects, 21 reproducers) yields **40 verified concurrency and state-machine defects** across 20 TLA+ specifications and 40 confirmed Go `-race` reproducers:

- Only **4 of the 40 defects (10%)** trigger Go's `-race` detector (`dirty.SyncMap.Locked`, `BuildOrchestratorWatch` on `task.result`, `SessionInferredOptions` on `s.compilerOptionsForInferredProjects`, and `LspProgressLocale` on `r.server.locale`).
- The remaining **36 of 40 defects (90%)** are data-race-free protocol, lifecycle, framing, or ownership failures: unrecovered panics and SIGSEGV crashes, permanent deadlocks, silent cross-call payload swaps, permanent clean-cache poisoning, stuck UI spinners, leaked or stolen file watches, stale diagnostic overwrites, and orphaned child processes.

Phase 1 showed how lock-splitting and implicit entry states cause bugs in shared concurrent primitives. Phase 2 extends those findings into orchestration, wire framing, cancellation, and multi-owner caches, exposing **four new defect classes** that did not appear in Phase 1: unordered edge-triggered side-effect fan-out, half-duplex wire multiplexing without correlation IDs, in-place reuse of one-shot Go channels and mutable task graphs across cycles, and non-transactional cancellation commits plus denormalized keys.

Each defect family maps directly to an established formal principle (reconciliation lattices, ABA/CAS identity preservation, total phase transition tables, wire correlation IDs, affine one-shot resources, atomic cancellation commit, and relational key normalization). In six of the seven families, a sibling component inside `tsc/internal` already implements the safe version of the same principle and passed audit with zero violations.

---

## 1. Severity and Reachability Triage (23 Tier 2 Findings)

Unlike Phase 1, where 10 of 17 defects lived in lower-level primitives (`dirty.SyncMap`, `RefCountCache`, `contentmapper`, `lspwatcher`), every Tier 2 finding directly affects interactive IDE sessions, `tsc -b -w` watch builds, or IPC/auto-import correctness. Triaging by failure consequence separates two remediation waves under `robertpenner/TypeScript#10`.

### Wave 1: Process Crashes, SIGSEGV, and Silent Wire Corruption (8 findings, 4 tickets)

1. **`lsp.Server` unrecovered lifecycle panics** (`tsc/internal/lsp/server.go`, Findings #15, #16, #17; `robertpenner/TypeScript#16`)
   - Three distinct nil-pointer and `close of closed channel` panics execute directly on `dispatchLoop` (outside the per-request `defer s.recover` used only for async goroutines) and crash the entire language server process: document requests sent between `initialize` and `initialized` (`s.session == nil`), requests sent after `shutdown` (`s.session.snapshot == nil`), and duplicate `initialized` notifications (`close(s.initComplete)` twice).
2. **`tsc -b -w` unresolved-project double-close panic/SIGSEGV and stale downstream leak** (`tsc/internal/execute/build/orchestrator.go`, `buildtask.go`, Findings #4, #5; `robertpenner/TypeScript#12`)
   - In a watch build with an unresolved project alongside a valid project, editing a source file skips recreating `task.done` and `task.built`, causing a live `-race` data race on `task.result`, a nil-pointer SIGSEGV in `(*BuildTask).report`, and `panic: close of closed channel` in `unblockDownstream`. Separately, config reloads reset `task.upStream` without clearing `task.downStream`, retaining stale replaced `*BuildTask` graphs unboundedly.
3. **`OwnerCache.Release` blind delete causing `AddOwner` panic** (`tsc/internal/project/ownercache.go`, `snapshot.go`, Finding #6; `robertpenner/TypeScript#13`)
   - Whenever two `tsconfig.json` files in one snapshot extend the same base config, `Snapshot.dispose` calls `Release` twice. A delayed second `Release` sees `len(oldEntry.owners) == 0` and blindly calls `c.entries.Delete(identity)`, evicting a newly acquired live entry and crashing the next `Snapshot.Clone` with `panic("OwnerCache.AddOwner: entry not found")`.
4. **`ipc.SyncConn` silent cross-call response swap and cancelled-call connection poison** (`tsc/internal/ipc/conn_sync.go`, Findings #20, #21; `robertpenner/TypeScript#18`)
   - Persists after `microsoft/TypeScript#64639`. Because `SyncConn.Call` uses `method` as `msg.ID` and unlocks `c.mu` during incoming notifications, two concurrent callers for the same method silently receive each other's payloads with `err == nil`. Separately, `Call` writes onto the pipe before checking `ctx.Err()`, leaving an orphaned response that permanently kills `SyncConn.Run()`.

### Wave 2: Live Data Races, Silent Cache Poisoning, Stuck UI, and Watch/Diagnostics Drift (15 findings, 5 tickets)

5. **`project.Session` out-of-order program diagnostics and unsynchronized inferred options** (`tsc/internal/project/session.go`, Findings #10, #11, #12; `robertpenner/TypeScript#15`)
   - `publishProgramDiagnostics` runs unserialized on `backgroundQueue`, letting an older snapshot overwrite cleared `tsconfig.json` diagnostics with stale errors. `DidChangeCompilerOptionsForInferredProjects` skips `s.snapshotUpdateMu`, causing a live `-race` data race on `s.compilerOptionsForInferredProjects`, stale-overlay overwrites against `DidOpenFile`, and a nil-snapshot panic against `Close()`.
6. **`ls/autoimport` cancelled clean-commit poisoning and cross-bucket `entrypoints` clobber** (`tsc/internal/ls/autoimport/registry.go`, `specifiers.go`, `tsc/internal/project/session.go`, Findings #22, #23; `robertpenner/TypeScript#19`)
   - A mid-build cancellation inside `buildProjectBucket` leaves `result.err == nil`, and `Session.GetLanguageServiceWithAutoImports` adopts the snapshot without checking `ctx.Err()`, permanently committing a 0-export clean project bucket (`Dirty() == false`) that suppresses project auto-imports for later non-cancelled requests. Separately, deleting a symlinked workspace package from one `node_modules` bucket deletes its shared `ResolvedPath` from registry-wide `Registry.entrypoints`, causing an untouched sibling app to bypass conditional `"exports"` checks and emit illegal relative paths into `dist/`.
7. **`lsp.Server` progress locale data race/stuck spinner and dynamic watch registry races** (`tsc/internal/lsp/progress.go`, `server.go`, Findings #13, #14, #18, #19; `robertpenner/TypeScript#17`)
   - `serverProgressReporter.localize` reads `r.server.locale` without `localeMu.RLock()` (`DATA RACE`), and `projectLoadingProgress` keys its refcount map by the localized string, so changing locale mid-load leaks `loading.Size() == 1` and suppresses `WorkDoneProgressEnd` forever. Separately, `Server.WatchFiles` drops timed-out IDs before adding them to `s.watchers` (stranding client registrations) and `Server.UnwatchFiles` checks `Has(id)` before an unlocked RPC, sending duplicate unregister RPCs under concurrency.
8. **`project.Session` watch protocol leaks, rollback stranding, and live-watch theft** (`tsc/internal/project/session.go`, `watch.go`, Findings #7, #8, #9; `robertpenner/TypeScript#14`)
   - Unserialized `updateWatches` allows `UnwatchFiles` to overtake `WatchFiles` (leaking client watches); concurrent `Acquire` during a failing `WatchFiles` leaves a live project unwatched with refcount 1; closing or retrying a failed/pending watcher ignores `IsPending` and double-releases shared globs, unwatching another live project.
9. **`fswatch` 3-lock directory watch lifecycle TOCTOU** (`tsc/internal/fswatch/watcher.go`, Findings #1, #2, #3; `robertpenner/TypeScript#11`)
   - Concurrent `WatchDirectories` and `watch.Close` across `w.mu`, `dw.mu`, and `b.mu` return a live `Watch` (`err == nil`) whose `debounce` is `nil`, whose OS subscription was torn down, or whose `dirWatch` was deleted from `w.dirWatches`.

---

## 2. Seven Structural Root-Cause Families and Their Theoretical Foundations

Comparing Phase 1 (`ANALYSIS.md`) and Phase 2 reveals **three families that recurred from Phase 1** and **four genuinely new families** that emerged when auditing stateful orchestration, wire framing, watch cycles, cancellation, and shared caches.

| # | Root-Cause Family | Tier 2 Findings (Count) | Relation to Phase 1 | Underlying Formal Theory | In-Repo Safe Contrast |
|---|---|---|---|---|---|
| 1 | Unordered edge-triggered side-effect fan-out | #7, #8, #9, #10 (4) | Extends Pattern 1 (plus Tier 1 #4) | Level-triggered convergence over a monotone desired-state lattice | `updateContentMapperRegistrations` (`session.go:1596`) |
| 2 | Split lock domains, ABA deletion, and indeterminate-commit RPCs | #1, #2, #3, #6, #13, #18, #19 (7) | Extends Patterns 1 & 2 | Linearizability, CAS/ABA identity preservation, two-phase RPC state | `project.checkerPool`, `pendingServerRequests` (`server.go:880`) |
| 3 | Implicit lifecycle encoded across nullable fields and one-shot channels | #11, #12, #15, #16, #17 (5) | Extends Pattern 3 (from caches to servers/sessions) | Total protocol transition functions and phase-indexed typestate invariants | `background.Queue` (`queue.go:33`), `binder.BindSourceFile` (`file.BindOnce`) |
| 4 | Half-duplex wire multiplexing without correlation IDs or cancel framing | #20, #21 (2) | **New in Phase 2** | Session types, unique request-response correlation, transactional wire framing | `ipc.AsyncConn` (`conn_async.go`) |
| 5 | Mutable in-place reuse of affine one-shot channels and task graphs | #4, #5 (2) | **New in Phase 2** | Separation of persistent caches from affine per-execution coordination state | `computeScheduleOrder` / `waitOnUpstream` DAG |
| 6 | Non-transactional cancellation committing partial state as clean | #22 (1) | **New in Phase 2** | All-or-nothing transactional commit and structured cancellation propagation | `buildNodeModulesBucket` (`registry.go:1712`), `warmAutoImportCache` (`session.go:2143`) |
| 7 | Denormalized / view-dependent keys breaking canonical identity and ownership | #14, #23 (2) | **New in Phase 2** | Relational normalization (invariant canonical keys and partition-scoped ownership) | Local per-bucket state in `autoimport` |

Total: 4 + 7 + 5 + 2 + 2 + 1 + 2 = **23 of 23 Tier 2 findings**.

### Family 1: Edge-Triggered Unordered Side-Effect Dispatch vs. Level-Triggered Convergence

- **Findings:** `SessionWatchProtocol` (#7, #8, #9), `SessionProgramDiag` (#10); pairs with Tier 1 `SessionGlobalDiag`.
- **What goes wrong:** `Session.updateSnapshot` enqueues edge-triggered deltas (`oldSnapshot -> newSnapshot`) onto `background.Queue`, which runs every callback in an independent, unordered goroutine. Register/unregister and error/clear RPCs do not commute: `Unwatch(id)` overtaking `Watch(id)` leaks a client watch forever, and `PublishDiagnostics(tsconfig, [err])` overtaking `PublishDiagnostics(tsconfig, [])` restores stale errors. Furthermore, `watchRegistry.Acquire` increments a shared refcount *before* the remote `WatchFiles` RPC succeeds, collapsing tentative local intent and confirmed remote state into one counter; rolling back a failure then either strands a concurrent sharer at refcount 1 or double-releases a live watcher on later removal.
- **What theory tells us:** Asynchronous external sinks cannot be maintained reliably by unordered edge-triggered diffs because delta application is non-commutative and remote RPCs are fallible. Control theory and distributed reconciliation (Kubernetes-style controllers) replace edge-triggered deltas with **level-triggered state convergence**:
  1. Producers publish only the latest immutable desired state (`latestSnapshot` with monotonic `snapshot.ID()`) and signal a 1-buffered wake channel.
  2. One serial reconciler goroutine owns the private `applied` state (exact set of confirmed active client watches or last-published diagnostics per URI) and computes `diff(applied, desired)` on each pass.
  3. Tentatively requested watches are tracked separately from confirmed active watches, so a failed registration is never treated as active and cannot be released against a live watcher.
- **In-repo proof:** `updateContentMapperRegistrations` (`tsc/internal/project/session.go:1596-1626`) already uses a dedicated serialization mutex and a monotonic `registeredContentMapperSnapshotID` watermark and passed our Target 2 audit cleanly.
- **Concrete fix direction (`robertpenner/TypeScript#14`, `#15`):** Serialize `publishProgramDiagnostics` with a dedicated mutex plus monotonic `snapshot.ID()` watermark (or move watches, program diagnostics, and global diagnostics onto single-owner level-triggered reconcilers). In `updateWatch` / `watchRegistry`, separate pending registration from confirmed ownership so `IsPending` watchers never release shared globs and concurrent sharers wait on or retry failed registrations.

### Family 2: Split Lock Domains, ABA Deletion, and Indeterminate-Commit RPCs

- **Findings:** `FSWatchLifecycle` (#1, #2, #3), `OwnerCacheRelease` (#6), `LspProgressLocale` (#13), `LspWatchRegistry` (#18, #19).
- **What goes wrong:** Three closely related concurrency violations appear across these seven findings:
  1. **Multi-lock split transitions (`fswatch`):** `WatchDirectories` and `watch.Close` acquire and drop `w.mu`, `dw.mu`, and `b.mu` across four separate critical sections, allowing teardown to destroy `dw.debounce`, remove `dw` from `w.dirWatches`, or tear down the OS subscription while a concurrent caller holds `dw` live.
  2. **ABA key deletion (`OwnerCache.Release`):** `c.entries.Delete(identity)` deletes by *key* rather than by *entry pointer*. A duplicate `Release` operating on old empty entry `E1` deletes newly inserted live entry `E2`, crashing `AddOwner`.
  3. **Indeterminate-commit RPCs (`LspWatchRegistry`):** `Server.WatchFiles` adds `id` to `s.watchers` only if `sendClientRequest` returns `nil`, treating a local timeout as proof that the remote client did not install the watch. In reality, a timed-out RPC has *indeterminate* remote state: the client often finishes installing registration `id`, which `Server.UnwatchFiles` then refuses to remove. Symmetrically, `UnwatchFiles` checks `Has(id)` before the unlocked RPC and deletes afterward, allowing duplicate unregister RPCs.
- **What theory tells us:**
  - **Linearizability (Herlihy & Wing):** A compound operation that releases locks mid-transition has no single linearization point unless either (a) all coupled state moves under one serialization owner (single mutex or single-owner event loop), or (b) every re-entry validates an explicit object/generation identity.
  - **ABA elimination via CAS:** Deleting an entry from a concurrent map must always be conditional on entry identity (`sync.Map.CompareAndDelete(key, entry)` in Go 1.20+, or `if m[k] == entry { delete(m, k) }` under a mutex) and, in `OwnerCache.Release`, guarded on prior owner membership.
  - **Two-phase intent state for distributed RPCs:** Before releasing a lock to perform a network/LSP RPC, transition the local entry into an explicit in-flight state (`Registering`, `Unregistering`). On timeout, transition to `Uncertain` rather than deleting the record, because `UnwatchFiles` must remain permitted to clean up a potentially installed remote watcher; on `UnwatchFiles`, claim the `Unregistering` transition atomically so only one caller transmits `client/unregisterCapability`.
- **In-repo proof:** `project.checkerPool` (26.9M+ TLC states, 0 errors) keeps all mutable fields under one mutex and validates pointer identity on re-entry; `pendingServerRequests` (`tsc/internal/lsp/server.go:880-905`) deletes its map entry under `pendingServerRequestsMu` before closing/sending on the response channel.
- **Concrete fix direction (`robertpenner/TypeScript#11`, `#13`, `#17`):** Use `CompareAndDelete(identity, entry)` plus prior-membership check in `OwnerCache.Release`; replace `s.watchers` (`SyncSet`) with a mutex-guarded state map (`Registering / Active / Uncertain / Unregistering`) in `lsp.Server`; call `r.server.GetLocale()` in `serverProgressReporter.localize`; consolidate `fswatch`'s `dirWatches`/`callbacks`/`debounce`/subscription lifecycle under one serialization boundary (single-owner loop or single lock with generation-checked teardown).

### Family 3: Implicit Lifecycle Encoded Across Nullable Pointers and One-Shot Primitives

- **Findings:** `LspServerLifecycle` (#15, #16, #17), `SessionInferredOptions` (#11, #12).
- **What goes wrong:** Neither `lsp.Server` nor `project.Session` represents its lifecycle as one explicit state machine checked at a single entry point. Instead, lifecycle phase is inferred piecemeal from `s.initializeParams != nil`, `s.session != nil`, `s.session.snapshot != nil`, and the open/closed state of `s.initComplete`. Whenever a new handler registrar or session mutator is added, forgetting one nil check or one mutex acquisition immediately introduces a crash or data race:
  - 3 of 5 handler registrars in `lsp/server.go` omit `if s.session == nil`.
  - `handleShutdown` calls `s.session.Close()` without transitioning the server to shut down or waiting for in-flight async handlers.
  - `handleInitialized` calls `close(s.initComplete)` with no transition guard against a second `initialized` notification.
  - `DidChangeCompilerOptionsForInferredProjects` is the lone snapshot mutator in `project/session.go` that omits `s.snapshotUpdateMu`, racing with concurrent calls, losing concurrent `DidOpenFile` overlays, and cloning a nil `s.snapshot` after `Close()`.
- **What theory tells us:** **Total transition functions and phase-indexed invariants (typestate).** An $M$-handler by $N$-phase protocol cannot be kept sound by duplicating guards in $M$ handlers. Defining a single explicit phase enum checked at one centralized dispatch boundary guarantees totality across all $M \times N$ pairs and enforces phase-resource coupling:
  - `lsp.Server`: `Uninitialized -> Initializing -> Running -> Draining -> ShutDown`. Invariant: `phase == Running => s.session != nil`; `Shutdown` transitions `Running -> Draining`, rejects new requests with `ErrorCodeInvalidRequest`, cancels and joins all in-flight request goroutines, and closes `s.session` only upon entering `ShutDown`. Only `Initializing -> Running` creates `s.session` and closes `s.initComplete`.
  - `project.Session`: `Open -> Closing -> Closed`, with **every** mutator (including `DidChangeCompilerOptionsForInferredProjects`) entering one serialized snapshot-update path under `s.snapshotUpdateMu` that rejects calls when `s.closed` (`oldSnapshot == nil`).
- **In-repo proof:** `background.Queue` (`tsc/internal/project/background/queue.go:33-49`) guards `q.closed` and `q.wg.Add(1)` under one mutex `q.mu`, preventing `WaitGroup` add-after-wait panics; `binder.BindSourceFile` uses `file.BindOnce` so duplicate calls are idempotent.
- **Concrete fix direction (`robertpenner/TypeScript#15`, `#16`):** Add an explicit lifecycle phase enum and centralized `dispatchLoop` guard plus async-request drain barrier in `lsp.Server`; acquire `s.snapshotUpdateMu` in `DidChangeCompilerOptionsForInferredProjects` and guard `updateSnapshot` against `oldSnapshot == nil`.

### Family 4: Half-Duplex Wire Multiplexing Without Correlation IDs or Cancellation Framing (New in Phase 2)

- **Findings:** `IpcSyncConn` (#20, #21).
- **What goes wrong:** `SyncConn` multiplexes synchronous requests, peer callbacks, and fire-and-forget notifications over one ordered pipe. Upstream `microsoft/TypeScript#64639` added a `c.pending` LIFO stack to fix nested peer-callback ordering, yet two fundamental framing bugs remain:
  1. `Call` sets `msg.ID = jsonrpc.NewIDString(method)` (not unique per call) and releases `c.reading` / `c.mu` while executing `HandleNotification`. A concurrent caller for the same method wakes up during the notification handler, writes its request, and consumes the first caller's response from the wire; both callers return `err == nil` with silently swapped payloads.
  2. `Call` writes the request onto the pipe (`conn_sync.go:211`) before checking `ctx.Err()` (`conn_sync.go:215`). A cancelled call abandons its in-flight reply on the wire, poisoning `SyncConn.Run()` with `ipc: unexpected response message in sync connection` or feeding the stale reply to a later call.
- **What theory tells us:** **Session types and transport-layer demultiplexing.** Over a shared bidirectional stream, safe concurrency requires separating framing from concurrency via one of two mathematically sound models:
  1. **Unique correlation IDs + single demultiplexing reader:** Every request gets a unique monotonic ID; a single reader routes each response by exact ID to that call's private one-shot channel, and dispatches notifications without relinquishing framing ownership. Cancelled callers drop their waiter entry and the reader safely discards late replies for unknown IDs.
  2. **Strict single-flight half-duplex turn ownership (if wire IDs cannot change):** External concurrent callers must never acquire the wire while an outer call is suspended in `HandleNotification` (only a call explicitly nested within the active callback stack may push onto `c.pending`). Before writing any request, check `ctx.Err() != nil`; once a request is written onto an uncancelable half-duplex wire, either drain its reply before returning or explicitly close the connection because stream framing is lost.
- **In-repo proof:** `ipc.AsyncConn` (`tsc/internal/ipc/conn_async.go`) in the very same package already implements Model 1 (monotonic atomic IDs, `pendingMu`, `writeMu`, clean teardown) and passed our Target 4 audit with zero defects.
- **Concrete fix direction (`robertpenner/TypeScript#18`):** Check `ctx.Err()` before `WriteRequest`. Where wire-compatible with the JS peer, assign unique request IDs or maintain per-call waiter channels instead of matching on `method`; otherwise block external concurrent callers while any `c.pending` call is active (distinguishing nested callback re-entrancy from independent goroutines) and drain or close the pipe on post-write cancellation.

### Family 5: Mutable In-Place Reuse of Affine One-Shot Primitives and Graphs Across Cycles (New in Phase 2)

- **Findings:** `BuildOrchestratorWatch` (#4, #5).
- **What goes wrong:** In `tsc -b -w`, `*BuildTask` structs hold both persistent build metadata and ephemeral per-cycle coordination state (`done chan struct{}`, `built chan struct{}`, `result`, `upStream`, `downStream`). Two bugs follow directly from mutating `*BuildTask` in place across cycles:
  1. `checkTasksForEventChanges` returns early (`continue`) when `task.resolved == nil`, skipping the channel reallocation at lines 723-724. On the next watch cycle, the already-closed `done` channel unblocks the reporter goroutine immediately while `buildOrCleanProject` writes `task.result` and later closes `task.done` a second time (`DATA RACE` + `SIGSEGV` + `panic: close of closed channel`).
  2. `createBuildTasks` clears `task.upStream = nil` on reused tasks during config reload but forgets `task.downStream`, leaking replaced `*BuildTask` graphs on every downstream `tsconfig.json` edit.
- **What theory tells us:** **Affine / linear resource lifecycles vs. persistent state.** In Go, a broadcast completion channel (`chan struct{}`) is an **affine one-shot resource**: it starts open, transitions to closed once, and can never transition back. Likewise, a build cycle's bidirectional DAG edges (`upStream` / `downStream`) are derived properties of one graph generation. Separating long-lived cached state (parsed configs, build-info cache) from freshly allocated per-cycle execution state (`cycleTask` with fresh `done`/`built` channels and fresh adjacency slices) eliminates partial-reset bugs because a new cycle cannot inherit a closed channel or a stale pointer from an earlier cycle.
- **Concrete fix direction (`robertpenner/TypeScript#12`):** Either allocate fresh per-cycle execution state holding `built`, `done`, `result`, `upStream`, and `downStream` (keeping persistent caches separate), or unconditionally reinitialize `built`/`done` for every scheduled task before `buildOrCleanOrder` and reset `task.downStream = nil` alongside `task.upStream = nil` during `GenerateGraphReusingOldTasks`.

### Family 6: Non-Transactional Cancellation Committing Partial Results as Clean (New in Phase 2)

- **Findings:** `AutoImportRegistry` (#22).
- **What goes wrong:** `buildProjectBucket` checks `ctx.Err()` at entry and guards each parallel file worker with `if ctx.Err() == nil`, so a mid-build cancellation skips export extraction cleanly. However, `buildProjectBucket` forgets `result.err = ctx.Err()` after `wg.Wait()`, returning `err == nil` with zero extracted exports. `Registry.Prepare` stamps the empty bucket `BucketStateClean` (`Dirty() == false`), and `Session.GetLanguageServiceWithAutoImports` adopts that snapshot onto `s.snapshot` without checking `ctx.Err()`. Every subsequent non-cancelled auto-import request then trusts `Dirty() == false` and silently returns zero project exports until a file edit dirties the bucket.
- **What theory tells us:** **Transactional atomicity (all-or-nothing commit under abort) and structured concurrency error propagation.** Context cancellation is an *abort*, never a valid completion that satisfies a `Clean` postcondition (`Dirty() == false => all files in bucket extracted`). Both ends of a parallel build pipeline must enforce the commit rule centrally rather than per-caller:
  1. At the fan-out join (`wg.Wait()`), any worker pool that checks `ctx.Err()` must propagate `ctx.Err()` as a non-nil build error before returning a result.
  2. At the state-transition commit boundary (`Registry.Prepare` and `Session` snapshot adoption), reject committing any derived cache built under a cancelled context (`ctx.Err() != nil`).
- **In-repo proof:** Two sibling paths in the exact same subsystem already obey their half of this rule: `buildNodeModulesBucket` (`registry.go:1712`) and `updateNodeModulesBucket` (`registry.go:1832`) set `result.err = ctx.Err()`, and `warmAutoImportCache` (`session.go:2143`) checks `if ctx.Err() != nil` before adopting the snapshot. The defect appeared precisely where those two guards were omitted on the parallel project-bucket / interactive-request path.
- **Concrete fix direction (`robertpenner/TypeScript#19`):** Propagate `result.err = ctx.Err()` in `buildProjectBucket` after `wg.Wait()` (and refuse marking any bucket clean when `ctx.Err() != nil`), and guard `tryAdoptSnapshotChangeInBackground` in `Session.GetLanguageServiceWithAutoImports` with `if ctx.Err() == nil`.

### Family 7: Denormalized / View-Dependent Keys Breaking Canonical Identity and Ownership (New in Phase 2)

- **Findings:** `LspProgressLocale` (#14), `AutoImportRegistry` (#23).
- **What goes wrong:** Two bugs in unrelated packages share the exact same data-modeling flaw:
  1. `projectLoadingProgress.run` keys its ref-counted `loading` map by the localized display string (`"Project 'foo'"` in English, `"Projekt „foo“"` in German). Changing locale between `ProgressStart` and `ProgressFinish` breaks key equality for the same logical operation, leaking `loading.Size() == 1` and leaving the client progress spinner running forever even after fixing the `localeMu` data race.
  2. `Registry.entrypoints` flattens per-bucket package entrypoint metadata into one registry-wide map keyed solely by symlink `ResolvedPath`. When sibling workspace apps (`app1` and `app2`) both symlink to a shared package with conditional `"exports"`, removing the package from `app2` deletes `ResolvedPath` from `Registry.entrypoints` unconditionally while `app1`'s bucket stays clean and untouched. `app1` then misses `v.registry.entrypoints[export.Path]`, skips the `"exports"` condition check, and emits an illegal relative path into `dist/`.
- **What theory tells us:** **Relational normalization: canonical key invariance and owner-scoped lifetime.**
  - Any open/close pairing table (`Start`/`Finish`, `Acquire`/`Release`) requires an **invariant canonical key** unaffected by orthogonal presentation state (locale, formatting). Localization belongs strictly at the render boundary (`WorkDoneProgressBegin`/`Report`), never in the refcount key.
  - Derived metadata shared across independent partitions (`node_modules` buckets) must preserve the **many-to-many ownership relation** between partitions and targets: either store `entrypoints` inside each owning bucket (normalizing ownership to match the bucket lifecycle), or maintain a reference count / owner-bucket set per `ResolvedPath` so deleting from bucket `app2` only removes `ResolvedPath` when no surviving bucket still references it.
- **Concrete fix direction (`robertpenner/TypeScript#17`, `#19`):** Key `projectLoadingProgress`'s active map by canonical `(message, args)` identity and localize only when emitting notifications; scope `entrypoints` per `node_modules` bucket (or track owning bucket references before deleting a `ResolvedPath` from `Registry.entrypoints`).

---

## 3. Why Safe Siblings in `tsc/internal` Passed (In-Repo Proof of the Theory)

Every target in Phase 2 uncovered clean contrast implementations inside the exact same packages whose bugs TLC found. Comparing buggy code directly against its clean neighbor confirms that the theory-informed fixes fit Go and `tsc/internal`'s own idioms without requiring foreign frameworks:

| Buggy Component | Clean Neighbor in Same Package | Exact Property That Made the Neighbor Safe |
|---|---|---|
| `updateWatches` & `publishProgramDiagnostics` (`session.go`) | `updateContentMapperRegistrations` (`session.go:1596-1626`) | Dedicated serialization mutex + monotonic `snapshot.ID()` staleness guard |
| `ipc.SyncConn` (`conn_sync.go`) | `ipc.AsyncConn` (`conn_async.go`) | Unique monotonic atomic request IDs + single demux reader + `pendingMu`/`writeMu` |
| `buildProjectBucket` (`registry.go:1240`) & `GetLanguageServiceWithAutoImports` (`session.go:1311`) | `buildNodeModulesBucket` (`registry.go:1712`) & `warmAutoImportCache` (`session.go:2143`) | Explicit `ctx.Err()` propagation at worker join and before snapshot adoption |
| `LspWatchRegistry` (`server.go:300-355`) | `pendingServerRequests` (`server.go:880-905`) | Atomic check-and-delete under lock before channel close/send |
| `LspServerLifecycle` (`server.go:1417, 1441, 1469`) | `registerRequestHandler` (`server.go:1399`) & `background.Queue` (`queue.go:33`) | Explicit closed/uninitialized phase check before operating on managed state |
| `FSWatchLifecycle` (`watcher.go`) & `OwnerCacheRelease` (`ownercache.go`) | `project.checkerPool` (`checkerpool.go`, 26.9M+ TLC states) | Single lock domain + pointer-identity validation on re-entry |

---

## 4. How These Patterns Guide Remediation Order and Verification

When executing `robertpenner/TypeScript#11` through `#19`, three practical lessons apply across every ticket:

1. **Fix the invariant, not the specific counterexample trace.** In `IpcSyncConn`, upstream `microsoft/TypeScript#64639` patched nested callback ordering with a `c.pending` stack while leaving non-unique `method` IDs and unlocked notification gaps intact, which left response swapping reachable through a 12-state trace. Similarly, fixing only `localeMu.RLock()` in `LspProgressLocale` clears the `-race` failure while leaving the stuck-spinner key bug untouched. Every fix ticket should verify the **full fixed TLA+ specification** (exit 0 across all reachable states) in `verification/tla/scripts/run-tlc-tier2.sh` alongside its Go `-race` regression tests.
2. **Enforce invariants at centralized boundaries rather than per-callsite discipline.** Bugs #11, #12, #15, #16, #17, and #22 all happened because 4 out of 5 callers remembered a lock or nil check or `ctx.Err()` check and 1 caller forgot. Moving phase checks into `dispatchLoop`, snapshot locking into `updateSnapshot` / a session coordinator, and cancellation checks into `Prepare` / snapshot adoption prevents the 6th future caller from reintroducing the same defect.
3. **Do not rely on `go test -race` alone as a concurrency oracle.** Across Phases 1 and 2 combined, 36 of 40 verified bugs (90%) pass `go test -race` cleanly when tested with single-operation or happy-path tests. Every regression test should deterministically drive the cross-operation interleaving uncovered by TLC (using channel barriers, mock clients, or `testing/synctest`) and assert the observable protocol invariant directly (no swapped payloads, non-empty auto-imports after cancellation, `WorkDoneProgressEnd` delivered after locale switch, zero leaked client watches, zero panics across all lifecycle phases).
