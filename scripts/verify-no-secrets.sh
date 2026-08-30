#!/usr/bin/env bash
# Scans git for common secret patterns. Used in pre-commit and CI.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

MODE="${1:---staged}"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

fail() {
  echo -e "${RED}SECRET SCAN FAILED${NC}" >&2
  echo "$1" >&2
  exit 1
}

pass() {
  echo -e "${GREEN}Secret scan passed (${MODE}).${NC}"
}

ALLOWLIST_REGEX='\.env\.example$|verify-no-secrets\.sh$|opensource-plan\.md$|CONTRIBUTING\.md$|README\.md$|readme\.md$|development\.md$'

is_allowlisted() {
  local path="$1"
  echo "$path" | grep -Eq "$ALLOWLIST_REGEX"
}

scan_content() {
  local label="$1"
  local content="$2"
  local path_hint="${3:-}"

  if [[ -n "$path_hint" ]] && is_allowlisted "$path_hint"; then
    return 0
  fi

  if [[ -n "$path_hint" ]] && echo "$path_hint" | grep -Eq '(^|/)\.env(\.|$)' && ! echo "$path_hint" | grep -q '\.env\.example'; then
    fail "Blocked env file in $label: $path_hint"
  fi

  local patterns=(
    'sk-proj-[A-Za-z0-9_-]{10,}'
    'xoxb-[A-Za-z0-9-]{10,}'
    'xoxp-[A-Za-z0-9-]{10,}'
    'xoxe\.[A-Za-z0-9._-]{10,}'
    'AIza[0-9A-Za-z_-]{20,}'
    'AQ\.[A-Za-z0-9_-]{20,}'
    'BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY'
  )

  for pattern in "${patterns[@]}"; do
    if echo "$content" | grep -Eiq "$pattern"; then
      fail "Pattern '$pattern' matched in $label ${path_hint:+(path: $path_hint)}"
    fi
  done

  if echo "$content" | grep -Eiq '(^|[^A-Z_])([A-Z0-9_]*API_KEY|[A-Z0-9_]*SECRET[^=]*)=[^[:space:]#]+'; then
    local line
    line="$(echo "$content" | grep -Ei '(^|[^A-Z_])([A-Z0-9_]*API_KEY|[A-Z0-9_]*SECRET[^=]*)=[^[:space:]#]+' | head -1 || true)"
        if [[ -n "$line" ]] && ! echo "$line" | grep -Eq '(=($|your-|change-me|dotenv-|example|test|placeholder))|dev-secret|=='; then
      if [[ -z "$path_hint" ]] || ! is_allowlisted "$path_hint"; then
        fail "Possible secret assignment in $label ${path_hint:+(path: $path_hint)}: $line"
      fi
    fi
  fi
}

scan_staged() {
  local found=0
  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    found=1
    scan_content "staged file" "$(git show ":$file")" "$file"
  done < <(git diff --cached --name-only --diff-filter=ACM 2>/dev/null || true)

  if [[ "$found" -eq 0 ]]; then
    pass
    return 0
  fi
  pass
}

scan_history() {
  echo "Scanning git history…"

  if git log --all --name-only --pretty=format: | grep -E '(^|/)\.env$|(^|/)\.env\.' | grep -v '\.env\.example' | grep -q .; then
    fail "A .env file appears in git history. Rotate secrets and rewrite history."
  fi

  local needles=(
    'sk-proj-'
    'xoxb-'
    'xoxp-'
    'xoxe.xox'
    'BEGIN RSA PRIVATE KEY'
    'BEGIN OPENSSH PRIVATE KEY'
  )

  for needle in "${needles[@]}"; do
    if git log --all -S"$needle" --oneline -- . ':(exclude)scripts/verify-no-secrets.sh' | head -1 | grep -q .; then
      local hits
      hits="$(git log --all -S"$needle" --oneline -- . ':(exclude)scripts/verify-no-secrets.sh' | head -3)"
      fail "History contains '$needle'. Review and rotate if real:\n$hits"
    fi
  done

  pass
}

case "$MODE" in
  --staged) scan_staged ;;
  --history) scan_history ;;
  *)
    echo "Usage: $0 [--staged|--history]" >&2
    exit 2
    ;;
esac
