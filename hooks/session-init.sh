#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Igor Santos
# SPDX-License-Identifier: MIT
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

# Accumulate any SessionStart output; emit a single payload at the end.
system_message=""
extra_context=""

if [[ "$source" == "resume" && -n "$current_hash" ]]; then
  prev_hash="$(cat "$hash_file" 2>/dev/null)"
  if [[ -n "$prev_hash" && "$prev_hash" != "$current_hash" ]]; then
    system_message="⚠ Claude config (settings.json + hooks) has drifted since this session was created. Plugins, output style, model default, and new hooks will NOT take effect on this resumed session — they're frozen at the original startup snapshot. To apply current config: exit and run \`cc fresh\` (or \`claude\` without --resume)."
    extra_context="The user resumed this session, but the config hash has changed since session creation. The harness has the OLD settings loaded. If the user asks about why a recent settings change isn't showing up, point them to 'cc fresh' or starting a new \`claude\` invocation."
  fi
fi

# Always refresh the stored hash on startup (the new baseline going forward).
[[ -n "$current_hash" && "$source" == "startup" ]] && \
  printf '%s' "$current_hash" > "$hash_file" 2>/dev/null

# ── Per-project memory ──
# Project memory lives in <repo-root>/.claude/memory/, kept out of git via
# .git/info/exclude. Inject the index lines only; fact bodies are read on
# demand. No-op outside a git repo or when the repo has no project memory.
_repo_root="$(git --no-optional-locks rev-parse --show-toplevel 2>/dev/null)"
_mem_index="$_repo_root/.claude/memory/MEMORY.md"
if [[ -n "$_repo_root" && -f "$_mem_index" ]]; then
  _mem_body="$(head -c 16000 "$_mem_index" 2>/dev/null)"
  if [[ -n "$_mem_body" ]]; then
    _mem_ctx="Project memory for this repo ($(basename "$_repo_root")), stored locally at $_repo_root/.claude/memory/. These facts apply only in this repo; read the referenced fact files on demand. Index:
$_mem_body"
    if [[ -n "$extra_context" ]]; then
      extra_context="$extra_context

$_mem_ctx"
    else
      extra_context="$_mem_ctx"
    fi
  fi
fi

# ── Auto-learn nudge ──
# If the previous session in this repo did substantive work, session-clean-exit
# left a flag in ~/.claude/runtime/to-learn/. Surface a one-time nudge to run
# /learn-project, then consume the flag. Stale flags are pruned so the dir
# doesn't grow. Disable with AUTO_LEARN_NUDGE=0.
if [[ "${AUTO_LEARN_NUDGE:-1}" != "0" && -n "$_repo_root" ]]; then
  _qdir="$RUNTIME_ROOT/to-learn"
  [[ -d "$_qdir" ]] && find "$_qdir" -name '*.json' -type f -mtime "+${AUTO_LEARN_MAX_AGE_DAYS:-14}" -delete 2>/dev/null
  _learn_slug="$(printf '%s' "$_repo_root" | sed 's/[^A-Za-z0-9_.-]/_/g')"
  _learn_flag="$_qdir/$_learn_slug.json"
  if [[ -f "$_learn_flag" ]]; then
    _learn_edits="$(jq -r '.edits // 0' "$_learn_flag" 2>/dev/null)"
    _learn_nudge="A previous session in this repo made ${_learn_edits:-some} edits, so project memory may be stale. Consider running /learn-project to refresh it, or /learn-project --stage to queue candidate facts for review."
    if [[ -n "$extra_context" ]]; then
      extra_context="$extra_context

$_learn_nudge"
    else
      extra_context="$_learn_nudge"
    fi
    rm -f "$_learn_flag" 2>/dev/null
  fi
fi

# Emit a single SessionStart payload if there is anything to say.
if [[ -n "$system_message" || -n "$extra_context" ]]; then
  jq -cn --arg um "$system_message" --arg cm "$extra_context" '
    ( (if $um != "" then { systemMessage: $um } else {} end)
      + (if $cm != "" then { hookSpecificOutput: { hookEventName: "SessionStart", additionalContext: $cm } } else {} end) )
  '
fi

# NOTE: crash-recovery warning removed. `ccd` restores the most recent session
# per directory, so the "did not end cleanly" warning was redundant, and it
# could not distinguish a live session (no clean-exit yet, but running) from a
# real crash, so it kept flagging healthy sessions. Recover any session with
# `ccd` in its directory, or `claude --resume <id>` for a specific one.
exit 0
