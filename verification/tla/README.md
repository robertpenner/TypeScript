# TLA+ Formal Verification of TypeScript 7 Concurrency (`tsc/internal`)

This directory captures a collection of verified concurrency and state-machine defects in TypeScript 7's Go implementation (`tsc/internal`), pinned against upstream commit `e0fce98` (`main`).

Each finding is backed by:
1. A compact TLA+ specification checked with official `tla2tools.jar` (TLC2 2.19).
2. A minimal TLC counterexample trace (3 to 16 states).
3. A deterministic Go reproducer verified under `go test -race -timeout=15s` against unmodified `tsc/internal` code.

## Documents

- [`FINDINGS.md`](./FINDINGS.md): Component-by-component catalog of all 17 verified defects across 9 components (7 packages), plus 2 verified-safe negative results (`checkerPool` and balanced `RefCountCache.Deref`).
- [`ANALYSIS.md`](./ANALYSIS.md): Severity and reachability triage, four recurring structural root-cause patterns, comparison against `project.checkerPool`, and architectural fix principles.

## Layout

- `specs/<Component>/`: TLA+ modules (`.tla`) and TLC configurations (`.cfg`).
- `reproducers/`: Standalone Go `_test.go` reproducers mapped onto their target `tsc/internal` packages by `scripts/run-repros.sh` so `tsc/` stays unmodified on this branch.
- `scripts/run-tlc.sh`: Runs SANY and TLC across all fast specs (stores TLC state files in `/tmp/tlc-states`).
- `scripts/run-repros.sh`: Temporarily copies each reproducer into its target package (with an `EXIT` trap), runs `go test -race -timeout=15s -count=1 -run '^TestRepro'`, verifies every defect reproduces, and restores a clean `tsc/` tree.

## Quickstart

Prerequisites: Java 17+ (`java`), Go 1.25+ (`go`), and official `tla2tools.jar` at `/tmp/tla2tools.jar` (or set `TLA2TOOLS_JAR`).

```sh
# 1. Run SANY + TLC on all bug-finding specs and verified-safe models (~10s)
./verification/tla/scripts/run-tlc.sh

# Include long exhaustive negative checks (RefCountCache WrongDel ~42M states, CheckerPool ~14M+ states)
./verification/tla/scripts/run-tlc.sh --exhaustive

# 2. Run all 19 Go reproducer tests (covering 17 defects) under the Go race detector (~1s after Go build cache warms)
./verification/tla/scripts/run-repros.sh
```
