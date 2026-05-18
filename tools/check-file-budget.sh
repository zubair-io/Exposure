#!/usr/bin/env bash
# File-size budget enforcer.
#
# Soft limit: 400 lines  → warning (stderr, exit 0).
# Hard limit: 600 lines  → error   (stderr, exit 1).
#
# Allowlist: tools/budget-allowlist.txt
#   - One repo-relative path per line. Lines starting with `#` are comments.
#   - Files listed here bypass both limits.
#   - GOLDEN RULE: this file can only shrink, never grow.
#     CI enforces it by diffing against the merge base.
#
# Usage:
#   tools/check-file-budget.sh                # scan all tracked source files
#   tools/check-file-budget.sh <path> [...]   # check only the given paths
#
# Applies to: *.rs *.swift *.ts *.tsx *.js *.py

set -euo pipefail

SOFT=400
HARD=600

ROOT="$(git rev-parse --show-toplevel)"
ALLOWLIST="$ROOT/tools/budget-allowlist.txt"

is_allowlisted() {
  local rel="$1"
  [[ -f "$ALLOWLIST" ]] || return 1
  # Strip comments and blanks before checking.
  grep -vE '^[[:space:]]*(#|$)' "$ALLOWLIST" | grep -Fxq "$rel"
}

is_source_file() {
  case "$1" in
    *.rs | *.swift | *.ts | *.tsx | *.js | *.py) return 0 ;;
    *) return 1 ;;
  esac
}

check_file() {
  local path="$1"
  is_source_file "$path" || return 0
  [[ -f "$path" ]] || return 0

  local rel
  rel="${path#"$ROOT/"}"

  if is_allowlisted "$rel"; then
    return 0
  fi

  local lines
  lines=$(wc -l < "$path" | tr -d ' ')

  if (( lines > HARD )); then
    printf 'ERROR: %s has %d lines (hard limit %d). Split the file or justify and allowlist.\n' \
      "$rel" "$lines" "$HARD" >&2
    return 1
  elif (( lines > SOFT )); then
    printf 'WARN:  %s has %d lines (soft limit %d).\n' "$rel" "$lines" "$SOFT" >&2
  fi
  return 0
}

failed=0

if (( $# > 0 )); then
  for f in "$@"; do
    check_file "$f" || failed=1
  done
else
  while IFS= read -r f; do
    check_file "$ROOT/$f" || failed=1
  done < <(git -C "$ROOT" ls-files -- '*.rs' '*.swift' '*.ts' '*.tsx' '*.js' '*.py')
fi

exit "$failed"
