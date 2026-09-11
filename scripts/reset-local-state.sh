#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_GROUP="$HOME/Library/Group Containers/VUSK4B2YKQ.derrick.shared"

echo "==> Quit Derrick before resetting local state."
echo "==> This removes all local SQLite data (chats, plugins, messaging, credentials in DB)."
echo "==> Keychain plugin secrets are not removed."

removed_dbs=0
if [[ -d "$APP_GROUP" ]]; then
  while IFS= read -r db; do
    rm -f "$db" "${db}-wal" "${db}-shm"
    echo "removed $(basename "$db") at ${db%/*}"
    removed_dbs=$((removed_dbs + 1))
  done < <(find "$APP_GROUP" -name 'derrick.sqlite3' 2>/dev/null)
fi

if [[ "$removed_dbs" -eq 0 ]]; then
  echo "no derrick.sqlite3 files found under $APP_GROUP"
fi

if command -v docker >/dev/null 2>&1; then
  echo "==> Removing Derrick runtime containers"
  for filter in 'name=derrick-guest-runtime' 'name=derrick-swift-runtime' 'label=app.derrick=runtime'; do
    ids="$(docker ps -aq --filter "$filter" || true)"
    if [[ -n "$ids" ]]; then
      docker rm -f $ids >/dev/null 2>&1 || true
    fi
  done

  echo "==> Removing obsolete guest images (Python / legacy guest-runtime)"
  for image in \
    'derrick-guest-runtime:python-v1' \
    'python:3.14.7'; do
    if docker image inspect "$image" >/dev/null 2>&1; then
      docker rmi -f "$image" >/dev/null
      echo "removed image $image"
    fi
  done
else
  echo "docker not available — skipped container/image cleanup"
fi

echo
echo "Done. Reopen Derrick from $ROOT (go-workers) to recreate an empty database."
echo "Policy rules seed automatically on first UI launch."
