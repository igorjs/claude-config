#!/usr/bin/env bash
# SessionStart hook:
#   1. Prepare per-session runtime dir + zero counters.
#   2. On fresh startup (source=startup), detect orphaned previous sessions
#      that may have crashed and surface a recovery hint to the user.
. "$(dirname "$0")/lib/common.sh"

dir="$(session_dir)"
if [[ -n "$dir" ]]; then
  : > "$dir/search-count" 2>/dev/null
  : > "$dir/tool-count" 2>/dev/null
  : > "$dir/edit-count" 2>/dev/null
  : > "$dir/edits.jsonl" 2>/dev/null
  : > "$dir/seen-reads" 2>/dev/null
  date +%s > "$dir/start-ts" 2>/dev/null
fi

# Clear the statusline PR/CI cache for the current repo+branch so the first
# render of each session fetches fresh data rather than reusing stale cache.
_sl_cache="${STATUSLINE_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/statusline}"
_sl_branch=$(git --no-optional-locks rev-parse --abbrev-ref HEAD 2>/dev/null)
if [[ -n "$_sl_branch" && "$_sl_branch" != "HEAD" ]]; then
  _sl_slug=$(printf '%s' "${PWD}::${_sl_branch}" | sed 's/[^A-Za-z0-9_.-]/_/g')
  rm -f "${_sl_cache}/pr-${_sl_slug}.json" "${_sl_cache}/ci-${_sl_slug}.json"
fi

source="$(hi_field '.source')"

# ── Config hash: warn on resume if settings have drifted ──
# Hash = sha256 of settings.json + every hook script. Stored in the session
# dir on first startup; on resume we recompute and compare. Divergence means
# the resumed session is running on the OLD config (plugins, hooks, model
# default, output style frozen at original session start).
config_hash() {
  {
    cat "$HOME/.claude/settings.json" 2>/dev/null
    find "$HOME/.claude/hooks" -name '*.sh' -type f -print0 2>/dev/null |
      sort -z | xargs -0 cat 2>/dev/null
  } | shasum -a 256 2>/dev/null | cut -c1-16
}

hash_file="$dir/config-hash"
current_hash="$(config_hash)"

if [[ "$source" == "resume" && -n "$current_hash" ]]; then
  prev_hash="$(cat "$hash_file" 2>/dev/null)"
  if [[ -n "$prev_hash" && "$prev_hash" != "$current_hash" ]]; then
    user_msg="⚠ Claude config (settings.json + hooks) has drifted since this session was created. Plugins, output style, model default, and new hooks will NOT take effect on this resumed session — they're frozen at the original startup snapshot. To apply current config: exit and run \`cc fresh\` (or \`claude\` without --resume)."
    claude_msg="The user resumed this session, but the config hash has changed since session creation. The harness has the OLD settings loaded. If the user asks about why a recent settings change isn't showing up, point them to 'cc fresh' or starting a new \`claude\` invocation."
    jq -cn --arg um "$user_msg" --arg cm "$claude_msg" '
      { systemMessage: $um,
        hookSpecificOutput: { hookEventName: "SessionStart", additionalContext: $cm } }
    '
    # Continue — don't return, so we can still log the hash for the next compare.
  fi
fi

# Always refresh the stored hash on startup (the new baseline going forward).
[[ -n "$current_hash" && "$source" == "startup" ]] && \
  printf '%s' "$current_hash" > "$hash_file" 2>/dev/null

# NOTE: crash-recovery warning removed. `ccd` restores the most recent session
# per directory, so the "did not end cleanly" warning was redundant, and it
# could not distinguish a live session (no clean-exit yet, but running) from a
# real crash, so it kept flagging healthy sessions. Recover any session with
# `ccd` in its directory, or `claude --resume <id>` for a specific one.
exit 0
