#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Igor Santos
# SPDX-License-Identifier: MIT
# PreCompact hook: fires when Claude Code is about to auto-compact the
# conversation. By the time this fires, the cheap-cache window is gone and the
# next turn will reload a lossy summary. Strong signal to wrap up + restart.
#
# Emits only a user-facing systemMessage. PreCompact has no additionalContext
# channel (the hook output schema defines no PreCompact variant), so the hook
# can't inject guidance to Claude here; the systemMessage prompts the user.
. "$(dirname "$0")/lib/common.sh"

trigger="$(hi_field '.trigger')"
sid="$(hi_session_id)"
ts="$(date '+%Y-%m-%d %H:%M:%S')"

# Log to a flat file for later review.
log="${RUNTIME_ROOT}/compactions.log"
printf '%s\tsession=%s\ttrigger=%s\n' "$ts" "$sid" "${trigger:-unknown}" >> "$log" 2>/dev/null

user_msg="⚠ Context compaction triggered (${trigger:-auto}). After this point, every turn replays a lossy summary instead of the original transcript, so the cache savings are gone. Strongly consider: finish the current step, ask me to wrap up (a session handoff), then /clear for a fresh session."

# PreCompact output supports only top-level fields, so emit just systemMessage.
jq -cn --arg um "$user_msg" '{ systemMessage: $um }'
exit 0
