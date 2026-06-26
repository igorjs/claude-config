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

  # ── Auto-learn queue ──
  # If this session did substantive work in a repo, drop a per-repo flag so the
  # next session there nudges a /learn-project run. This writes a flag file
  # only; nothing is written to memory here. Disable with AUTO_LEARN_NUDGE=0;
  # tune the threshold with AUTO_LEARN_MIN_EDITS (default 5).
  if [[ "${AUTO_LEARN_NUDGE:-1}" != "0" ]]; then
    _root="$(git --no-optional-locks rev-parse --show-toplevel 2>/dev/null)"
    _edits="$(cat "$dir/edit-count" 2>/dev/null || printf 0)"; _edits="${_edits//[^0-9]/}"; _edits="${_edits:-0}"
    if [[ -n "$_root" && "$_edits" -ge "${AUTO_LEARN_MIN_EDITS:-5}" ]]; then
      _qdir="$RUNTIME_ROOT/to-learn"; mkdir -p "$_qdir" 2>/dev/null
      _slug="$(printf '%s' "$_root" | sed 's/[^A-Za-z0-9_.-]/_/g')"
      _ts="$(date +%s 2>/dev/null || printf 0)"
      jq -cn --arg root "$_root" --argjson edits "$_edits" --arg sid "$(hi_session_id)" --argjson ts "$_ts" \
        '{repo_root:$root, edits:$edits, session_id:$sid, ts:$ts}' > "$_qdir/$_slug.json.tmp" 2>/dev/null \
        && mv -f "$_qdir/$_slug.json.tmp" "$_qdir/$_slug.json" 2>/dev/null
    fi
  fi
fi

exit 0
