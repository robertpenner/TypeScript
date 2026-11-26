#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SPECS_DIR="$ROOT/verification/tla/specs"
JAR="${TLA2TOOLS_JAR:-/tmp/tla2tools.jar}"
METADIR="${TLC_METADIR:-/tmp/tlc-states}"
EXHAUSTIVE=0

if [[ "${1:-}" == "--exhaustive" ]]; then
  EXHAUSTIVE=1
fi

if [[ ! -f "$JAR" ]]; then
  echo "error: tla2tools.jar not found at $JAR (set TLA2TOOLS_JAR or download official tla2tools.jar)" >&2
  exit 1
fi
mkdir -p "$METADIR"

# Expect exit codes from TLC:
#   0  = no error found (expected for clean/fixed models)
#   11 = deadlock reached (expected for deadlock models)
#   12 = safety/invariant violation (expected for buggy models)
run_case() {
  local dir="$1"
  local mod="$2"
  local cfg="$3"
  local expect="$4"
  local label="$mod/$cfg"

  local out
  out="$(mktemp /tmp/tlc-run-XXXXXX.out)"
  trap 'rm -f "$out"' RETURN

  (
    cd "$SPECS_DIR/$dir"
    java -cp "$JAR" tla2sany.SANY "${mod}.tla" > /dev/null
  )

  set +e
  (
    cd "$SPECS_DIR/$dir"
    java -XX:+UseParallelGC -cp "$JAR" tlc2.TLC -workers auto -metadir "$METADIR" -config "$cfg" "${mod}.tla" > "$out" 2>&1
  )
  local ec=$?
  set -e

  local summary
  summary="$(grep -E "Error:|Model checking completed|states generated" "$out" | head -2 | tr '\n' ' ' | sed 's/  */ /g')"
  if [[ "$ec" -eq "$expect" ]]; then
    printf "PASS [exit=%2d == %2d] %-48s %s\n" "$ec" "$expect" "$label" "$summary"
  else
    printf "FAIL [exit=%2d != %2d] %-48s %s\n" "$ec" "$expect" "$label" "$summary"
    cat "$out"
    return 1
  fi
}

echo "=== Running SANY + TLC verification suite ==="
run_case SymbolCache            SymbolCache            SymbolCache_Buggy.cfg                  12
run_case SymbolCache            SymbolCache            SymbolCache_Fixed.cfg                   0
run_case DirtySyncMap           DirtySyncMap           DirtySyncMap_NoNilClonePanic.cfg       12
run_case DirtySyncMap           DirtySyncMap           DirtySyncMap_NoDataRace.cfg            12
run_case DirtySyncMap           DirtySyncMap           DirtySyncMap_NoMutateDeleted.cfg       12
run_case DirtySyncMap           DirtySyncMap           DirtySyncMap_NoChangeIfTOCTOU.cfg      12
run_case DirtySyncMap           DirtySyncMap           DirtySyncMap_NoLostDelete.cfg          12
run_case RefCountCache          RefCountCache          RefCountCache_Strict.cfg                0
run_case RefCountCache          RefCountCache          RefCountCache_ConcRef.cfg              12
run_case RefCountCache          RefCountCache          RefCountCache_ConcRef_Overwrite.cfg    12
run_case RefCountCache          RefCountCache          RefCountCache_DisableDel.cfg           12
run_case SessionGlobalDiag      SessionGlobalDiag      SessionGlobalDiag.cfg                  12
run_case SessionGlobalDiag      SessionGlobalDiag      SessionGlobalDiag_Fixed.cfg             0
run_case LspWatcher             LspWatcher             LspWatcher_Resurrect.cfg               12
run_case LspWatcher             LspWatcher             LspWatcher_StaleTerm.cfg               12
run_case FSWatchDebounce        FSWatchDebounce        FSWatchDebounce.cfg                    12
run_case ContentMapperHost      ContentMapperHost      ContentMapperHost_Refresh.cfg          12
run_case ContentMapperHost      ContentMapperHost      ContentMapperHost_Orphan.cfg           12
run_case ExtendedConfigDeadlock ExtendedConfigDeadlock ExtendedConfigDeadlock.cfg             11
run_case LspServerCancel        LspServerCancel        LspServerCancel.cfg                    12
run_case LspServerCancel        LspServerCancel        LspServerCancel_Fixed.cfg               0
run_case ApiSessionSnapshot     ApiSessionSnapshot     ApiSessionSnapshot_UAD.cfg             12
run_case ApiSessionSnapshot     ApiSessionSnapshot     ApiSessionSnapshot_Leak.cfg            12
run_case ApiSessionSnapshot     ApiSessionSnapshot     ApiSessionSnapshot_Fixed.cfg            0

if [[ "$EXHAUSTIVE" -eq 1 ]]; then
  echo "=== Running long exhaustive negative checks ==="
  run_case RefCountCache RefCountCache RefCountCache_ConcRef_WrongDel.cfg 0
  run_case CheckerPool   CheckerPool   CheckerPool_Fast.cfg               0
fi

echo "=== All expected TLC verdicts matched ==="
