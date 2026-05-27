#!/usr/bin/env bash
# =============================================================================
# docker_amd64_monolith_test.sh
#
# Integration test: build sct for linux/amd64 in Docker, download the SNOMED
# CT UK monolith via TRUD, run `sct ndjson`, and assert that the output
# contains a non-zero number of concepts.
#
# This test specifically regresses two bugs that caused zero concepts to be
# parsed on linux/amd64:
#
#   Fix 1 (parse_active_token):  src/rf2.rs — parse_active_token()
#     Robust BOM/NUL/whitespace stripping so "1" is always recognised.
#     Unit test: tests/rf2_parsing.rs::parse_concepts_active_row_with_nul_padding
#
#   Fix 2 (quoting=false):       src/rf2.rs — tsv_reader()
#     Disables csv-crate quoting so description terms that start with `"`
#     do not absorb subsequent tab-separated fields (including the active
#     column) into a single merged field value.
#     Unit test: tests/rf2_parsing.rs::parse_descriptions_with_quoted_term_does_not_misalign_fields
#
# To reproduce Fix 2's bug manually:
#   1. In src/rf2.rs, change `.quoting(false)` to `.quoting(true)` in
#      the `tsv_reader` function.
#   2. Re-run this script — the concept count will drop to 0 and the
#      assertion at the bottom will fail.
#
# Prerequisites:
#   - Docker with linux/amd64 platform support (or Rosetta / QEMU on ARM hosts)
#   - TRUD_API_KEY env var set to a valid NHS TRUD API key
#   - Optional: TRUD_EDITION (default: uk_monolith)
#
# Usage:
#   TRUD_API_KEY=<key> bash tests/docker_amd64_monolith_test.sh
#   TRUD_API_KEY=<key> TRUD_EDITION=uk_clinical bash tests/docker_amd64_monolith_test.sh
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Guard: require TRUD_API_KEY
# ---------------------------------------------------------------------------
if [[ -z "${TRUD_API_KEY:-}" ]]; then
  echo "SKIP: TRUD_API_KEY is not set. Export it to run this test." >&2
  exit 0
fi

TRUD_EDITION="${TRUD_EDITION:-uk_monolith}"
REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"

echo "=== docker_amd64_monolith_test ==="
echo "Repo:         $REPO_ROOT"
echo "TRUD edition: $TRUD_EDITION"
echo ""

# ---------------------------------------------------------------------------
# Guard: require Docker
# ---------------------------------------------------------------------------
if ! command -v docker &>/dev/null; then
  echo "SKIP: docker not found in PATH." >&2
  exit 0
fi

if ! docker info --format '{{.ServerVersion}}' &>/dev/null; then
  echo "SKIP: Docker daemon is not running." >&2
  exit 0
fi

# ---------------------------------------------------------------------------
# Write a self-contained Dockerfile for linux/amd64
# ---------------------------------------------------------------------------
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat >"$TMP_DIR/Dockerfile" <<'DOCKERFILE'
# Stage 1: build sct binary for linux/amd64
FROM --platform=linux/amd64 rust:1.82-bookworm AS builder
WORKDIR /build
COPY . .
RUN cargo build --release --bin sct

