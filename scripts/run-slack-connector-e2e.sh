#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$ROOT/ui/ui/Resources/.env"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi
# Never touch the Derrick app database; E2E uses its own SQLite directory.
export E2E_DATABASE_DIR="${E2E_DATABASE_DIR:-${TMPDIR:-/tmp}/derrick-slack-e2e}"
SWIFT="${SWIFT:-/Applications/Xcode-beta.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift}"
cd "$ROOT/packages/MCPServer"
exec "$SWIFT" run -c release SlackConnectorE2EHarness "$@"
