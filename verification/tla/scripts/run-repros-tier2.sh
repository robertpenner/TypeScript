#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
REPRO_DIR="$ROOT/verification/tla/reproducers"
TSC_DIR="$ROOT/tsc"

TMP_FILES=(
  "$TSC_DIR/internal/fswatch/tla_repro_tmp_test.go"
  "$TSC_DIR/internal/execute/build/tla_repro_tmp_test.go"
  "$TSC_DIR/internal/project/tla_repro_ownercache_tmp_test.go"
  "$TSC_DIR/internal/project/tla_repro_session_tmp_test.go"
)

cleanup() {
  rm -f "${TMP_FILES[@]}"
}
trap cleanup EXIT

cp "$REPRO_DIR/fswatch_lifecycle_repro_test.go"        "$TSC_DIR/internal/fswatch/tla_repro_tmp_test.go"
cp "$REPRO_DIR/build_orchestrator_watch_repro_test.go" "$TSC_DIR/internal/execute/build/tla_repro_tmp_test.go"
cp "$REPRO_DIR/ownercache_release_repro_test.go"       "$TSC_DIR/internal/project/tla_repro_ownercache_tmp_test.go"
cp "$REPRO_DIR/session_project_repro_test.go"          "$TSC_DIR/internal/project/tla_repro_session_tmp_test.go"

# Format: "<pkg>|<test-regex>|<mode>"
#   mode=fail  -> expects --- FAIL: TestRepro...
#   mode=crash -> expects goroutine panic/SIGSEGV or race crash (non-zero exit)
CASES=(
  "./internal/fswatch|^TestReproFSWatchLifecycleDeadDebounceAndOrphanedWatch$|fail"
  "./internal/execute/build|^TestReproBuildWatchUnresolvedProjectDoubleClosePanic$|crash"
  "./internal/execute/build|^TestReproBuildWatchDownstreamUnboundedDuplicationAndStaleRetention$|fail"
  "./internal/project|^TestReproOwnerCacheReleaseBlindDeleteCausesAddOwnerPanic$|fail"
  "./internal/project|^TestReproSessionWatchLeakedClientWatchOnAddRemove$|fail"
  "./internal/project|^TestReproSessionWatchConcurrentAcquireFailStrandsLiveProject$|fail"
  "./internal/project|^TestReproSessionWatchFailedThenRemovedStealsLiveWatch$|fail"
  "./internal/project|^TestReproSessionProgramDiagOutOfOrderStaleOverwrite$|fail"
  "./internal/project|^TestReproSessionDidChangeInferredOptionsDataRace$|crash"
  "./internal/project|^TestReproSessionDidChangeInferredOptionsNilSnapshotPanic$|fail"
)

total_reproduced=0
total_expected=${#CASES[@]}

cd "$TSC_DIR"
for entry in "${CASES[@]}"; do
  IFS='|' read -r pkg regex mode <<< "$entry"

  out="$(mktemp /tmp/repro-tier2-go-XXXXXX.out)"
  set +e
  go test -race -v -timeout=20s -count=1 -run "$regex" "$pkg" > "$out" 2>&1
  ec=$?
  set -e

  echo "=== $pkg ($regex, mode=$mode, exit=$ec) ==="
  grep -E '=== RUN|--- FAIL:|--- PASS:|BUG REPRODUCED|WARNING: DATA RACE|panic:|build failed' "$out" | head -12 || true

  if [[ "$mode" == "fail" ]]; then
    failed_count="$(grep -c '^--- FAIL: TestRepro' "$out" || true)"
    passed_count="$(grep -c '^--- PASS: TestRepro' "$out" || true)"
    if [[ "$ec" -eq 0 || "$failed_count" -ne 1 || "$passed_count" -ne 0 ]]; then
      echo "ERROR: expected fail reproduction for $pkg $regex" >&2
      cat "$out" >&2
      rm -f "$out"
      exit 1
    fi
  else
    if [[ "$ec" -eq 0 ]] || ! grep -qE 'panic:|WARNING: DATA RACE' "$out"; then
      echo "ERROR: expected crash/race reproduction for $pkg $regex" >&2
      cat "$out" >&2
      rm -f "$out"
      exit 1
    fi
  fi

  total_reproduced=$((total_reproduced + 1))
  rm -f "$out"
done

echo "=== Confirmed $total_reproduced/$total_expected Tier 2 Go reproducers under -race ==="
