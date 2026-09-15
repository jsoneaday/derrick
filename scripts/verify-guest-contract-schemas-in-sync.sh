#!/usr/bin/env bash
# Fails CI when canonical Structure schemas (guest + worker product) drift from the Go worker copy.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/packages/Structure/Sources/Contract/Resources/schemas"
DST="$ROOT/workers/go/internal/contract/schemas"

if ! diff -qr "$SRC" "$DST" >/dev/null; then
  echo "Guest contract schemas are out of sync. Run: scripts/sync-guest-contract-schemas.sh" >&2
  diff -qr "$SRC" "$DST" >&2 || true
  exit 1
fi

echo "Guest contract schemas are in sync."
