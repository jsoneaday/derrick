#!/usr/bin/env bash
# Fast CI: Swift package unit tests only (no ui xcodebuild, no MCPServer harness compile).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

UNIT_TEST_PACKAGES=(
  AgentRuntime
  AppEvents
  DBRepository
  DerrickBackend
  DockerRunnerXPC
  EgressProxy
  FileExtractor
  Lib
  LLMAgentClient
  MCPClient
  MCPToolCatalog
  MemorySystem
  Plugin
  PolicyRuntime
  PolicyUserInteraction
  ServiceEnsureUp
  Structure
  WebCrawler
)

for name in "${UNIT_TEST_PACKAGES[@]}"; do
  dir="packages/$name"
  pkg="$dir/Package.swift"
  if [[ ! -f "$pkg" ]]; then
    echo "Skipping $name (no Package.swift)"
    continue
  fi
  if ! grep -q 'testTarget' "$pkg"; then
    echo "Skipping $name (no test target)"
    continue
  fi
  echo "== Testing $dir =="
  (cd "$dir" && swift test)
done