# Stage 2: minimal runtime image
FROM --platform=linux/amd64 debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    unzip \
 && rm -rf /var/lib/apt/lists/*
COPY --from=builder /build/target/release/sct /usr/local/bin/sct
DOCKERFILE

# ---------------------------------------------------------------------------
# Build the image (repo root is the Docker build context)
# ---------------------------------------------------------------------------
IMAGE_TAG="sct-amd64-test:$(date +%s)"
echo "Building Docker image $IMAGE_TAG for linux/amd64 …"
docker build \
  --platform linux/amd64 \
  --tag "$IMAGE_TAG" \
  --file "$TMP_DIR/Dockerfile" \
  "$REPO_ROOT"

# ---------------------------------------------------------------------------
# Run the test inside the container
# ---------------------------------------------------------------------------
# The container:
#   1. Downloads the latest TRUD release for the given edition
#   2. Locates the extracted RF2 Snapshot directory
#   3. Converts it to NDJSON on stdout
#   4. Counts active concept lines (each line is a JSON object with "id")
#   5. Exits non-zero if count is 0
echo ""
echo "Running sct inside linux/amd64 container …"

CONCEPT_COUNT="$(docker run --rm \
  --platform linux/amd64 \
  --env TRUD_API_KEY="$TRUD_API_KEY" \
  "$IMAGE_TAG" \
  bash -euo pipefail -c "
    # Download the latest release zip (respects SCT_DATA_HOME, defaults to ~/.local/share/sct)
    sct trud download --edition $TRUD_EDITION

    # Locate the Snapshot directory under the releases tree
    RELEASES_ROOT=\"\${SCT_DATA_HOME:-\$HOME/.local/share/sct}/releases\"
    RF2_DIR=\"\$(find \"\$RELEASES_ROOT\" -name 'Snapshot' -type d 2>/dev/null \
                | sort | tail -1)\"

    if [[ -z \"\$RF2_DIR\" ]]; then
      echo 'ERROR: No RF2 Snapshot directory found after download.' >&2
      exit 1
    fi

    echo \"RF2 dir: \$RF2_DIR\" >&2

    # Convert to NDJSON (stdout) and count concept records.
    # Each active concept is one JSON line; grep -c counts matching lines.
    sct ndjson --rf2 \"\$RF2_DIR\" --output - \
      | grep -c '\"id\"' \
      || echo 0
  ")"

echo ""
echo "Active concepts parsed: $CONCEPT_COUNT"

# ---------------------------------------------------------------------------
# Assert non-zero concept count
# ---------------------------------------------------------------------------
if [[ -z "$CONCEPT_COUNT" || "$CONCEPT_COUNT" -eq 0 ]]; then
  echo "" >&2
  echo "FAIL: parsed 0 concepts on linux/amd64 — zero-concept bug may have regressed." >&2
  echo "" >&2
  echo "Checklist:" >&2
  echo "  Fix 1: parse_active_token() in src/rf2.rs trims BOM/NUL before comparing to \"1\"." >&2
  echo "  Fix 2: tsv_reader() in src/rf2.rs has .quoting(false) — reverting to" >&2
  echo "         .quoting(true) causes description terms that start with '\"' to" >&2
  echo "         absorb subsequent fields, collapsing all active flags to 0." >&2
  docker rmi "$IMAGE_TAG" &>/dev/null || true
  exit 1
fi

echo "PASS: $CONCEPT_COUNT active concepts parsed correctly on linux/amd64."

# Clean up the test image
docker rmi "$IMAGE_TAG" &>/dev/null || true

set -euo pipefail

# ---------------------------------------------------------------------------
# Guard: require TRUD_API_KEY
# ---------------------------------------------------------------------------
if [[ -z "${TRUD_API_KEY:-}" ]]; then
  echo "SKIP: TRUD_API_KEY is not set. Export it to run this test." >&2
  exit 0
fi

TRUD_ITEM_ID="${TRUD_ITEM_ID:-101}"
REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"

echo "=== docker_amd64_monolith_test ==="
echo "Repo:      $REPO_ROOT"
echo "TRUD item: $TRUD_ITEM_ID"
echo ""

# ---------------------------------------------------------------------------
# Guard: require Docker with linux/amd64 support
# ---------------------------------------------------------------------------
if ! command -v docker &>/dev/null; then
  echo "SKIP: docker not found in PATH." >&2
  exit 0
fi

if ! docker info --format '{{.ServerVersion}}' &>/dev/null; then
  echo "SKIP: Docker daemon is not running." >&2
  exit 0
fi

# ---------------------------------------------------------------------------
# Write a self-contained Dockerfile for linux/amd64
# ---------------------------------------------------------------------------
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat >"$TMP_DIR/Dockerfile" <<'DOCKERFILE'
# Stage 1: build sct binary for linux/amd64
FROM --platform=linux/amd64 rust:1.82-bookworm AS builder
WORKDIR /build
COPY . .
RUN cargo build --release --bin sct

# Stage 2: minimal runtime image
FROM --platform=linux/amd64 debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    unzip \
 && rm -rf /var/lib/apt/lists/*
COPY --from=builder /build/target/release/sct /usr/local/bin/sct
DOCKERFILE

# ---------------------------------------------------------------------------
# Build the image (copies repo into build context)
# ---------------------------------------------------------------------------
IMAGE_TAG="sct-amd64-test:$(date +%s)"
echo "Building Docker image $IMAGE_TAG for linux/amd64 …"
docker build \
  --platform linux/amd64 \
  --tag "$IMAGE_TAG" \
  --file "$TMP_DIR/Dockerfile" \
  "$REPO_ROOT"

# ---------------------------------------------------------------------------
# Run the test inside the container
# ---------------------------------------------------------------------------
# The container:
#   1. Downloads the latest TRUD release for TRUD_ITEM_ID
#   2. Converts the RF2 release to NDJSON
#   3. Counts the active concepts
#   4. Asserts the count is > 0
echo ""
echo "Running sct inside linux/amd64 container …"

CONCEPT_COUNT="$(docker run --rm \
  --platform linux/amd64 \
  --env TRUD_API_KEY="$TRUD_API_KEY" \
  "$IMAGE_TAG" \
  bash -c "
    set -euo pipefail

    # Download the latest release for the given TRUD item
    sct trud download --item-id $TRUD_ITEM_ID --latest

    # Find the extracted RF2 directory (sct puts it under \$SCT_DATA_DIR)
    RF2_DIR=\$(find \${SCT_DATA_DIR:-\$HOME/.local/share/sct}/releases \
                   -name 'Snapshot' -type d 2>/dev/null | sort | tail -1)

    if [[ -z \"\$RF2_DIR\" ]]; then
      echo 'ERROR: No RF2 Snapshot directory found after download.' >&2
      exit 1
    fi

    echo \"RF2 dir: \$RF2_DIR\" >&2

    # Convert to NDJSON and write to stdout, then count concept lines
    sct ndjson --rf2 \"\$RF2_DIR\" --output - \
      | grep -c '\"id\"' \
      || true
  ")"

echo ""
echo "Active concepts parsed: $CONCEPT_COUNT"

# ---------------------------------------------------------------------------
# Assert
# ---------------------------------------------------------------------------
if [[ -z "$CONCEPT_COUNT" || "$CONCEPT_COUNT" -eq 0 ]]; then
  echo "FAIL: parsed 0 concepts — zero-concept bug may have regressed." >&2
  echo ""
  echo "To diagnose Fix 2 regression: check that tsv_reader() in src/rf2.rs" >&2
  echo "has '.quoting(false)' — reverting to '.quoting(true)' causes this." >&2
  docker rmi "$IMAGE_TAG" &>/dev/null || true
  exit 1
fi

echo "PASS: $CONCEPT_COUNT active concepts parsed on linux/amd64."

# Clean up image
docker rmi "$IMAGE_TAG" &>/dev/null || true
