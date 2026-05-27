#!/usr/bin/env bash
# =============================================================================
# run_regression_evidence.sh
#
# Produces copy-pasteable evidence for the PR review by running tests inside a
# linux/amd64 Docker container.
#
# You asked for 4 blocks (2 pass + 2 fail):
#   1) Fix 2 quoting test passes with fixes enabled
#   2) Fix 1 NUL-padding test passes with fixes enabled
#   3) Fix 2 quoting test FAILS with quoting fix disabled
#   4) Fix 1 NUL-padding test FAILS with active-token fix disabled
#
# Optional: if TRUD_API_KEY is set, we also run an end-to-end `sct trud download`
# + `sct ndjson` on uk_monolith (slow, but closest to Northflank).
#
# Usage:
#   bash tests/run_regression_evidence.sh
#   TRUD_API_KEY=... bash tests/run_regression_evidence.sh   # adds monolith run
# =============================================================================
set -euo pipefail

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"

TEST_QUOTING="parse_descriptions_with_quoted_term_does_not_misalign_fields"
TEST_NUL="parse_concepts_active_row_with_nul_padding"

if ! command -v docker &>/dev/null; then
  echo "ERROR: docker not found in PATH." >&2; exit 1
fi
if ! docker info --format '{{.ServerVersion}}' &>/dev/null; then
  echo "ERROR: Docker daemon is not running." >&2; exit 1
fi

IMAGE_TAG="sct-regression-evidence:$(date +%s)"

echo "Building linux/amd64 image (first run will take a few minutes)..."
echo ""

docker build \
  --platform linux/amd64 \
  --tag "$IMAGE_TAG" \
  --file - \
  "$REPO_ROOT" <<'DOCKERFILE'
FROM rust:latest
WORKDIR /src
COPY . .
RUN cargo fetch
DOCKERFILE

run_test_round() {
  local title="$1"
  local patch_script="${2:-}"
  local test_filter="$3"

  echo ""
  echo "========================================================================"
  echo "  $title"
  echo "========================================================================"
  echo ""

  local patch_cmd="echo '  [no patch applied]'"
  if [[ -n "$patch_script" ]]; then
    patch_cmd="python3 /src/$patch_script"
  fi

  docker run --rm \
    --platform linux/amd64 \
    "$IMAGE_TAG" \
    bash -euo pipefail -c "
cd /src
$patch_cmd

echo ''
echo '--- src/rf2.rs lines 183-210 (reader + parse_active_token) ---'
sed -n '183,210p' src/rf2.rs

echo ''
echo '--- cargo test --test rf2_parsing $test_filter ---'
set +e
cargo test --test rf2_parsing $test_filter 2>&1
status=\$?
set -e
echo ''
echo "exit code: \$status"
exit 0
"

  echo ""
}

# 1) Pass: quoting regression test
run_test_round \
  "1/4 PASS: quoting(false) regression test (fixes enabled)" \
  "" \
  "$TEST_QUOTING"

# 2) Pass: NUL-padding active-token regression test
run_test_round \
  "2/4 PASS: NUL-padding active-token regression test (fixes enabled)" \
  "" \
  "$TEST_NUL"

# 3) Fail: disable Fix 2 and rerun quoting test
run_test_round \
  "3/4 FAIL: disable Fix 2 (.quoting(true)), rerun quoting regression test" \
  "tests/patch_disable_fix2.py" \
  "$TEST_QUOTING"

# 4) Fail: disable Fix 1 and rerun NUL-padding test
run_test_round \
  "4/4 FAIL: disable Fix 1 (strict raw == \"1\"), rerun NUL-padding test" \
  "tests/patch_disable_fix1.py" \
  "$TEST_NUL"

# Optional: monolith end-to-end (requires TRUD_API_KEY)
if [[ -n "${TRUD_API_KEY:-}" ]]; then
  echo ""
  echo "========================================================================"
  echo "  OPTIONAL: TRUD uk_monolith end-to-end (TRUD_API_KEY set)"
  echo "========================================================================"
  echo ""

  echo "-- monolith round A: fixes enabled (expect: PASS) --"
  docker run --rm \
    --platform linux/amd64 \
    --env TRUD_API_KEY="$TRUD_API_KEY" \
    "$IMAGE_TAG" \
    bash -euo pipefail -c "
cd /src

echo '--- build sct (release) ---'
cargo build --release --bin sct

mkdir -p /tmp/sct/releases /tmp/sct/data

echo ''
echo '--- sct trud download (uk_monolith) ---'
./target/release/sct trud download --edition uk_monolith --output-dir /tmp/sct/releases --data-dir /tmp/sct/data

ZIP=\"\$(ls -1 /tmp/sct/releases/*.zip 2>/dev/null | sort | tail -1)\"
if [[ -z \"\$ZIP\" ]]; then
  echo 'ERROR: no zip found under /tmp/sct/releases' >&2
  exit 1
fi

echo ''
echo \"--- sct ndjson from zip: \$ZIP ---\"
set +e
./target/release/sct ndjson --rf2 \"\$ZIP\" --output /tmp/out.ndjson 2>&1 | tail -n 40
status=\$?
set -e

echo ''
echo \"ndjson exit code: \$status\"\n"

  echo ""
  echo "-- monolith round B: disable Fix 2 (.quoting(true)) + rebuild (expect: FAIL) --"
  docker run --rm \
    --platform linux/amd64 \
    --env TRUD_API_KEY="$TRUD_API_KEY" \
    "$IMAGE_TAG" \
    bash -euo pipefail -c "
cd /src
python3 /src/tests/patch_disable_fix2.py

echo ''
echo '--- rebuild sct (release) with Fix 2 disabled ---'
cargo build --release --bin sct

mkdir -p /tmp/sct/releases /tmp/sct/data

echo ''
echo '--- sct trud download (uk_monolith) ---'
./target/release/sct trud download --edition uk_monolith --output-dir /tmp/sct/releases --data-dir /tmp/sct/data

ZIP=\"\$(ls -1 /tmp/sct/releases/*.zip 2>/dev/null | sort | tail -1)\"
if [[ -z \"\$ZIP\" ]]; then
  echo 'ERROR: no zip found under /tmp/sct/releases' >&2
  exit 1
fi

echo ''
echo \"--- sct ndjson from zip (Fix 2 disabled): \$ZIP ---\"
set +e
./target/release/sct ndjson --rf2 \"\$ZIP\" --output /tmp/out.ndjson 2>&1 | tail -n 60
status=\$?
set -e

echo ''
echo \"ndjson exit code: \$status\"\n"

else
  echo "(TRUD_API_KEY not set; skipping optional monolith end-to-end.)"
fi

# Cleanup
docker rmi "$IMAGE_TAG" &>/dev/null || true

echo "Done. Copy the output above into the PR comment."
