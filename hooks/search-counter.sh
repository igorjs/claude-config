#!/usr/bin/env bash
# PreToolUse hook on Grep/Glob/Read: track exploration breadth. Nudge Claude
# toward the Explore subagent when the main session is fanning out across
# many files.
#
# Counting rules:
#   - Grep/Glob: each call = 1.
#   - Read: only the *first* time a unique absolute path is read this session
#     counts. Subsequent reads of the same file don't (they're often offset
#     follow-ups, which we want to encourage, not discourage).
#
# Emits additionalContext at thresholds 4, 8, 12. Past 12 it stays silent so
# it doesn't become spam — by then Claude has either delegated or chosen not to.
. "$(dirname "$0")/lib/common.sh"

dir="$(session_dir)"
[[ -z "$dir" ]] && exit 0

tool="$(hi_field '.tool_name')"

count_file="$dir/search-count"
seen_file="$dir/seen-reads"
tool_count_file="$dir/tool-count"

# Bump global tool counter (statusline reads this).
tn="$(cat "$tool_count_file" 2>/dev/null || echo 0)"
tn=$((tn + 1))
printf '%s' "$tn" > "${tool_count_file}.tmp.$$" && mv "${tool_count_file}.tmp.$$" "$tool_count_file"

bump_search=false
case "$tool" in
  Grep|Glob) bump_search=true ;;
  Read)
    path="$(hi_field '.tool_input.file_path')"
    if [[ -n "$path" ]]; then
      abs="$(abspath "$path")"
      # Check if this path is already in seen-reads.
      if ! grep -qxF "$abs" "$seen_file" 2>/dev/null; then
        printf '%s\n' "$abs" >> "$seen_file"
        bump_search=true
      fi
    fi
    ;;
esac

[[ "$bump_search" != true ]] && exit 0

n="$(cat "$count_file" 2>/dev/null || echo 0)"
n=$((n + 1))
printf '%s' "$n" > "${count_file}.tmp.$$" && mv "${count_file}.tmp.$$" "$count_file"

# Threshold nudges. Single, escalating message at each step.
case "$n" in
  4)
    emit_pre_context "PreToolUse" \
"Search/read count for this session has reached ${n}. If your remaining searches will fan across more than a couple more files, dispatch the Explore subagent now (Task tool, subagent_type: \"Explore\") — its full search context stays in its window and only a digest comes back to yours. Keeps main context lean for the actual work."
    ;;
  8)
    emit_pre_context "PreToolUse" \
"Search/read count is now ${n}. You're deep in exploration — strongly prefer dispatching the Explore subagent for the rest of this discovery work. Each additional Read here costs main-context tokens you won't recover."
    ;;
  12)
    emit_pre_context "PreToolUse" \
"Search/read count is ${n}. Main context is now carrying significant exploration weight. Wrap up this discovery and continue in an Explore subagent, or summarize findings to yourself and consider /clear once the task is settled."
    ;;
esac

exit 0
