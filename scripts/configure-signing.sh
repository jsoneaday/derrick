#!/usr/bin/env bash
# Replaces the bundled Apple Team ID and app group across entitlements, plists, and Swift.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="${1:-$ROOT/Config/Signing.xcconfig}"

if [[ ! -f "$CONFIG" ]]; then
  echo "Missing $CONFIG" >&2
  echo "Copy Config/Signing.xcconfig.example to Config/Signing.xcconfig and set DERRICK_TEAM_ID." >&2
  exit 1
fi

TEAM_ID="$(grep '^DERRICK_TEAM_ID' "$CONFIG" | head -1 | sed 's/.*= *//' | tr -d '[:space:]')"
APP_GROUP="$(grep '^DERRICK_APP_GROUP' "$CONFIG" | head -1 | sed 's/.*= *//' | tr -d '[:space:]')"

if [[ -z "$TEAM_ID" || "$TEAM_ID" == "YOUR_TEAM_ID_HERE" ]]; then
  echo "Set DERRICK_TEAM_ID in $CONFIG" >&2
  exit 1
fi

if [[ -z "$APP_GROUP" ]]; then
  APP_GROUP="${TEAM_ID}.derrick.shared"
fi

OLD_TEAM="${DERRICK_OLD_TEAM_ID:-VUSK4B2YKQ}"
OLD_GROUP="${DERRICK_OLD_APP_GROUP:-${OLD_TEAM}.derrick.shared}"

echo "Configuring signing: team=$TEAM_ID app_group=$APP_GROUP"

replace_in() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  sed -i '' "s/${OLD_GROUP}/${APP_GROUP}/g" "$file"
  sed -i '' "s/${OLD_TEAM}/${TEAM_ID}/g" "$file"
}

replace_in "packages/Structure/Sources/AppLayerServices/AppServices/DerrickAppSupport.swift"
replace_in "packages/Structure/Sources/AppLayerServices/AppServices/ServiceIdentity.swift"
replace_in "ui/ui/ui.entitlements"
replace_in "ui/JobKeepAlive/JobKeepAlive.entitlements"
replace_in "ui/AgentService/AgentService.entitlements"
replace_in "ui/JobService/JobService.entitlements"
replace_in "ui/MCPService/MCPService.entitlements"
replace_in "ui/LaunchAgents/derrick.ui.Daemon.plist"
replace_in "ui/ui.xcodeproj/project.pbxproj"

echo "Done. Open derrick.xcworkspace and verify DEVELOPMENT_TEAM in Xcode."
