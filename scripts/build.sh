#!/usr/bin/env bash
# Build and test Derrick from the command line.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

WORKSPACE="derrick.xcworkspace"
SCHEME="${DERRICK_SCHEME:-ui}"
DESTINATION="${DERRICK_DESTINATION:-platform=macOS}"

run_tests="${1:-}"

echo "== Secret scan (history) =="
chmod +x scripts/verify-no-secrets.sh
./scripts/verify-no-secrets.sh --history

echo "== Resolve packages =="
xcodebuild -resolvePackageDependencies -workspace "$WORKSPACE" -scheme "$SCHEME" | tail -5

echo "== Build $SCHEME =="
xcodebuild build \
  -workspace "$WORKSPACE" \
  -scheme "$SCHEME" \
  -destination "$DESTINATION" \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=YES \
  | xcbeautify 2>/dev/null || xcodebuild build \
  -workspace "$WORKSPACE" \
  -scheme "$SCHEME" \
  -destination "$DESTINATION" \
  -configuration Debug

if [[ "$run_tests" == "test" ]]; then
  echo "== Test Swift packages =="
  for pkg in packages/*/Package.swift; do
    dir="$(dirname "$pkg")"
  name="$(basename "$dir")"
    echo "--- $name ---"
    (cd "$dir" && swift test) || exit 1
  done

  echo "== Test ui scheme =="
  xcodebuild test \
    -workspace "$WORKSPACE" \
    -scheme "$SCHEME" \
    -destination "$DESTINATION" \
    -configuration Debug \
    | xcbeautify 2>/dev/null || xcodebuild test \
    -workspace "$WORKSPACE" \
    -scheme "$SCHEME" \
    -destination "$DESTINATION" \
    -configuration Debug
fi

echo "Build complete."
