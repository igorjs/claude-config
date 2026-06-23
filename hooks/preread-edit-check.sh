#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Igor Santos
# SPDX-License-Identifier: MIT
# PreToolUse hook on Read: if the target was edited by this session within the
# last N minutes, inject a system reminder so Claude doesn't waste tokens
# re-reading content already in context.
#
# Emits additionalContext (info-only). Never blocks.
. "$(dirname "$0")/lib/common.sh"

dir="$(session_dir)"
[[ -z "$dir" ]] && exit 0

edits="$dir/edits.jsonl"
[[ -s "$edits" ]] || exit 0

path="$(hi_field '.tool_input.file_path')"
[[ -z "$path" ]] && exit 0

abs="$(abspath "$path")"
now="$(date +%s)"
window=1800  # 30 minutes

# Find the most recent edit of this exact path within the window.
match_ts="$(jq -r --arg p "$abs" --argjson now "$now" --argjson w "$window" '
  select(.path == $p) | select($now - .ts < $w) | .ts
' "$edits" 2>/dev/null | tail -1)"

[[ -z "$match_ts" ]] && exit 0

# Compose a human-friendly age string.
delta=$((now - match_ts))
if   [[ $delta -lt 60   ]]; then ago="${delta}s ago"
elif [[ $delta -lt 3600 ]]; then ago="$((delta / 60))m ago"
else                              ago="$((delta / 3600))h ago"
fi

msg="You edited this file ${ago} via Edit/Write. Your context already reflects the post-edit state — re-reading it now is wasted tokens unless you suspect external modifications. Skip the Read and proceed."

emit_pre_context "PreToolUse" "$msg"
exit 0
