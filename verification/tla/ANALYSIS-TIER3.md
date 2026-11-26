# Architectural Analysis: Tier 3 Findings and Cross-Tier Synthesis (Tiers 1 through 3)

Branch: `tla-tier2-investigation` (pinned against `microsoft/TypeScript` `main` at `e0fce98`)
Companion reports: [`FINDINGS.md`](./FINDINGS.md) (Tier 1), [`ANALYSIS.md`](./ANALYSIS.md) (Tier 1), [`FINDINGS-TIER2.md`](./FINDINGS-TIER2.md) (Tier 2), [`ANALYSIS-TIER2.md`](./ANALYSIS-TIER2.md) (Tier 2), [`FINDINGS-TIER3.md`](./FINDINGS-TIER3.md) (Tier 3), [`ROADMAP.md`](./ROADMAP.md) (roadmap)
Remediation tracking: `robertpenner/TypeScript#1` (Tier 1 epic), `robertpenner/TypeScript#10` (Tier 2 epic), `robertpenner/TypeScript#20` (Tier 3 epic: `#21`, `#22`, `#23`)

## Summary

Phase 3 completed the synchronization audit of every remaining package in `tsc/internal` (`api`, `contentmapper`, `compiler`, `core`, `execute/incremental`, `ls`, `checker`, `project/logging`, `ast`, `tsoptions`). Model checking with official `tla2tools.jar` (TLC2 2.19) verified **7 novel safety invariant violations across 3 specifications**, backed by **7 deterministic `go test -race` reproducers** and **4 exhaustive fixed-model TLC proofs (exit 0)**. Seven additional audited packages (`core`, `execute/incremental`, `ls`, `checker`, `project/logging`, `ast`, `tsoptions`) passed without safety violations.

Rolling up Phases 1, 2, and 3 yields **47 verified concurrency and state-machine defects** across **24 component TLA+ specifications** (23 with verified violations and 1 verified-safe `CheckerPool`, plus the initial `SymbolCache` prototype) and **47 confirmed `go test -race` reproducers**:

| Phase | Audited Specs | Verified Defects | Confirmed Go `-race` Reproducers | Trigger Go `-race` Detector | Race-Free Protocol / Ordering / Lifecycle Bugs | Tracking Epic |
|---|---|---|---|---|---|---|
| Tier 1 | 10 (9 buggy + `CheckerPool`) | 17 | 19 | 1 (`dirty.SyncMap.Locked`) | 16 | `robertpenner/TypeScript#1` (`#2`–`#5`) |
| Tier 2 | 11 | 23 | 21 | 3 (`BuildOrchestratorWatch`, `SessionInferredOptions`, `LspProgressLocale`) | 20 | `robertpenner/TypeScript#10` (`#11`–`#19`) |
| Tier 3 | 3 | 7 | 7 | 0 | 7 | `robertpenner/TypeScript#20` (`#21`–`#23`) |
| **Total** | **24** | **47** | **47** | **4 (8.5%)** | **43 (91.5%)** | **3 epics, 16 tickets** |

All 7 Tier 3 defects are completely invisible to Go's `-race` detector: every one uses mutexes or `sync.Map` cleanly at the memory-model level while violating a higher-level safety invariant (monotonic teardown, map-to-refcount bijection, or order-invariant parallel graph discovery). Across the full 47-bug corpus, **43 of 47 (91.5%)** are data-race-free protocol, lifecycle, framing, or ordering defects.

Five of the 7 Tier 3 defects reinforce two families already established in [`ANALYSIS-TIER2.md`](./ANALYSIS-TIER2.md) (Family 3: implicit lifecycle across separate tables/nullable pointers; Family 7: non-canonical ownership accounting). The remaining two defects in `compiler.filesParser` introduce **Family 8**: speculative shared-state mutation before an early-return filter/elision guard, which breaks commutativity and monotonicity of concurrent graph traversal.

---

## 1. Tier 3 Triage and Defect Summary

