#!/usr/bin/env bash
# PostToolUse hook on Edit/Write/NotebookEdit: record edited absolute path + ts
# to per-session edits.jsonl. Consumed by preread-edit-check.sh + statusline.
. "$(dirname "$0")/lib/common.sh"

dir="$(session_dir)"
[[ -z "$dir" ]] && exit 0

tool="$(hi_field '.tool_name')"
case "$tool" in
  Edit|Write|NotebookEdit) ;;
  *) exit 0 ;;
esac

# Different tools use different field names; try both common ones.
path="$(hi_field '.tool_input.file_path')"
[[ -z "$path" ]] && path="$(hi_field '.tool_input.notebook_path')"
[[ -z "$path" ]] && exit 0

abs="$(abspath "$path")"
ts="$(date +%s)"

line="$(jq -cn --arg p "$abs" --argjson t "$ts" '{path:$p, ts:$t}')"
atomic_append "$dir/edits.jsonl" "$line"

# Bump human-readable edit count (used by statusline).
count_file="$dir/edit-count"
n="$(cat "$count_file" 2>/dev/null || echo 0)"
n=$((n + 1))
tmp="${count_file}.tmp.$$"
printf '%s' "$n" > "$tmp" && mv "$tmp" "$count_file"

exit 0
