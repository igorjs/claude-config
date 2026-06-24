#!/usr/bin/env bash
# Shared helpers for Claude Code hooks.
# Source from each hook script:  . "$(dirname "$0")/lib/common.sh"
#
# Design rules:
#   - Hooks must never break Claude Code. Any uncaught error → exit 0 silent.
#   - Stdout must be either empty or a single valid JSON object.
#   - All file writes are atomic (tmp + mv) so concurrent hooks don't tear state.
#   - Per-session state lives in ~/.claude/runtime/<session_id>/.

set -u
umask 077

RUNTIME_ROOT="${HOME}/.claude/runtime"

# Read the entire JSON payload from stdin ONCE, in the parent shell's scope.
# This is critical: hi_field is called inside $(...) substitutions which run
# in subshells. Each subshell inherits HOOK_INPUT but cannot reach back into
# the parent. If we instead read stdin lazily inside hi_field, the first
# $(...) call would consume stdin and every subsequent call would see EOF.
HOOK_INPUT="${HOOK_INPUT:-}"
if [[ -z "$HOOK_INPUT" ]] && [[ ! -t 0 ]]; then
  HOOK_INPUT="$(cat 2>/dev/null || printf '')"
fi

# Extract a JSON field. Usage: hi_field '.tool_name'
hi_field() {
  if [[ -z "$HOOK_INPUT" ]] || ! command -v jq >/dev/null 2>&1; then
    return 0
  fi
  printf '%s' "$HOOK_INPUT" | jq -r "$1 // empty" 2>/dev/null
}

# Get session id from input. Empty string if absent.
hi_session_id() {
  hi_field '.session_id'
}

# Per-session state dir. Created on demand. Empty string return if no session id.
session_dir() {
  local sid; sid="$(hi_session_id)"
  [[ -z "$sid" ]] && { printf ''; return 0; }
  local dir="${RUNTIME_ROOT}/${sid}"
  [[ -d "$dir" ]] || mkdir -p "$dir" 2>/dev/null
  printf '%s' "$dir"
}

# Resolve a path to absolute, following symlinks. Tolerates non-existent paths
# by resolving the parent dir and re-appending the basename.
abspath() {
  local p="$1"
  [[ -z "$p" ]] && return 0
  if [[ -e "$p" ]]; then
    # python is on every macOS install and handles both files + dirs cleanly.
    python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$p" 2>/dev/null \
      || printf '%s' "$p"
  else
    local d b
    d="$(dirname "$p")"; b="$(basename "$p")"
    if [[ -d "$d" ]]; then
      printf '%s/%s' "$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$d" 2>/dev/null)" "$b"
    else
      printf '%s' "$p"
    fi
  fi
}

# Atomic append. flock to serialize concurrent hook instances.
atomic_append() {
  local file="$1" line="$2"
  local dir; dir="$(dirname "$file")"
  [[ -d "$dir" ]] || mkdir -p "$dir" 2>/dev/null
  # macOS lacks flock by default; fall back to a noop subshell.
  if command -v flock >/dev/null 2>&1; then
    ( flock -x 9; printf '%s\n' "$line" >> "$file" ) 9>>"$file.lock"
  else
    printf '%s\n' "$line" >> "$file"
  fi
}

# Emit a PreToolUse additionalContext (info shown to Claude only, no block).
# Usage: emit_pre_context "PreToolUse" "message text"
emit_pre_context() {
  local event="$1" msg="$2"
  jq -cn --arg ev "$event" --arg msg "$msg" '
    { hookSpecificOutput: { hookEventName: $ev, additionalContext: $msg } }
  '
}

# Emit a PreToolUse deny decision.
# Usage: emit_pre_deny "reason text"
emit_pre_deny() {
  local reason="$1"
  jq -cn --arg r "$reason" '
    { hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: $r
    } }
  '
}

# Emit a UserPromptSubmit additionalContext (injects info Claude reads before
# generating). Same shape as PreToolUse but with hookEventName UserPromptSubmit.
emit_prompt_context() {
  local msg="$1"
  jq -cn --arg msg "$msg" '
    { hookSpecificOutput: { hookEventName: "UserPromptSubmit", additionalContext: $msg } }
  '
}

# Emit a top-level systemMessage (shown to the *user*, not Claude). Optionally
# combine with additionalContext via a second jq merge if both are needed.
emit_system_message() {
  local msg="$1"
  jq -cn --arg msg "$msg" '{ systemMessage: $msg }'
}
