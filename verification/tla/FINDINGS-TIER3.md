# TLA+ Formal Verification Findings: Tier 3 Investigation

Branch: `tla-tier2-investigation` (base `e0fce98` / `main`)
Tooling: Official `tla2tools.jar` (TLC2 Version 2.19) + Go 1.27.1 (`go test -race`)

Run all Tier 3 TLC checks:
```bash
./verification/tla/scripts/run-tlc-tier3.sh
```

Run all Tier 3 Go `-race` reproducers:
```bash
./verification/tla/scripts/run-repros-tier3.sh
```

## Summary Table

| # | Spec | Target Code | Invariant / Failure | TLC Verdict | Go `-race` Reproducer | Upstream Status |
|---|---|---|---|---|---|---|
| 1 | `ApiSessionLifecycle` | `tsc/internal/api/session.go` | `NoPostCloseLspRefLeak`: `handleGetCurrentLanguageServerSnapshot` acquires `s.languageServerUpdateMu` after `Session.Close()` ran `releaseLanguageServerRefs()`, calls `projectSession.APIUpdate`, and leaks open projects/files/synthetic programs into the live shared LSP `project.Session` permanently (`s.closeOnce` already fired) | Exit 12 (`ApiSessionLifecycle_LspRefs.cfg`) | `TestReproApiSessionLspSnapshotAfterCloseLeaksRefs` (`FAIL`) | Novel (distinct from Tier 1 `ApiSessionSnapshot`, which modeled `s.snapshots` only) |
| 2 | `ApiSessionLifecycle` | `tsc/internal/api/session.go` | `NoPostCloseLeaseLeak`: `registerSourceFileLease` locks `s.sourceFileLeasesMu` and inserts a `*project.SourceFileLease` without checking whether `Session.Close()` already ran `releaseSourceFileLeases()`, pinning `*ast.SourceFile` refcounts in the shared `parseCache` | Exit 12 (`ApiSessionLifecycle_SourceFileLease.cfg`) | `TestReproApiSessionSourceFileLeaseAfterCloseLeak` (`FAIL`) | Novel |
| 3 | `ApiSessionLifecycle` | `tsc/internal/api/session.go` | `NoPostCloseBatchPageLeak`: `paginateBatchResponses` stores continuation pages into `s.batchResponsePages` after `Session.Close()` cleared it, leaking pages permanently | Exit 12 (`ApiSessionLifecycle_BatchPages.cfg`) | `TestReproApiSessionBatchResponsePagesAfterCloseLeak` (`FAIL`) | Novel |
| 4 | `ContentMapperTransformClose` | `tsc/internal/contentmapper/hostimpl.go` | `NoNilProjectDeref`: `host.Close()` sets `h.projects = nil`, causing `host.Project(spec)` to return `nil`; `host.Transform(mapper, request)` calls `defer project.Close()` and `project.Transform(...)` with no `project == nil` check, panicking with a nil pointer dereference | Exit 12 (`ContentMapperTransformClose_NilDeref.cfg`) | `TestReproContentMapperHostTransformAfterCloseNilDerefPanic` (nil-pointer panic crash) | Novel (persists after `microsoft/TypeScript#65492`) |
| 5 | `ContentMapperTransformClose` | `tsc/internal/contentmapper/hostimpl.go` | `NoLeakedConnRef`: `host.Project(spec)` loops over `spec.Mappers` without deduplicating repeated `*Mapper` pointers (unlike `host.Acquire`), inserting two entries into `h.projects`, incrementing `connEntry.refs` twice, and overwriting `lease.entries[mapper]`; `projectLease.release()` only deletes one entry, leaving one `h.projects` entry and `connEntry.refs == 1` leaked forever | Exit 12 (`ContentMapperTransformClose_DupMapperLeak.cfg`) | `TestReproContentMapperProjectDuplicateMapperLeaksConnRef` (`FAIL`) | Novel |
| 6 | `CompilerFilesParserDepth` | `tsc/internal/compiler/filesparser.go` | `LoadedFileStartsSubtasks`: `filesParser.start()` updates `data.lowestDepth` and `data.startedSubTasks` before checking `if task.elideOnDepth && currentDepth > w.maxDepth { return }`; an elided JS import from `node_modules` at depth 1 poisons `data.lowestDepth = 1` and returns without loading, so a later non-elided arrival at depth 1 loads the file into `Program` while skipping `w.start(..., subTasks, ...)` and silently dropping all its transitive imports and references | Exit 12 (`CompilerFilesParserDepth_DropsSubtasks.cfg`) | `TestReproCompilerFilesParserElideOnDepthDropsTransitiveImports` (`FAIL`) | Novel (missed in `microsoft/TypeScript#64632`) |
| 7 | `CompilerFilesParserDepth` | `tsc/internal/compiler/filesparser.go` | `LowestNonElidedDepthReached`: after a non-elided arrival loads a file at depth 3 (with `maxDepth = 1`), an elided JS arrival at depth 2 (`> maxDepth`) lowers `data.lowestDepth` from 3 to 2 and returns without restarting subtasks; a subsequent non-elided arrival at depth 2 sees `lowered = (2 < 2) = false` and leaves subtasks stuck at depth 3 | Exit 12 (`CompilerFilesParserDepth_PoisonsRestart.cfg`) | `TestReproCompilerFilesParserElideOnDepthPoisonsDepthRestart` (`FAIL`) | Novel (re-breaks `microsoft/TypeScript#64632`'s depth-restart invariant) |

All 4 fixed model configurations pass TLC2 2.19 exhaustively with exit code 0:

- `ApiSessionLifecycle_Fixed.cfg`: 360 states generated, 147 distinct states, 0 errors.
- `ContentMapperTransformClose_Fixed.cfg`: 40 states generated, 21 distinct states, 0 errors.
- `CompilerFilesParserDepth_Fixed_DropsSubtasks.cfg`: 14 states generated, 9 distinct states, 0 errors.
- `CompilerFilesParserDepth_Fixed_PoisonsRestart.cfg`: 56 states generated, 27 distinct states, 0 errors.

---

## Target #1: `tsc/internal/api` Session Teardown Beyond `s.snapshots`

### `ApiSessionLifecycle` (`tsc/internal/api/session.go`)

Tier 1 (`ApiSessionSnapshot.tla`) modeled `s.snapshots` against `Session.Close()`. Auditing the rest of `Session.Close()` (`session.go:5789-5810`) shows the same missing terminal-state pattern across three other independent resource tables owned by `Session`, plus an unstopped profiler:

1. **LSP reference leak (`NoPostCloseLspRefLeak`):**
   - `Session.Close()` runs inside `s.closeOnce.Do(...)` (`session.go:5790`) and calls `s.releaseLanguageServerRefs()` (`session.go:5812-5844`), which acquires `s.languageServerUpdateMu`, releases `s.openProjects`, `s.openFiles`, and `s.createdPrograms` against `s.projectSession`, clears those sets, and unlocks without recording that the session is closed.
   - `handleGetCurrentLanguageServerSnapshot` (`session.go:1892-1929`) acquires `s.languageServerUpdateMu` (`session.go:1908`), calls `s.projectSession.APIUpdate(...)` (`session.go:1919`), and commits `s.openProjects` / `s.openFiles` / `s.createdPrograms` (`session.go:1924`).
   - If `handleGetCurrentLanguageServerSnapshot` enters `s.languageServerUpdateMu` after `Close()` unlocked, it opens projects, files, or synthetic programs on the live shared LSP `project.Session`. Because `s.closeOnce` already fired, `releaseLanguageServerRefs()` will never run again, leaking those open refs in the long-lived language server for the lifetime of the editor session.

2. **Source-file lease leak (`NoPostCloseLeaseLeak`):**
   - `Session.Close()` calls `s.releaseSourceFileLeases()` (`session.go:2419-2430`), draining and releasing `s.sourceFileLeases` under `s.sourceFileLeasesMu` without marking the session closed.
   - `registerSourceFileLease` (`session.go:2339-2345`), called by `handleCreateSourceFile`, `handleCreateSourceFileFromFile`, and `handleRetainSourceFile`, locks `s.sourceFileLeasesMu` and stores a newly acquired `*project.SourceFileLease` unconditionally.
   - Any in-flight call that reaches `registerSourceFileLease` after `Close()` unlocks permanently retains its lease in `s.sourceFileLeases`, keeping the underlying `*ast.SourceFile` refcount above zero in the shared `parseCache`.

3. **Batch continuation page leak (`NoPostCloseBatchPageLeak`):**
   - `Session.Close()` calls `s.batchResponsePages.Clear()` (`session.go:5808`).
   - `paginateBatchResponses` (`session.go:1349-1394`) calls `s.batchResponsePages.Store(continuationToken, ...)` (`session.go:1390`) with no closed check or lock shared with `Close()`.
   - An in-flight `handleBatchRequests` call finishing after `Close()` leaves an unreachable `batchResponsePage` entry in `s.batchResponsePages`.

4. **Additional teardown omission (non-concurrency, noted during audit):**
   - `Session.cpuProfiler` (`session.go:1448-1455`, started via `handleStartCPUProfile` and stopped via `handleStopCPUProfile`) is never stopped in `Session.Close()`. If an API client disconnects mid-profile, the Go runtime CPU profiler stays active and writes to the open file until process exit.

**Theory-informed fix (verified by `ApiSessionLifecycle_Fixed.cfg`):**
Give `Session` a monotonic lifecycle state (`open -> closed`) enforced under each table's synchronization boundary (or a single `sessionLifecycle` RWMutex/state gate acquired for admission by handlers and transitioned to `closed` under exclusive lock in `Close()`):
- Under `s.languageServerUpdateMu`: set `s.closed = true` inside `releaseLanguageServerRefs()`, and reject `handleGetCurrentLanguageServerSnapshot` (and other LSP-mutating handlers) with a closed error before calling `projectSession.APIUpdate`.
- Under `s.sourceFileLeasesMu`: reject `registerSourceFileLease` when `s.closed` is true and immediately call `lease.Release()`.
- Guard `batchResponsePages` with a mutex + `closed` flag (or reject before `Store` under the session lifecycle RWMutex), so no page can be inserted after `Close()` drains the map.
- Stop `s.cpuProfiler` in `Session.Close()` if active.

---

## Target #2: `tsc/internal/contentmapper` Host Teardown & Lease Accounting

### `ContentMapperTransformClose` (`tsc/internal/contentmapper/hostimpl.go`)

Tier 1 (`ContentMapperHost.tla`) modeled `Refresh`-vs-`Transform` handle reuse and `Close`-vs-`Acquire` orphan connections. Upstream `microsoft/TypeScript#65492` subsequently cancelled in-flight mapper requests before waiting for shutdown in `host.Close()`. Auditing `hostimpl.go` after `#65492` reveals two remaining bugs:

1. **Nil-pointer panic in `host.Transform` after `host.Close()` (`NoNilProjectDeref`):**
   - `host.Close()` (`hostimpl.go:617-641`) acquires `h.lifecycleMu.Lock()`, acquires `h.mu.Lock()`, and sets `h.conns = nil`, `h.projects = nil`, `h.projectLeases = nil` (`hostimpl.go:631-633`).
   - `host.Project(spec)` (`hostimpl.go:412-447`) checks `if h.projects == nil { return nil }` (`hostimpl.go:421-423`).
   - `host.Transform(mapper, request)` (`hostimpl.go:578-586`) calls:
     ```go
     project := h.Project(ProjectSpec{
         Mappers:         []*Mapper{mapper},
         CompilerOptions: &core.CompilerOptions{},
     })
     defer project.Close()
     return project.Transform(mapper, request)
     ```
   - `host.Transform` never checks `project == nil`. Calling `host.Transform` concurrently with or after `host.Close()` panics inside `project.Transform` (and again inside `defer project.Close()`).

2. **Duplicate `*Mapper` leak in `host.Project` (`NoLeakedConnRef`):**
   - `host.Acquire(mappers)` (`hostimpl.go:558-575`) explicitly deduplicates `mappers` by `mapper.Identity()` using a `seen` map before incrementing `entry.refs`.
   - `host.Project(spec)` (`hostimpl.go:426-445`) does not deduplicate `spec.Mappers`. For each element of `spec.Mappers`, it allocates a fresh `entryKey` in `h.projects`, increments `connEntry.refs++`, and writes `lease.entries[mapper] = entryKey` (`hostimpl.go:440`).
   - If `spec.Mappers` contains the same `*Mapper` pointer twice, the second iteration overwrites `lease.entries[mapper]`, losing the first `entryKey`. When `projectLease.release()` (`hostimpl.go:849-883`) iterates `for _, key := range p.entries`, it deletes only the second `h.projects` entry and decrements `connEntry.refs` once. The first `h.projects` entry and one `connEntry.refs` reference leak permanently, preventing the mapper subprocess from ever closing on idle release.

**Theory-informed fix (verified by `ContentMapperTransformClose_Fixed.cfg`):**
- In `host.Transform`, check `if project == nil { return Result{}, errHostClosed }` (or return a closed-host error) before deferring `project.Close()` and calling `project.Transform`.
- In `host.Project`, deduplicate `spec.Mappers` by `*Mapper` pointer (or skip `if _, exists := lease.entries[mapper]; exists { continue }`) before allocating `entryKey` and incrementing `connEntry.refs`, so the 1:1 invariant between `lease.entries`, `h.projects` insertions, and `connEntry.refs` increments holds unconditionally.

---

## Target #3: `tsc/internal/compiler` Concurrent Graph Loader (`filesParser`)

### `CompilerFilesParserDepth` (`tsc/internal/compiler/filesparser.go`)

`tsc/internal/compiler` had never been formally audited in Tier 1 or Tier 2. Its concurrent graph loader `filesParser.start()` (`filesparser.go:303-365`) runs queued parse tasks across worker goroutines, protecting per-path state (`parseTaskData`) with `data.mu`.

Upstream `microsoft/TypeScript#64632` fixed a bug where seeing a file at a lower depth did not restart subtasks, changing lines 340-352 to:

```go
currentDepth := core.IfElse(task.increaseDepth, depth+1, depth)
lowered := currentDepth < data.lowestDepth
if lowered {
    // If we're seeing this task at a lower depth than before,
    // reprocess its subtasks to ensure they are loaded.
    data.lowestDepth = currentDepth
    startSubtasks = true
    data.startedSubTasks = true
}

if task.elideOnDepth && currentDepth > w.maxDepth {
    return
}
```

Checking `task.elideOnDepth && currentDepth > w.maxDepth` *after* mutating `data.lowestDepth` and `data.startedSubTasks` breaks the loader's monotonicity invariant in two distinct ways:

1. **Schedule-dependent silent dropping of transitive imports/references (`LoadedFileStartsSubtasks`):**
   - Suppose `/node_modules/pkg/entry.js` is reachable at `currentDepth = 1` (with default `maxNodeModuleJsDepth = 0`) along two edges:
     - `/src/a.ts`: `import "pkg/entry"` -> `increaseDepth = true`, `elideOnDepth = true` (`isJsFileFromNodeModules` at `fileloader.go:467`), `currentDepth = 1`.
     - `/src/b.ts` -> `/node_modules/pkg/types.d.ts` (depth 1) -> `/// <reference path="./entry.js" />` -> `increaseDepth = false`, `elideOnDepth = false`, `currentDepth = 1`.
   - If the elided task from `a.ts` acquires `data.mu` first, `lowered = (1 < MaxInt) = true` sets `data.lowestDepth = 1` and `data.startedSubTasks = true`, then hits `if task.elideOnDepth && currentDepth > w.maxDepth { return }` without loading `entry.js` or starting its subtasks.
   - When the non-elided task from `types.d.ts` acquires `data.mu` next, `lowered = (1 < 1) = false` and `startSubtasks = false`. Inside the loop (`filesparser.go:354-368`), `taskByFileName.load(ctx, loader)` loads `entry.js` (so `entry.js` is present in the final `Program`), but `if loadSubTasks && (lowered || !taskByFileName.startedSubTasks)` is false because `loadSubTasks == false`. Every transitive `import` and `/// <reference path="..." />` inside `entry.js` is silently dropped.
   - In `TestReproCompilerFilesParserElideOnDepthDropsTransitiveImports`, simply reversing the root file list `["/src/a.ts", "/src/b.ts"]` vs `["/src/b.ts", "/src/a.ts"]` in `compiler.NewProgram(...)` makes `/node_modules/pkg/dep.d.ts` appear in one run and vanish in the other. Under multi-threaded compilation, which files are included in the program depends on goroutine scheduling.

2. **Elided arrival poisons depth-restart for already-loaded files (`LowestNonElidedDepthReached`):**
   - With `maxNodeModuleJsDepth = 1`, suppose `entry.js` is first loaded via a non-elided path at depth 3 (loading its subtask `dep.d.ts` at depth 3).
   - An elided JS import arrives at depth 2 (`2 > maxDepth = 1`). Because the elision check is below the `if lowered` block, it lowers `data.lowestDepth` from 3 to 2 and returns early without restarting `entry.js`'s subtasks at depth 2.
   - When a non-elided path subsequently arrives at depth 2, it sees `lowered = (2 < 2) = false` and does not restart `dep.d.ts` at depth 2, leaving `dep.d.ts` stuck at depth 3, which re-breaks the invariant `microsoft/TypeScript#64632` was meant to enforce.

**Theory-informed fix (verified by `CompilerFilesParserDepth_Fixed_DropsSubtasks.cfg` and `CompilerFilesParserDepth_Fixed_PoisonsRestart.cfg`):**
Move the elision guard *above* the `lowestDepth` / `startedSubTasks` mutation (and above `data.tasks` registration or before mutating `data.lowestDepth` and `data.startedSubTasks`):

```go
currentDepth := core.IfElse(task.increaseDepth, depth+1, depth)
if task.elideOnDepth && currentDepth > w.maxDepth {
    return
}

lowered := currentDepth < data.lowestDepth
if lowered {
    data.lowestDepth = currentDepth
    startSubtasks = true
    data.startedSubTasks = true
}
```

With this single ordering fix, elided arrivals become pure no-ops with respect to `data.lowestDepth` and `data.startedSubTasks`, making the resulting `Program` file set independent of goroutine arrival order and preserving the lowest-depth restart invariant.

---

## Clean-Audit Inventory (Remaining Unmodeled `tsc/internal/` Packages)

During the Tier 3 sweep, every remaining package containing synchronization primitives (`sync.Mutex`, `sync.RWMutex`, `sync.Once`, `sync.WaitGroup`, `atomic.*`, channels, goroutines) was inspected and classified as clean on concurrency safety invariants:

| Package / File | Concurrency Surface Audited | Result |
|---|---|---|
| `tsc/internal/core/workgroup.go`, `semaphore.go` | `parallelWorkGroup`, `singleThreadedWorkGroup`, `LimitedSemaphore`, `UnlimitedSemaphore` | Clean: `done` atomic guard + `sync.WaitGroup` + `defer sem.Acquire()()` preserve non-deadlocking nested `Queue`. |
| `tsc/internal/execute/incremental/` | Incremental build-info serialization, graph state | Clean: single-threaded build-info mutation per build cycle; no concurrent shared state. |
| `tsc/internal/ls/crossproject.go` | Cross-project reference/rename coordination | Clean: fan-out over immutable `project.Snapshot` views with per-worker result slots joined by `WaitGroup`. |
| `tsc/internal/checker/emitresolver.go` | `sync.Mutex` / `sync.Once` lazy caches on checker/emit resolver | Clean: mutex-guarded memoization with no re-entrant lock acquisition or teardown race. |
| `tsc/internal/project/logging/logtree.go` | `LogTree` node creation and formatting | Clean: single-owner tree construction per snapshot update; read-only afterward. |
| `tsc/internal/ast/ast.go`, `diagnostic.go` | `jsdocMu`, `ecmaLineMapMu`, `DiagnosticsCollection` | Clean: monotonic lazy initialization under per-file mutexes with no invalidation or lock nesting. |
| `tsc/internal/tsoptions/` | Extended-config cache and option parsing | Clean: immutable parsed configs; no shared mutable cache races. |
