#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SPECS_DIR="$ROOT/verification/tla/specs"
JAR="${TLA2TOOLS_JAR:-/tmp/tla2tools.jar}"
METADIR="${TLC_METADIR:-/tmp/tlc-states-tier2}"

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
  out="$(mktemp /tmp/tlc-tier2-run-XXXXXX.out)"
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
    printf "PASS [exit=%2d == %2d] %-54s %s\n" "$ec" "$expect" "$label" "$summary"
  else
    printf "FAIL [exit=%2d != %2d] %-54s %s\n" "$ec" "$expect" "$label" "$summary"
    cat "$out"
    return 1
  fi
}

echo "=== Running Tier 2 SANY + TLC verification suite ==="
run_case FSWatchLifecycle       FSWatchLifecycle       FSWatchLifecycle_NoDebounce.cfg             12
run_case FSWatchLifecycle       FSWatchLifecycle       FSWatchLifecycle_NoOSSub.cfg                12
run_case FSWatchLifecycle       FSWatchLifecycle       FSWatchLifecycle_Orphaned.cfg               12
run_case BuildOrchestratorWatch BuildOrchestratorWatch BuildOrchestratorWatch_DoubleClose.cfg      12
run_case BuildOrchestratorWatch BuildOrchestratorWatch BuildOrchestratorWatch_StaleDownstream.cfg  12
run_case OwnerCacheRelease      OwnerCacheRelease      OwnerCacheRelease.cfg                       12
run_case SessionWatchProtocol   SessionWatchProtocol   SessionWatchProtocol_AddRemove.cfg          12
run_case SessionWatchProtocol   SessionWatchProtocol   SessionWatchProtocol_ConcurrentFail.cfg     12
run_case SessionWatchProtocol   SessionWatchProtocol   SessionWatchProtocol_FailThenRemove.cfg     12
run_case SessionProgramDiag     SessionProgramDiag     SessionProgramDiag.cfg                      12
run_case SessionInferredOptions SessionInferredOptions SessionInferredOptions_LostOverlay.cfg      12
run_case SessionInferredOptions SessionInferredOptions SessionInferredOptions_NilClone.cfg         12
run_case LspProgressLocale      LspProgressLocale      LspProgressLocaleRace.cfg                   12
run_case LspProgressLocale      LspProgressLocale      LspProgressLocaleStuck.cfg                  12
run_case LspServerLifecycle     LspServerLifecycle     LspServerLifecyclePreInit.cfg               12
run_case LspServerLifecycle     LspServerLifecycle     LspServerLifecyclePostShutdown.cfg          12
run_case LspServerLifecycle     LspServerLifecycle     LspServerLifecycleDupInit.cfg               12
run_case LspWatchRegistry       LspWatchRegistry       LspWatchRegistryTimeout.cfg                 12
run_case LspWatchRegistry       LspWatchRegistry       LspWatchRegistryDupUnwatch.cfg              12
run_case IpcSyncConn            IpcSyncConn            IpcSyncConn_NotificationSwap.cfg            12
run_case IpcSyncConn            IpcSyncConn            IpcSyncConn_CancelOrphan.cfg                12
run_case AutoImportRegistry     AutoImportRegistry     AutoImportRegistry_CancelCleanCommit.cfg    12
run_case AutoImportRegistry     AutoImportRegistry     AutoImportRegistry_EntrypointClobber.cfg    12

echo "=== All expected Tier 2 TLC verdicts matched ==="
