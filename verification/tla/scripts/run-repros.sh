#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
REPRO_DIR="$ROOT/verification/tla/reproducers"
TSC_DIR="$ROOT/tsc"

TMP_FILES=(
  "$TSC_DIR/internal/project/dirty/tla_repro_tmp_test.go"
  "$TSC_DIR/internal/project/tla_repro_tmp_test.go"
  "$TSC_DIR/internal/lsp/lspwatcher/tla_repro_tmp_test.go"
  "$TSC_DIR/internal/fswatch/tla_repro_tmp_test.go"
  "$TSC_DIR/internal/contentmapper/tla_repro_tmp_test.go"
  "$TSC_DIR/internal/execute/tsc/tla_repro_tmp_test.go"
  "$TSC_DIR/internal/lsp/tla_repro_tmp_test.go"
  "$TSC_DIR/internal/api/tla_repro_tmp_test.go"
)

cleanup() {
  rm -f "${TMP_FILES[@]}"
}
trap cleanup EXIT

cp "$REPRO_DIR/dirty_syncmap_repro_test.go"           "$TSC_DIR/internal/project/dirty/tla_repro_tmp_test.go"
cp "$REPRO_DIR/project_repro_test.go"                 "$TSC_DIR/internal/project/tla_repro_tmp_test.go"
cp "$REPRO_DIR/lspwatcher_repro_test.go"              "$TSC_DIR/internal/lsp/lspwatcher/tla_repro_tmp_test.go"
cp "$REPRO_DIR/fswatch_debounce_repro_test.go"        "$TSC_DIR/internal/fswatch/tla_repro_tmp_test.go"
cp "$REPRO_DIR/contentmapper_repro_test.go"           "$TSC_DIR/internal/contentmapper/tla_repro_tmp_test.go"
cp "$REPRO_DIR/extendedconfig_deadlock_repro_test.go" "$TSC_DIR/internal/execute/tsc/tla_repro_tmp_test.go"
cp "$REPRO_DIR/lsp_cancel_repro_test.go"              "$TSC_DIR/internal/lsp/tla_repro_tmp_test.go"
cp "$REPRO_DIR/api_session_repro_test.go"             "$TSC_DIR/internal/api/tla_repro_tmp_test.go"

PACKAGES=(
  "./internal/project/dirty:6"
  "./internal/project:4"
  "./internal/lsp/lspwatcher:2"
  "./internal/fswatch:1"
  "./internal/contentmapper:2"
  "./internal/execute/tsc:1"
  "./internal/lsp:1"
  "./internal/api:2"
)

total_reproduced=0
total_expected=0

cd "$TSC_DIR"
for entry in "${PACKAGES[@]}"; do
  pkg="${entry%%:*}"
  expected="${entry##*:}"
  total_expected=$((total_expected + expected))

  out="$(mktemp /tmp/repro-go-XXXXXX.out)"
  set +e
  go test -race -v -timeout=15s -count=1 -run '^TestRepro' "$pkg" > "$out" 2>&1
  ec=$?
  set -e

  failed_count="$(grep -c '^--- FAIL: TestRepro' "$out" || true)"
  passed_count="$(grep -c '^--- PASS: TestRepro' "$out" || true)"
  skipped_count="$(grep -c '^--- SKIP: TestRepro' "$out" || true)"

  echo "=== $pkg (expected $expected reproduced, got FAIL=$failed_count PASS=$passed_count SKIP=$skipped_count, exit=$ec) ==="
  grep -E '=== RUN|--- FAIL:|--- PASS:|--- SKIP:|BUG REPRODUCED|WARNING: DATA RACE|build failed|panic:' "$out" || true

  if [[ "$ec" -eq 0 || "$failed_count" -ne "$expected" || "$passed_count" -ne 0 || "$skipped_count" -ne 0 ]]; then
    echo "ERROR: unexpected reproducer result for $pkg" >&2
    cat "$out" >&2
    rm -f "$out"
    exit 1
  fi
  total_reproduced=$((total_reproduced + failed_count))
  rm -f "$out"
done

echo "=== Confirmed $total_reproduced/$total_expected Go reproducers under -race -timeout=15s ==="
