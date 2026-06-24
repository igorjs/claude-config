#!/usr/bin/env bash
# PreCompact hook: fires when Claude Code is about to auto-compact the
# conversation. By the time this fires, the cheap-cache window is gone and the
# next turn will reload a lossy summary. Strong signal to wrap up + restart.
#
# Emits:
#   - systemMessage  (visible to the *user* in the terminal)
#   - additionalContext (visible to *Claude* in the next turn)
. "$(dirname "$0")/lib/common.sh"

trigger="$(hi_field '.trigger')"
sid="$(hi_session_id)"
ts="$(date '+%Y-%m-%d %H:%M:%S')"

# Log to a flat file for later review.
log="${RUNTIME_ROOT}/compactions.log"
printf '%s\tsession=%s\ttrigger=%s\n' "$ts" "$sid" "${trigger:-unknown}" >> "$log" 2>/dev/null

user_msg="⚠ Context compaction triggered (${trigger:-auto}). After this point, every turn replays a lossy summary instead of the original transcript — cache savings are gone. Strongly consider: finish the current step, /wrap-up, then /clear for a fresh session."

claude_msg="The conversation just hit auto-compaction. From here on, your view of earlier turns is a summary, not the original messages. Concretely:
  1. Finish the immediate sub-task you're on (do not abandon mid-edit).
  2. Then proactively suggest the user run /wrap-up (or commit + /clear) before starting any new task.
  3. Don't expand scope. Don't re-explore — work from what you remember now.
  4. If you learned any durable facts this session not yet in ~/.claude/memory/, persist them now per the Memory section of the system prompt before they are summarized away.
This is the cheapest moment to end the session cleanly."

# Combine both into one JSON object.
jq -cn --arg um "$user_msg" --arg cm "$claude_msg" '
  { systemMessage: $um,
    hookSpecificOutput: { hookEventName: "PreCompact", additionalContext: $cm } }
'
exit 0