| Ticket | Component & File | Findings (Count) | Failure Impact | Fixed TLC Proof (Exit 0) | Upstream Novelty |
|---|---|---|---|---|---|
| `robertpenner/TypeScript#23` | `compiler.filesParser` (`tsc/internal/compiler/filesparser.go`) | `LoadedFileStartsSubtasks`, `LowestNonElidedDepthReached` (2) | Schedule-dependent silent dropping of transitive imports/references from `node_modules` JS files; broken depth-restart on shallower arrivals | 2/2 configs (`14` / `56` states) | Novel (missed in `microsoft/TypeScript#64632`) |
| `robertpenner/TypeScript#21` | `contentmapper.host` (`tsc/internal/contentmapper/hostimpl.go`) | `NoNilProjectDeref`, `NoLeakedConnRef` (2) | Unrecovered nil-pointer dereference panic in `host.Transform` after `host.Close()`; permanent `h.projects` and `connEntry.refs` leak on duplicate `*Mapper` in `spec.Mappers` | 1/1 config (`40` states) | Novel (still present after `microsoft/TypeScript#65492`) |
| `robertpenner/TypeScript#22` | `api.Session` (`tsc/internal/api/session.go`) | `NoPostCloseLspRefLeak`, `NoPostCloseLeaseLeak`, `NoPostCloseBatchPageLeak` (3) + `cpuProfiler` audit note | Permanent leak of LSP open projects/files/synthetic programs, `parseCache` `*ast.SourceFile` refcounts, and `batchResponsePages` after `Close()`; unstopped CPU profiler on client disconnect | 1/1 config (`360` states) | Novel (distinct from Tier 1 `robertpenner/TypeScript#3` `s.snapshots`) |

---

## 2. Mapping Tier 3 Into the Root-Cause Taxonomy (Families 1 through 8)

### Existing Families Confirmed in Tier 3

1. **Family 3 (Implicit lifecycle encoded across nullable fields and separate tables, 4 Tier 3 findings):**
   - `api.Session` (`NoPostCloseLspRefLeak`, `NoPostCloseLeaseLeak`, `NoPostCloseBatchPageLeak`, plus unstopped `s.cpuProfiler`): `Session.Close()` runs behind `s.closeOnce`, draining four independent resource tables under separate locks (`s.snapshots` in Tier 1 `#3`, plus `s.languageServerUpdateMu`, `s.sourceFileLeasesMu`, and `s.batchResponsePages` in Tier 3 `#22`). None of the three Tier 3 tables records a monotonic `closed` bit checked under the same lock that guards insertion, so any handler that runs concurrently with or after `Close()` inserts resources that can never be released because `s.closeOnce` already fired.
   - `contentmapper.host` (`NoNilProjectDeref`): `host.Close()` sets `h.projects = nil`, causing `host.Project(spec)` to return `nil`, while `host.Transform` assumes a non-nil `*projectLease` and panics on `project.Transform(...)` and `defer project.Close()`.
   - **Theory-informed fix:** Replace piecemeal nullable pointers and one-shot drain calls with a single monotonic closed transition enforced at every insertion site under the table's own lock (and a `nil` / `ErrClosed` return check in `host.Transform`).
2. **Family 7 (Denormalized / non-canonical ownership accounting, 1 Tier 3 finding):**
   - `contentmapper.host` (`NoLeakedConnRef`): `host.Project` inserts one `h.projects[entryKey]` entry and increments `connEntry.refs++` for each element of `spec.Mappers`, while indexing `lease.entries` by `*Mapper` pointer (`lease.entries[mapper] = entryKey`). Passing the same `*Mapper` twice overwrites `lease.entries[mapper]` with the second key, breaking the 1:1 bijection between `lease.entries`, `h.projects`, and `connEntry.refs`. When `projectLease.release()` runs, the overwritten `entryKey` is orphaned in `h.projects` and `connEntry.refs` stays permanently at 1.
   - **In-repo safe contrast:** `host.Acquire` (`tsc/internal/contentmapper/hostimpl.go:558-575`) in the exact same file already deduplicates `mappers` with a `seen` map before incrementing refs. Applying the same deduplication to `host.Project` restores the exact 1:1 bijection (proven in `ContentMapperTransformClose_Fixed.cfg`, 40 states, 0 errors).

### New Family 8: Speculative Shared-State Mutation Before Guard / Filter Rejection in Concurrent Graph Traversal

- **Findings:** `CompilerFilesParserDepth` (`LoadedFileStartsSubtasks`, `LowestNonElidedDepthReached`; `robertpenner/TypeScript#23`).
- **What goes wrong:** `filesParser.start()` (`tsc/internal/compiler/filesparser.go:340-352`) updates shared per-file traversal state (`data.lowestDepth` and `data.startedSubTasks`) *before* evaluating the early-return depth-elision predicate `if task.elideOnDepth && currentDepth > w.maxDepth { return }`.
  - When an elided `node_modules` JS arrival reaches `entry.js` at depth 1 before a non-elided arrival at depth 1 (for example `/// <reference path="./entry.js" />` from a `.d.ts` file), the elided goroutine writes `data.lowestDepth = 1` and returns without loading or spawning subtasks. The subsequent non-elided goroutine sees `lowered = (1 < 1) = false`, loads `entry.js` into `Program`, and skips `w.start(..., subTasks, ...)`, silently dropping all transitive imports and references.
  - When a non-elided arrival first reaches a file at depth 3 (`maxDepth = 1`), an elided arrival at depth 2 lowers `data.lowestDepth` from 3 to 2 and returns early without restarting subtasks; a later non-elided arrival at depth 2 sees `lowered = false` and leaves subtasks permanently un-restarted at depth 3.
