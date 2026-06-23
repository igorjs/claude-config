#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Igor Santos
# SPDX-License-Identifier: MIT
# Stop / SessionEnd hook: mark this session as having ended cleanly.
# Used by session-init.sh on the NEXT session start to detect crashes
# (orphaned sessions with no clean-exit marker).
. "$(dirname "$0")/lib/common.sh"

dir="$(session_dir)"
[[ -z "$dir" ]] && exit 0

# Stop fires after every assistant turn (not session-end). We still want to
# refresh the timestamp on every turn so a stale crash detection only fires
# if the session is genuinely abandoned, not just paused.
date +%s > "$dir/last-clean-ts" 2>/dev/null

# SessionEnd is the real "this session is done" signal. The reason field
# distinguishes graceful (clear/resume/logout/prompt_input_exit) from crash.
reason="$(hi_field '.reason')"
if [[ -n "$reason" && "$reason" != "other" ]]; then
  : > "$dir/clean-exit" 2>/dev/null
  printf '%s\n' "$reason" > "$dir/clean-exit"

  # SessionEnd only (Stop has no .reason): last-chance memory flush reminder.
  jq -cn --arg msg "If you learned any durable facts this session not yet in ~/.claude/memory/, persist them now per the Memory section of the system prompt." '
    { hookSpecificOutput: { hookEventName: "SessionEnd", additionalContext: $msg } }' 2>/dev/null
fi

exit 0
