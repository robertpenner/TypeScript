#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SPECS_DIR="$ROOT/verification/tla/specs"
JAR="${TLA2TOOLS_JAR:-/tmp/tla2tools.jar}"
METADIR="${TLC_METADIR:-/tmp/tlc-states-tier3}"

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
  out="$(mktemp /tmp/tlc-tier3-run-XXXXXX.out)"
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
    printf "PASS [exit=%2d == %2d] %-64s %s\n" "$ec" "$expect" "$label" "$summary"
  else
    printf "FAIL [exit=%2d != %2d] %-64s %s\n" "$ec" "$expect" "$label" "$summary"
    cat "$out"
    return 1
  fi
}

echo "=== Running Tier 3 SANY + TLC verification suite ==="
run_case ApiSessionLifecycle         ApiSessionLifecycle         ApiSessionLifecycle_LspRefs.cfg                        12
run_case ApiSessionLifecycle         ApiSessionLifecycle         ApiSessionLifecycle_SourceFileLease.cfg                12
run_case ApiSessionLifecycle         ApiSessionLifecycle         ApiSessionLifecycle_BatchPages.cfg                     12
run_case ApiSessionLifecycle         ApiSessionLifecycle         ApiSessionLifecycle_Fixed.cfg                           0
run_case ContentMapperTransformClose ContentMapperTransformClose ContentMapperTransformClose_NilDeref.cfg               12
run_case ContentMapperTransformClose ContentMapperTransformClose ContentMapperTransformClose_DupMapperLeak.cfg          12
run_case ContentMapperTransformClose ContentMapperTransformClose ContentMapperTransformClose_Fixed.cfg                   0
run_case CompilerFilesParserDepth    CompilerFilesParserDepth    CompilerFilesParserDepth_DropsSubtasks.cfg             12
run_case CompilerFilesParserDepth    CompilerFilesParserDepth    CompilerFilesParserDepth_PoisonsRestart.cfg            12
run_case CompilerFilesParserDepth    CompilerFilesParserDepth    CompilerFilesParserDepth_Fixed_DropsSubtasks.cfg        0
run_case CompilerFilesParserDepth    CompilerFilesParserDepth    CompilerFilesParserDepth_Fixed_PoisonsRestart.cfg       0

echo "=== All expected Tier 3 TLC verdicts matched ==="
