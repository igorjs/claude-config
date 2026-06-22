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

# Crash detection only runs on fresh startup.
[[ "$source" != "startup" ]] && exit 0

current_sid="$(hi_session_id)"
now="$(date +%s)"

# Window: only flag sessions that were active in the last 24h. Older orphans
# are stale and almost certainly not what the user wants to recover.
WINDOW_SECONDS=$((24 * 3600))

# Find the most recent OTHER session dir (excluding current) that lacks a
# clean-exit marker and was active within the window.
orphan_sid=""
orphan_age=""
orphan_cwd=""

# Iterate sessions newest-first by mtime of any state file (start-ts is the
# proxy — every initialized session has one).
while IFS= read -r sdir; do
  sid="$(basename "$sdir")"
  [[ "$sid" == "$current_sid" ]] && continue
  [[ -d "$sdir" ]] || continue
  [[ -f "$sdir/start-ts" ]] || continue
  # Skip cleanly-ended sessions.
  [[ -f "$sdir/clean-exit" ]] && continue
  # Need a recent activity timestamp to consider this a real "in progress" orphan.
  last_ts=$(cat "$sdir/last-clean-ts" 2>/dev/null || cat "$sdir/start-ts" 2>/dev/null || echo 0)
  age=$((now - last_ts))
  [[ "$age" -gt "$WINDOW_SECONDS" ]] && continue
  # Only need the most recent one.
  orphan_sid="$sid"
  orphan_age="$age"
  break
done < <(
  # Enumerate session dirs by mtime descending. Avoids ls -t because user
  # shells often set CLICOLOR_FORCE which would inject ANSI escapes into
  # the filenames downstream.
  find "${RUNTIME_ROOT}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null |
    while IFS= read -r d; do
      ts=$(stat -f %m "$d" 2>/dev/null || stat -c %Y "$d" 2>/dev/null || echo 0)
      printf '%s\t%s\n' "$ts" "$d"
    done | sort -rn | cut -f2-
)

[[ -z "$orphan_sid" ]] && exit 0

# Compose a human age string.
if   [[ "$orphan_age" -lt 60   ]]; then age_str="${orphan_age}s ago"
elif [[ "$orphan_age" -lt 3600 ]]; then age_str="$((orphan_age / 60))m ago"
else                                    age_str="$((orphan_age / 3600))h ago"
fi

user_msg="⚠ Previous session ${orphan_sid:0:8}… last seen ${age_str} did not end cleanly (possible crash). Recover with: claude --resume ${orphan_sid} --fork-session   (the --fork-session flag re-initializes settings/plugins/hooks from current settings.json.)"

claude_msg="On startup I detected an orphaned previous session (id ${orphan_sid}, last active ${age_str}) — no clean-exit marker. The user has been informed and given the recovery command. If they ask about recovering, the session transcript should be at ~/.claude/projects/<project-slug>/${orphan_sid}/ — read it to understand what was in progress."

jq -cn --arg um "$user_msg" --arg cm "$claude_msg" '
  { systemMessage: $um,
    hookSpecificOutput: { hookEventName: "SessionStart", additionalContext: $cm } }
'
exit 0