- **Why this is a distinct class:** Every previous bug in Tiers 1 and 2 involved locks, channels, wire framing, or lifecycle teardown. Here, `data.mu` serializes access to `data` properly and there is no data race or panic. The defect is a **broken algebraic law of parallel graph search**: parallel reachability and shortest-depth discovery are schedule-independent if and only if each arrival updates the monotone lattice (`lowestDepth`, `startedSubTasks`) **only for arrivals that actually pass the filter and perform work**. Mutating the monotone watermark for a rejected/elided arrival destroys commutativity: `Apply(Elided(d)) ; Apply(NonElided(d)) != Apply(NonElided(d)) ; Apply(Elided(d))`.
- **Theory-informed fix (proven in TLC):** Evaluate `if task.elideOnDepth && currentDepth > w.maxDepth { return }` **before** touching `data.lowestDepth`, `data.startedSubTasks`, or the loaded-file table (specifically before mutating `data` in `filesParser.start()`). Elided arrivals then become pure no-ops with respect to shared traversal state, restoring commutativity and guaranteeing both `LoadedFileStartsSubtasks` and `LowestNonElidedDepthReached` across all goroutine schedules (`CompilerFilesParserDepth_Fixed_DropsSubtasks.cfg` and `CompilerFilesParserDepth_Fixed_PoisonsRestart.cfg`, 0 errors).

---

## 3. Cross-Tier Root-Cause Distribution (All 47 Verified Defects)

| # | Root-Cause Family | Tier 1 | Tier 2 | Tier 3 | Total | Core Formal Principle |
|---|---|---|---|---|---|---|
| 1 | Unordered edge-triggered side-effect fan-out | 1 | 4 | 0 | **5** | Level-triggered convergence over a monotone desired-state lattice |
| 2 | Split lock domains, ABA deletion, and indeterminate-commit RPCs | 10 | 7 | 0 | **17** | Linearizability, CAS/ABA identity validation, two-phase RPC intent state |
| 3 | Implicit lifecycle across nullable fields, separate tables, and one-shot channels | 6 | 5 | 4 | **15** | Explicit monotonic phase machine checked at centralized boundaries |
| 4 | Half-duplex wire multiplexing without correlation IDs or cancel framing | 0 | 2 | 0 | **2** | Unique correlation IDs / single demux reader / pre-write cancel check |
| 5 | Mutable in-place reuse of affine one-shot channels and task graphs | 0 | 2 | 0 | **2** | Separate persistent caches from fresh per-cycle coordination state |
| 6 | Non-transactional cancellation committing partial state as clean | 0 | 1 | 0 | **1** | Propagate `ctx.Err()` at worker join and reject cancelled commits |
| 7 | Denormalized / view-dependent keys or broken 1:1 ownership accounting | 0 | 2 | 1 | **3** | Canonical invariant keys, partition-scoped ownership, input deduplication |
| 8 | Speculative shared-state mutation before filter/elision guard | 0 | 0 | 2 | **2** | Guard-before-mutate to preserve commutativity and monotonicity of parallel search |
| **Total** | | **17** | **23** | **7** | **47** | |

---

## 4. Why 7 Tier 3 Packages Audited Clean

Completing the repository-wide census confirmed that seven packages with real concurrency primitives had no reachable safety violations:

- **`tsc/internal/core/` (`workgroup.go`, `bfs.go`):** `WorkGroup` runs a bounded worker pool with `sync.WaitGroup` and `recover` panic propagation; `ParallelBFS` uses atomic frontier exchange per level without cross-level mutation.
- **`tsc/internal/execute/incremental/`:** Read-mostly build-info cache with immutable value records.
- **`tsc/internal/ls/` (outside `autoimport`):** Stateless request helpers operating over immutable `Program` snapshots.
- **`tsc/internal/checker/`:** Single-threaded per-`Checker` execution (serialized by `project.checkerPool`, already verified safe across 26.9M+ TLC states in Tier 1).
- **`tsc/internal/project/logging/`:** Append-only mutex-guarded log writers with no cross-lock callbacks.
- **`tsc/internal/ast/` and `tsc/internal/tsoptions/`:** `sync.Once` lazy initialization of pure derived values with no mutable teardown paths.

The dividing line across all 47 bugs and all clean packages is consistent: packages that either hold immutable snapshots, confine mutable state to one lock with pure callbacks, or use `sync.Once` on pure derivations stayed bug-free. Defects concentrated wherever code crossed two locks, tore down shared registries across separate tables, multiplexed RPCs without state machines, or mutated shared traversal watermarks before checking early-exit guards.
