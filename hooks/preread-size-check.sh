#!/usr/bin/env bash
# PreToolUse hook on Read: deny a full-file Read when the file is large and no
# offset/limit was provided. Pushes Claude toward Grep-first, then targeted Read.
#
# Allowlist a small set of config files commonly needed in full.
. "$(dirname "$0")/lib/common.sh"

path="$(hi_field '.tool_input.file_path')"
[[ -z "$path" ]] && exit 0
[[ -f "$path" ]] || exit 0

# Honour explicit offset/limit — caller already knows what they're doing.
offset="$(hi_field '.tool_input.offset')"
limit="$(hi_field '.tool_input.limit')"
[[ -n "$offset" || -n "$limit" ]] && exit 0

# Allowlist common small config / docs files that are usually needed whole.
base="$(basename "$path")"
case "$base" in
  package.json|tsconfig.json|tsconfig.*.json|pyproject.toml|go.mod|go.sum|\
  Cargo.toml|Cargo.lock|Gemfile|Gemfile.lock|requirements.txt|\
  CLAUDE.md|README.md|README|CHANGELOG.md|LICENSE|\
  .gitignore|.dockerignore|Dockerfile|docker-compose.yml|docker-compose.yaml|\
  Makefile|.env.example|settings.json|settings.local.json)
    exit 0 ;;
esac

# Get line count + byte size. Use BSD-compatible stat invocation.
lines="$(wc -l < "$path" 2>/dev/null | tr -d ' ')"
bytes="$(stat -f %z "$path" 2>/dev/null || stat -c %s "$path" 2>/dev/null || echo 0)"

LINE_LIMIT=1000
BYTE_LIMIT=204800   # 200 KB

# Files at or below either threshold pass.
if [[ "${lines:-0}" -le $LINE_LIMIT && "${bytes:-0}" -le $BYTE_LIMIT ]]; then
  exit 0
fi

reason="$(cat <<MSG
This file is ${lines} lines / ${bytes} bytes — too large to Read in full.

Cheaper approaches:
  1. Grep the file first to find the relevant line ranges.
  2. Re-call Read with offset:<line> and limit:<rows> for the section you need.
  3. If you really need the whole file (e.g. a small minified bundle), re-issue
     with explicit offset:0, limit:9999 to override this guard.

Why this matters: full Reads on large files burn input tokens that almost never
pay back — most callers only use 10-20% of the content.
MSG
)"

emit_pre_deny "$reason"
exit 0
