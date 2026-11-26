#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
REPRO_DIR="$ROOT/verification/tla/reproducers"
TSC_DIR="$ROOT/tsc"

TMP_FILES=(
  "$TSC_DIR/internal/api/tla_repro_tier3_tmp_test.go"
  "$TSC_DIR/internal/contentmapper/tla_repro_tier3_tmp_test.go"
  "$TSC_DIR/internal/compiler/tla_repro_tier3_tmp_test.go"
)

cleanup() {
  rm -f "${TMP_FILES[@]}"
}
trap cleanup EXIT

cp "$REPRO_DIR/api_session_tier3_repro_test.go"          "$TSC_DIR/internal/api/tla_repro_tier3_tmp_test.go"
cp "$REPRO_DIR/contentmapper_tier3_repro_test.go"        "$TSC_DIR/internal/contentmapper/tla_repro_tier3_tmp_test.go"
cp "$REPRO_DIR/compiler_filesparser_tier3_repro_test.go" "$TSC_DIR/internal/compiler/tla_repro_tier3_tmp_test.go"

# Format: "<pkg>|<test-regex>|<mode>"
#   mode=fail  -> expects --- FAIL: TestRepro...
#   mode=crash -> expects goroutine panic/SIGSEGV or race crash (non-zero exit)
CASES=(
  "./internal/api|^TestReproApiSessionLspSnapshotAfterCloseLeaksRefs$|fail"
  "./internal/api|^TestReproApiSessionSourceFileLeaseAfterCloseLeak$|fail"
  "./internal/api|^TestReproApiSessionBatchResponsePagesAfterCloseLeak$|fail"
  "./internal/contentmapper|^TestReproContentMapperHostTransformAfterCloseNilDerefPanic$|crash"
  "./internal/contentmapper|^TestReproContentMapperProjectDuplicateMapperLeaksConnRef$|fail"
  "./internal/compiler|^TestReproCompilerFilesParserElideOnDepthDropsTransitiveImports$|fail"
  "./internal/compiler|^TestReproCompilerFilesParserElideOnDepthPoisonsDepthRestart$|fail"
)

total_reproduced=0
total_expected=${#CASES[@]}

cd "$TSC_DIR"
for entry in "${CASES[@]}"; do
  IFS='|' read -r pkg regex mode <<< "$entry"

  out="$(mktemp /tmp/repro-tier3-go-XXXXXX.out)"
  set +e
  go test -race -v -timeout=30s -count=1 -run "$regex" "$pkg" > "$out" 2>&1
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

echo "=== Confirmed $total_reproduced/$total_expected Tier 3 Go reproducers under -race ==="
