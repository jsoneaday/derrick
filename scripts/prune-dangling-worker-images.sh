#!/bin/sh
# Drop leftover derrick-worker rebuilds after Xcode builds a new tag.
# Keep the live derrick-worker tag and the Dockerfile's golang base.
# Older local builds have no OCI labels, so label-only prune misses them.
PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:${PATH}"
if ! command -v docker >/dev/null 2>&1; then
  exit 0
fi
if ! docker info >/dev/null 2>&1; then
  exit 0
fi

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
DOCKERFILE="${SCRIPT_DIR}/../docker/worker/Dockerfile"
GOLANG_KEEP=$(awk '
  /^FROM golang:/ {
    sub(/^FROM golang:/, "")
    sub(/[[:space:]].*/, "")
    print
    exit
  }
' "$DOCKERFILE")

docker image prune -f --filter "label=derrick.worker.binaries" >/dev/null 2>&1 || true

ids=$(docker images -q --filter dangling=true 2>/dev/null) || ids=""
for id in $ids; do
  [ -n "$id" ] || continue
  label=$(docker inspect --format '{{index .Config.Labels "derrick.worker.binaries"}}' "$id" 2>/dev/null || true)
  user=$(docker inspect --format '{{.Config.User}}' "$id" 2>/dev/null || true)
  if [ -n "$label" ] || [ "$user" = "worker" ]; then
    docker rmi "$id" >/dev/null 2>&1 || true
  fi
done

if [ -n "$GOLANG_KEEP" ]; then
  docker images golang --format '{{.Tag}}' 2>/dev/null | while IFS= read -r tag; do
    [ -n "$tag" ] || continue
    [ "$tag" = "<none>" ] && continue
    [ "$tag" = "$GOLANG_KEEP" ] && continue
    docker rmi "golang:${tag}" >/dev/null 2>&1 || true
  done
fi

exit 0
