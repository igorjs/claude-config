#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Igor Santos
# SPDX-License-Identifier: MIT
# PreToolUse: EnterPlanMode — restore Opus + max thinking for planning phase.
# Writes settings.json so the next session also starts correctly.
. "$(dirname "$0")/lib/common.sh"

SETTINGS="$HOME/.claude/settings.json"
TMP="$(mktemp /tmp/claude-settings-XXXXXX.json)"

if jq '.model = "opus" | .effortLevel = "xhigh"' "$SETTINGS" > "$TMP" 2>/dev/null; then
  mv "$TMP" "$SETTINGS"
else
  rm -f "$TMP"
fi

emit_system_message "Plan mode → Opus + max thinking. Run /model opus if the model indicator hasn't updated yet."
exit 0
