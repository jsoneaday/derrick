#!/usr/bin/env bash
# Copies canonical guest and worker-product JSON schemas from Structure into the Go worker module.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/packages/Structure/Sources/Contract/Resources/schemas"
DST="$ROOT/workers/go/internal/contract/schemas"

mkdir -p "$DST"
rsync -a --delete "$SRC/" "$DST/"
echo "Synced guest contract schemas to $DST"
