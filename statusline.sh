#!/usr/bin/env bash
set +e   # Never let an error silently kill the status line
# ╔══════════════════════════════════════════════════════════════════════════════════════════════╗
# ║  Claude Code Status Line                                                                     ║
# ║                                                                                              ║
# ║  Three-line status bar rendered below the Claude Code prompt.                                ║
# ║  Receives session data as JSON on stdin; outputs ANSI-colored text.                          ║
# ║                                                                                              ║
# ║  Line 1 (LEFT):  ~/path branch [$]                                                           ║
# ║  Line 1 (RIGHT): PR #42 CI  JIRA @author APPROVED by name (1h ago)                           ║
# ║  Line 2:         Model: Sonnet 4.6 (max) │ Ctx: 72% → 18% to compact │ Up 18m                ║
# ║  Line 3:         Tokens In: 48k │ Cache 86% │ Cost: $0.42 ($1.42/min) │ Rate 5h: 23% 7d: 41% ║
# ║                                                                                              ║
# ║  Configure by setting STATUSLINE_* env vars or editing the feature                           ║
# ║  flags section below.                                                                        ║
# ╚══════════════════════════════════════════════════════════════════════════════════════════════╝

# ┌──────────────────────────────────────────────────────────────────────────────┐
# │  Feature Flags                                                              │
# │                                                                             │
# │  Toggle individual sections on/off. Set to "true" to enable, anything       │
# │  else to disable. Override via environment: STATUSLINE_SHOW_GIT=false       │
# └──────────────────────────────────────────────────────────────────────────────┘

SHOW_GIT="${STATUSLINE_SHOW_GIT:-true}"             # Git branch + dirty indicator
SHOW_PR="${STATUSLINE_SHOW_PR:-true}"                # GitHub PR number, author, review status
SHOW_CI="${STATUSLINE_SHOW_CI:-true}"                # CI status rollup (workspace projects only)
SHOW_MODEL="${STATUSLINE_SHOW_MODEL:-true}"          # Model name + effort
SHOW_CONTEXT="${STATUSLINE_SHOW_CONTEXT:-true}"      # Context window % (with compaction proximity arrow)
SHOW_SESSION_AGE="${STATUSLINE_SHOW_SESSION_AGE:-true}"   # "Up 18m" since session start (needs hooks)
SHOW_TOKENS_IN="${STATUSLINE_SHOW_TOKENS_IN:-true}"  # Total input tokens (out is implied by cost)
SHOW_CACHE_RATIO="${STATUSLINE_SHOW_CACHE_RATIO:-true}"   # Cache hit ratio % (replaces raw write/read)
SHOW_ACTIVITY="${STATUSLINE_SHOW_ACTIVITY:-false}"   # Tools / Edits counters (from hook state)
SHOW_RATE_LIMITS="${STATUSLINE_SHOW_RATE_LIMITS:-true}" # 5h / 7d quota usage %

# Removed sections (no SHOW_* flag because they were dropped during the
# enhance/simplify pass — they were low-signal noise):
#   - Node version    (rarely actionable)
#   - Window size     (rarely changes)
#   - Duration        (cost is the better signal)
#   - Lines +/-       (Edits counter covers this)
#   - Raw cache W/R   (replaced by SHOW_CACHE_RATIO)
#   - Tokens Out      (cost subsumes; SHOW_TOKENS_IN covers input side)

PR_TIMEOUT="${STATUSLINE_PR_TIMEOUT:-3}"             # Seconds before gh pr view is killed
PR_CACHE_TTL="${STATUSLINE_PR_CACHE_TTL:-60}"        # Seconds before cached PR data is refetched
CI_TIMEOUT="${STATUSLINE_CI_TIMEOUT:-3}"             # Seconds before standalone CI fetch is killed
CI_CACHE_TTL="${STATUSLINE_CI_CACHE_TTL:-60}"        # Seconds before cached CI data is refetched

# Cache directory. Defaults to $XDG_CACHE_HOME/statusline or ~/.cache/statusline.
# Created with 0700 perms (owner-only) on first run so cached PR bodies stay private.
CACHE_DIR="${STATUSLINE_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/statusline}"

# ┌──────────────────────────────────────────────────────────────────────────────┐
# │  Colour Palette — Catppuccin Mocha                                          │
# │                                                                             │
# │  Uses true-colour (24-bit) ANSI escapes. Requires a terminal that           │
# │  supports \033[38;2;R;G;Bm sequences (iTerm2, Kitty, Alacritty, etc).      │
# └──────────────────────────────────────────────────────────────────────────────┘

GREEN='\033[38;2;166;227;161m'    # #a6e3a1 — paths, values, approved
RED='\033[38;2;243;139;168m'      # #f38ba8 — git branch, changes requested, closed
YELLOW='\033[38;2;249;226;175m'   # #f9e2af — git status brackets, review required
ORANGE='\033[38;2;250;179;135m'   # #fab387 — model name, cost, PR number
WHITE='\033[38;2;205;214;244m'    # #cdd6f4 — connectors ("via"), PR author
TEAL='\033[38;2;148;226;213m'     # #94e2d5 — cache statistics
MAUVE='\033[38;2;203;166;247m'    # #cba6f7 — merged PRs
DIM='\033[38;2;127;132;156m'      # #7f849c — labels, separators
RESET='\033[0m'

SEP="${DIM} │ ${RESET}"           # Separator used between line 2 segments

# ┌──────────────────────────────────────────────────────────────────────────────┐
# │  Utility Functions                                                           │
# └──────────────────────────────────────────────────────────────────────────────┘

# Colour a rate-limit percentage: green < 50%, yellow 50-80%, red > 80%
rl_color() {
    local pct="${1%%.*}"
    if [[ "${pct:-0}" -gt 80 ]]; then printf '%b' "$RED"
    elif [[ "${pct:-0}" -gt 50 ]]; then printf '%b' "$YELLOW"
    else printf '%b' "$GREEN"
    fi
}

# Colour a context-usage percentage with thresholds tuned to autocompact at 90%.
# < 65% green (plenty of room), 65-80% yellow (plan to wrap), > 80% red (urgent).
ctx_color() {
    local pct="${1%%.*}"
    if [[ "${pct:-0}" -gt 80 ]]; then printf '%b' "$RED"
    elif [[ "${pct:-0}" -gt 65 ]]; then printf '%b' "$YELLOW"
    else printf '%b' "$GREEN"
    fi
}

# Format an age in seconds as a compact "Xs", "Xm", or "XhYm" string.
fmt_age() {
    local s="${1:-0}"
    if   [[ "$s" -lt 60   ]]; then printf '%ds' "$s"
    elif [[ "$s" -lt 3600 ]]; then printf '%dm' "$((s / 60))"
    else
        local h=$((s / 3600)) m=$(((s % 3600) / 60))
        if [[ "$m" -eq 0 ]]; then printf '%dh' "$h"
        else printf '%dh%dm' "$h" "$m"
        fi
    fi
}

# Cache hit ratio as integer percent: read / (read + write). Empty if no cache
# activity yet. High ratio = warm cache = cheap turns. Low ratio = paying full
# input price each turn.
cache_hit_pct() {
    local write="${1:-0}" read="${2:-0}"
    local total=$((write + read))
    [[ "$total" -eq 0 ]] && return 0
    printf '%d' $(( (read * 100) / total ))
}

# Colour for cache hit ratio: <50% red (cache cold), 50-80% yellow, >80% green.
cache_color() {
    local pct="${1:-0}"
    if   [[ "$pct" -ge 80 ]]; then printf '%b' "$GREEN"
    elif [[ "$pct" -ge 50 ]]; then printf '%b' "$YELLOW"
    else printf '%b' "$RED"
    fi
}

# Cost burn rate in $/min, rounded to 4 decimals. Empty if no usage yet.
cost_per_min() {
    local cost="${1:-0}" wall_ms="${2:-0}"
    [[ "$wall_ms" -le 0 ]] && return 0
    awk -v c="$cost" -v w="$wall_ms" 'BEGIN { printf "%.4f", (c * 60000) / w }'
}

# Compaction proximity: returns the gap from current % to the autocompact
# trigger (CLAUDE_AUTOCOMPACT_PCT_OVERRIDE, default 90). Empty when far away
# (< 50% used) so the indicator only appears when actionable.
compact_gap() {
    local used="${1%%.*}"
    local trigger="${CLAUDE_AUTOCOMPACT_PCT_OVERRIDE:-90}"
    [[ "${used:-0}" -lt 50 ]] && return 0
    local gap=$((trigger - used))
    [[ "$gap" -lt 0 ]] && gap=0
    printf '%d' "$gap"
}

# Append a labelled segment to a named line variable. Same as append_to but
# without the trailing space between label and value — used for tight composite
# segments like "Ctx: 72% → 12%".
append_raw() {
    local var="$1" content="$2"
    local cur="${!var}"
    [[ -n "$cur" ]] && cur="${cur}${SEP}"
    cur="${cur}${content}"
    printf -v "$var" '%s' "$cur"
}

# Strip ANSI escape codes to measure visible string length
strip_ansi() {
    printf '%s' "$1" | sed 's/\x1b\[[0-9;]*m//g'
}

# Count visible characters (unicode-safe via awk)
visible_len() {
    printf '%s' "$(strip_ansi "$1")" | awk '{print length}'
}

# File mtime in epoch seconds. macOS uses stat -f %m, GNU stat uses -c %Y.
file_mtime() {
    stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0
}

# Filesystem-safe slug from arbitrary string (for cache file names).
cache_slug() {
    printf '%s' "$1" | sed 's/[^A-Za-z0-9_.-]/_/g'
}

# True when the host terminal is known to support OSC 8 hyperlinks.
# Honours STATUSLINE_OSC8=true/false to force-enable or force-disable.
# Without an override, recognises Ghostty, iTerm2, kitty, WezTerm, VS Code,
# Hyper, foot, and libvte (GNOME Terminal) ≥ 0.50. Unknown terminals fall
# back to plain text so the statusline never shows raw escape sequences.
terminal_supports_osc8() {
    case "${STATUSLINE_OSC8:-}" in
        true|1) return 0 ;;
        false|0) return 1 ;;
    esac
    case "${TERM_PROGRAM:-}" in
        ghostty|iTerm.app|WezTerm|vscode|Hyper) return 0 ;;
    esac
    case "${TERM:-}" in
        xterm-kitty|foot|foot-extra) return 0 ;;
    esac
    [[ -n "${GHOSTTY_RESOURCES_DIR:-}" ]] && return 0
    [[ -n "${KITTY_WINDOW_ID:-}" ]] && return 0
    [[ -n "${WEZTERM_EXECUTABLE:-}" ]] && return 0
    if [[ "${VTE_VERSION:-0}" =~ ^[0-9]+$ ]] && [[ "${VTE_VERSION:-0}" -ge 5000 ]]; then
        return 0
    fi
    return 1
}

# Wrap text in an OSC 8 hyperlink escape so supporting terminals render it
# as clickable. Detects terminal capability via terminal_supports_osc8 and
# falls back to plain text on terminals that would otherwise show raw escapes
# (older xterm, Apple Terminal, Alacritty, etc).
#
# Emits literal \033 sequences (not pre-interpreted ESC bytes) so that the
# downstream `printf '%b'` that renders the status line interprets these
# escapes together with the color codes embedded in $text. Pre-interpreting
# them here would put a real ESC \ before the literal \033 of a color code
# and %b would treat the pair as \\\\033, dropping a backslash.
# Usage: osc8_link "https://example.com" "click me"
osc8_link() {
    local url="$1" text="$2"
    if [[ -z "$url" ]] || ! terminal_supports_osc8; then
        printf '%s' "$text"
        return
    fi
    printf '%s' '\033]8;;'"$url"'\033\\'"$text"'\033]8;;\033\\'
}

# True when the path is under ~/Workspace/ (work projects). The trailing slash is
# load-bearing — without it ~/Workspace-personal/ would also match, but that tree
# is explicitly excluded from CI status display.
is_workspace_project() {
    [[ "$1" == "$HOME/Workspace/"* ]]
}

# Ensure cache dir exists with restrictive perms. chmod runs only on first creation
# so the user can loosen perms later without us silently resetting them.
if [[ ! -d "$CACHE_DIR" ]]; then
    mkdir -p "$CACHE_DIR" 2>/dev/null && chmod 700 "$CACHE_DIR" 2>/dev/null
fi

# Append a labelled segment to a named line variable. Handles separator insertion.
# Usage: append_to line_a "Label:" COLOR "value"
# Uses ${!var} + printf -v (both bash ≥ 3.1) to support 80-col multi-line output.
append_to() {
    local var="$1" label="$2" color="$3" value="$4"
    local cur="${!var}"
    [[ -n "$cur" ]] && cur="${cur}${SEP}"
    cur="${cur}${DIM}${label}${RESET} ${color}${value}${RESET}"
    printf -v "$var" '%s' "$cur"
}

# ┌──────────────────────────────────────────────────────────────────────────────┐
# │  Parse JSON Input                                                            │
# │                                                                              │
# │  Claude Code pipes session state as JSON to stdin. A single jq call          │
# │  extracts all fields at once using @sh quoting, then eval sets them as       │
# │  shell variables. This avoids spawning jq multiple times.                    │
# └──────────────────────────────────────────────────────────────────────────────┘

input=$(cat 2>/dev/null || true)

if command -v jq >/dev/null 2>&1 && [[ -n "$input" ]]; then
    _jq_out=$(printf '%s' "$input" | jq -r '
        @sh "cwd=\(.cwd // .workspace.current_dir // env.PWD // "")",
        @sh "session_id=\(.session_id // "")",
        @sh "model=\(.model.display_name // "")",
        @sh "used=\(.context_window.used_percentage // "")",
        @sh "total_in=\(.context_window.total_input_tokens // "")",
        @sh "total_out=\(.context_window.total_output_tokens // "")",
        @sh "cache_create=\(.context_window.current_usage.cache_creation_input_tokens // "")",
        @sh "cache_read=\(.context_window.current_usage.cache_read_input_tokens // "")",
        @sh "rl_5h=\(.rate_limits.five_hour.used_percentage // "")",
        @sh "rl_7d=\(.rate_limits.seven_day.used_percentage // "")",
        @sh "json_effort=\(.effort.level // "")",
        @sh "json_thinking=\(if .thinking.enabled then "true" else "" end)",
        @sh "json_pr_number=\(.pr.number // "" | tostring | if . == "null" then "" else . end)",
        @sh "json_pr_review=\(.pr.review_state // "")",
        @sh "json_worktree_branch=\(.worktree.branch // "")",
        @sh "json_git_worktree=\(.workspace.git_worktree // "")",
        @sh "json_repo_owner=\(.workspace.repo.owner // "")",
        @sh "json_repo_name=\(.workspace.repo.name // "")",
        @sh "cost_usd=\(.cost_usd // .usage.cost_usd // .session.cost_usd // "")",
        @sh "wall_ms=\(.wall_ms // .session.wall_ms // .elapsed_ms // "")"
    ' 2>/dev/null) && eval "$_jq_out" 2>/dev/null || true
fi

cwd="${cwd:-$PWD}"

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  LINE 1 — Working directory, git info, PR status                             ║
# ╠══════════════════════════════════════════════════════════════════════════════╣

# ── Left side: path + git branch + dirty indicator + node version ──

# Replace $HOME with ~ for readability
display_path="$cwd"
if [[ "$display_path" == "$HOME"* ]]; then
    display_path="~${display_path#$HOME}"
fi

left="${GREEN}${display_path}${RESET}"

# ── Git branch and dirty indicator ──

branch=""
git_in_repo=false
gh_path=""          # "<owner>/<repo>" when origin is GitHub, else empty
repo_owner=""
repo_name=""

if [[ "$SHOW_GIT" == true ]]; then
    if git --no-optional-locks -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
        git_in_repo=true
        branch=$(git --no-optional-locks -C "$cwd" branch --show-current 2>/dev/null)
        [[ -z "$branch" ]] && branch="detached"

        # Parse origin remote once and reuse downstream. A missing remote (fresh
        # `git init`) or a non-GitHub host leaves gh_path empty, which is the
        # signal every gh-using block uses to bail out without spawning `gh`.
        remote_url=$(git --no-optional-locks -C "$cwd" config --get remote.origin.url 2>/dev/null)
        if [[ "$remote_url" =~ ^git@github\.com:(.+)$ ]] \
            || [[ "$remote_url" =~ ^ssh://git@github\.com/(.+)$ ]] \
            || [[ "$remote_url" =~ ^https?://github\.com/(.+)$ ]]; then
            gh_path="${BASH_REMATCH[1]%.git}"
            repo_owner="${gh_path%%/*}"
            repo_name="${gh_path#*/}"
        fi
    fi

    if [[ -n "$branch" ]]; then
        # Render branch as an OSC 8 clickable hyperlink to the GitHub branch URL
        # when origin is a GitHub remote. For non-GitHub remotes or detached
        # HEAD, fall back to plain text.
        branch_link=""
        if [[ "$branch" != "detached" && -n "$gh_path" ]]; then
            branch_link="https://github.com/${gh_path}/tree/${branch}"
        fi

        if [[ -n "$branch_link" ]]; then
            # OSC 8 hyperlink: ESC ] 8 ;; URL ST  TEXT  ESC ] 8 ;; ST   (ST = ESC + \)
            # Use the same \033 + \\\\ pattern as the colour vars so printf %b
            # interprets them uniformly at the final output step.
            branch_display="\\033]8;;${branch_link}\\033\\\\${branch}\\033]8;;\\033\\\\"
        else
            branch_display="${branch}"
        fi
        left="${left} ${RED}ϓ ${branch_display}${RESET}"
    fi

    # [$] = clean, [+] = dirty. Uses diff (not status --porcelain) to skip untracked scan.
    if [[ "$git_in_repo" == true ]]; then
        if git --no-optional-locks -C "$cwd" diff --quiet 2>/dev/null \
            && git --no-optional-locks -C "$cwd" diff --cached --quiet 2>/dev/null; then
            left="${left} ${YELLOW}[\$]${RESET}"
        else
            left="${left} ${YELLOW}[+]${RESET}"
        fi
    fi
fi


# ── Right side: GitHub PR status ──
# Reads whatever is cached and renders immediately. If the cache is stale or
# missing, spawns a fully-detached background `gh pr view` to refresh it for the
# next render (the harness re-runs us every refreshInterval seconds). The
# synchronous path NEVER blocks on `gh` — that's what trips Claude Code's
# statusline timeout and disables it for the rest of the process lifetime.

right=""

if [[ "$SHOW_PR" == true && "$git_in_repo" == true \
    && -n "$branch" && "$branch" != "detached" \
    && -n "$gh_path" ]] \
    && command -v gh >/dev/null 2>&1; then

    # Shared cache (repo + branch). The file may not exist yet, may be empty (a
    # known "no PR" marker), or may be stale — we use it as-is and refresh in bg.
    pr_cache_file="${CACHE_DIR}/pr-$(cache_slug "${cwd}::${branch}").json"
    pr_cache_age=999999
    [[ -f "$pr_cache_file" ]] && pr_cache_age=$(( $(date +%s) - $(file_mtime "$pr_cache_file") ))

    pr_json=""
    [[ -f "$pr_cache_file" ]] && pr_json=$(cat "$pr_cache_file" 2>/dev/null || true)

    # If cache is stale or missing, refresh asynchronously. setsid + nohup +
    # closing all inherited fds detaches the child completely so this script
    # exits in <100ms regardless of gh's response time.
    if [[ "$pr_cache_age" -ge "$PR_CACHE_TTL" ]]; then
        # Skip refresh if another refresh is already in flight (lock file).
        # Treat lock files older than 30s as stale (trap cleanup may not fire on SIGKILL).
        pr_lock="${pr_cache_file}.lock"
        pr_lock_age=0
        [[ -f "$pr_lock" ]] && pr_lock_age=$(( $(date +%s) - $(file_mtime "$pr_lock") ))
        if [[ "$pr_lock_age" -gt 30 ]]; then
            rm -f "$pr_lock" 2>/dev/null || true
        fi
        if ( set -o noclobber; : > "$pr_lock" ) 2>/dev/null; then
            nohup bash -c '
                trap "rm -f \"$1\"" EXIT
                NO_COLOR=1 GIT_TERMINAL_PROMPT=0 gh pr view \
                    --json number,author,reviewDecision,state,mergedAt,closedAt,body,latestReviews,reviewRequests,statusCheckRollup \
                    2>/dev/null > "$2.tmp.$$" && mv "$2.tmp.$$" "$2"
            ' _ "$pr_lock" "$pr_cache_file" </dev/null >/dev/null 2>&1 &
            disown 2>/dev/null || true
        fi
    fi

    if [[ -n "$pr_json" ]]; then
        pr_number=$(printf '%s' "$pr_json" | jq -r '.number // empty' 2>/dev/null)
        pr_author=$(printf '%s' "$pr_json" | jq -r '.author.login // empty' 2>/dev/null)
        pr_review=$(printf '%s' "$pr_json" | jq -r '.reviewDecision // empty' 2>/dev/null)
        pr_state=$(printf '%s' "$pr_json" | jq -r '.state // empty' 2>/dev/null)
    fi

    # repo_owner / repo_name already parsed once near the git_in_repo block above.

    # ── CI rollup (workspace projects only) ──
    # Collapses statusCheckRollup (a heterogeneous array of CheckRun + StatusContext
    # entries) into a single state plus counts. The // [] fallback handles cached PR
    # JSON written before this field was tracked — those simply render as "none".
    ci_state=""; ci_failed=0; ci_running=0; ci_total=0
    if [[ "$SHOW_CI" == true ]] && is_workspace_project "$cwd" && [[ -n "$pr_json" ]]; then
        ci_summary=$(printf '%s' "$pr_json" | jq -r '
            def is_failed:
                (((.conclusion // "") | ascii_downcase) | (. == "failure" or . == "cancelled" or . == "timed_out" or . == "action_required" or . == "startup_failure" or . == "stale"))
                or (((.state // "") | ascii_downcase) | (. == "failure" or . == "error"));
            def is_running:
                (((.status // "") | ascii_downcase) | (. == "in_progress" or . == "queued" or . == "pending" or . == "waiting"))
                or (((.state // "") | ascii_downcase) | (. == "pending"));
            (.statusCheckRollup // []) as $checks
            | ($checks | length) as $total
            | ($checks | map(select(is_failed)) | length) as $failed
            | ($checks | map(select(is_running)) | length) as $running
            | (if $total == 0 then "none"
               elif $failed > 0 then "fail"
               elif $running > 0 then "running"
               else "pass" end) as $state
            | "\($state) \($failed) \($running) \($total)"
        ' 2>/dev/null)
        read -r ci_state ci_failed ci_running ci_total <<< "$ci_summary"
    fi

    # Extract Jira ticket: try branch name first, then PR body
    jira_ticket=""
    if [[ "$branch" =~ ([A-Z][A-Z0-9]+-[0-9]+) ]]; then
        jira_ticket="${BASH_REMATCH[1]}"
    elif [[ -n "$pr_json" ]]; then
        jira_ticket=$(printf '%s' "$pr_json" | jq -r '.body // ""' 2>/dev/null \
            | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | head -1)
    fi

    # Split into completed reviews and pending requests
    completed_reviewers=""
    pending_reviewers=""
    if [[ -n "$pr_json" ]]; then
        # Pending reviewers (re-requested reviews take priority over past reviews)
        pending_reviewers=$(printf '%s' "$pr_json" | jq -r '
            [.reviewRequests[]? | (.login // .name // "team")]
            | .[]' 2>/dev/null)
        # Completed: users who submitted a review (skip bots, comments, and anyone re-requested)
        # Format: color:login:submittedAt
        completed_reviewers=$(printf '%s' "$pr_json" | jq -r --argjson pending \
            "$(printf '%s' "$pr_json" | jq '[.reviewRequests[]? | (.login // .name // "team")]' 2>/dev/null)" '
            [.latestReviews[]? |
                select(.author.login != "coderabbitai" and .state != "COMMENTED"
                    and ([.author.login] | inside($pending) | not)) |
                (if .state == "APPROVED" then "g"
                elif .state == "CHANGES_REQUESTED" then "r"
                else "d" end) + ":" + .author.login + ":" + (.submittedAt // "")]
            | .[]' 2>/dev/null)
    fi

    if [[ -n "$pr_number" ]]; then
        pr_label="${ORANGE}PR #${pr_number}${RESET}"
        if [[ -n "$repo_owner" && -n "$repo_name" ]]; then
            pr_label=$(osc8_link "https://github.com/${repo_owner}/${repo_name}/pull/${pr_number}" "$pr_label")
        fi
        right="$pr_label"
        # CI badge sits right after the PR number so build state is visible without
        # scanning past the Jira ticket, author, review state, and reviewer list.
        case "$ci_state" in
            pass)    right="${right} ${GREEN}CI ✓${RESET}" ;;
            fail)    right="${right} ${RED}CI ✗ ${ci_failed}/${ci_total}${RESET}" ;;
            running) right="${right} ${YELLOW}CI ● ${ci_running}/${ci_total}${RESET}" ;;
        esac
        if [[ -n "$jira_ticket" ]]; then
            jira_label="${TEAL}${jira_ticket}${RESET}"
            jira_label=$(osc8_link "https://clipboard.atlassian.net/browse/${jira_ticket}" "$jira_label")
            right="${right} ${jira_label}"
        fi
        [[ -n "$pr_author" ]] && right="${right} ${WHITE}@${pr_author}${RESET}"
        show_reviewers=true
        # PR lifecycle state takes priority over review decision.
        # A merged PR's reviewDecision is still "APPROVED" but the user
        # needs to see MERGED, not the stale review status.
        case "$pr_state" in
            MERGED)
                right="${right} ${MAUVE}MERGED${RESET}"
                state_ts=$(printf '%s' "$pr_json" | jq -r '.mergedAt // empty' 2>/dev/null)
                if [[ -n "$state_ts" ]]; then
                    state_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$state_ts" +%s 2>/dev/null || echo "")
                    if [[ -n "$state_epoch" ]]; then
                        diff_s=$(($(date +%s) - state_epoch))
                        if [[ $diff_s -lt 3600 ]]; then state_ago="$((diff_s / 60))m ago"
                        elif [[ $diff_s -lt 86400 ]]; then state_ago="$((diff_s / 3600))h ago"
                        else state_ago="$((diff_s / 86400))d ago"; fi
                        right="${right} ${DIM}(${state_ago})${RESET}"
                    fi
                fi
                show_reviewers=false ;;
            CLOSED)
                right="${right} ${RED}CLOSED${RESET}"
                state_ts=$(printf '%s' "$pr_json" | jq -r '.closedAt // empty' 2>/dev/null)
                if [[ -n "$state_ts" ]]; then
                    state_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$state_ts" +%s 2>/dev/null || echo "")
                    if [[ -n "$state_epoch" ]]; then
                        diff_s=$(($(date +%s) - state_epoch))
                        if [[ $diff_s -lt 3600 ]]; then state_ago="$((diff_s / 60))m ago"
                        elif [[ $diff_s -lt 86400 ]]; then state_ago="$((diff_s / 3600))h ago"
                        else state_ago="$((diff_s / 86400))d ago"; fi
                        right="${right} ${DIM}(${state_ago})${RESET}"
                    fi
                fi
                show_reviewers=false ;;
            *)
                case "$pr_review" in
                    APPROVED)           right="${right} ${GREEN}APPROVED${RESET}" ;;
                    CHANGES_REQUESTED)  right="${right} ${RED}CHANGES REQUESTED${RESET}" ;;
                    REVIEW_REQUIRED)    right="${right} ${YELLOW}REVIEW REQUIRED${RESET}" ;;
                    *)                  right="${right} ${DIM}NO REVIEW${RESET}"; show_reviewers=false ;;
                esac
                ;;
        esac
        # Append completed reviewers: "by name(2h) name(1d)"
        if [[ -n "$completed_reviewers" && "$show_reviewers" == true ]]; then
            right="${right} ${DIM}by${RESET}"
            now_epoch=$(date +%s)
            while IFS= read -r entry; do
                local_color="${entry%%:*}"
                local_rest="${entry#*:}"
                local_name="${local_rest%%:*}"
                local_ts="${local_rest#*:}"
                local_ago=""
                if [[ -n "$local_ts" ]]; then
                    review_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$local_ts" +%s 2>/dev/null || echo "")
                    if [[ -n "$review_epoch" ]]; then
                        diff_s=$((now_epoch - review_epoch))
                        if [[ $diff_s -lt 3600 ]]; then
                            local_ago="$((diff_s / 60))m"
                        elif [[ $diff_s -lt 86400 ]]; then
                            local_ago="$((diff_s / 3600))h"
                        else
                            local_ago="$((diff_s / 86400))d"
                        fi
                    fi
                fi
                case "$local_color" in
                    g) right="${right} ${GREEN}${local_name}${RESET}" ;;
                    r) right="${right} ${RED}${local_name}${RESET}" ;;
                    *) right="${right} ${DIM}${local_name}${RESET}" ;;
                esac
                [[ -n "$local_ago" ]] && right="${right} ${DIM}(${local_ago} ago)${RESET}"
            done <<< "$completed_reviewers"
        fi
        # Append pending reviewers: "waiting on name, name"
        if [[ -n "$pending_reviewers" ]]; then
            pending_list=""
            while IFS= read -r name; do
                [[ -n "$pending_list" ]] && pending_list="${pending_list}, "
                pending_list="${pending_list}${name}"
            done <<< "$pending_reviewers"
            right="${right} ${DIM}waiting on${RESET} ${YELLOW}${pending_list}${RESET}"
        fi
    fi
fi

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  Standalone CI fetch (workspace projects without an open PR)                 ║
# ║                                                                              ║
# ║  When the branch has a PR, statusCheckRollup is already on the cached PR     ║
# ║  JSON (no extra round trip). For branches without a PR (e.g., master), we    ║
# ║  run a small GraphQL query against the branch's HEAD commit so the CI badge  ║
# ║  still appears on line 1.                                                    ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

if [[ "$SHOW_CI" == true ]] && is_workspace_project "$cwd" \
    && [[ "$git_in_repo" == true ]] \
    && [[ -n "$branch" && "$branch" != "detached" ]] \
    && [[ -n "$repo_owner" && -n "$repo_name" ]] \
    && [[ -z "$ci_state" ]] \
    && command -v gh >/dev/null 2>&1; then

    ci_cache_file="${CACHE_DIR}/ci-$(cache_slug "${cwd}::${branch}").json"
    ci_cache_age=999999
    [[ -f "$ci_cache_file" ]] && ci_cache_age=$(( $(date +%s) - $(file_mtime "$ci_cache_file") ))

    # Read cache as-is (may be empty or stale).
    ci_json=""
    [[ -f "$ci_cache_file" ]] && ci_json=$(cat "$ci_cache_file" 2>/dev/null || true)

    # Refresh asynchronously when stale or missing — never block the render.
    if [[ "$ci_cache_age" -ge "$CI_CACHE_TTL" ]]; then
        ci_lock="${ci_cache_file}.lock"
        ci_lock_age=0
        [[ -f "$ci_lock" ]] && ci_lock_age=$(( $(date +%s) - $(file_mtime "$ci_lock") ))
        if [[ "$ci_lock_age" -gt 30 ]]; then
            rm -f "$ci_lock" 2>/dev/null || true
        fi
        if ( set -o noclobber; : > "$ci_lock" ) 2>/dev/null; then
            nohup bash -c '
                trap "rm -f \"$1\"" EXIT
                NO_COLOR=1 GIT_TERMINAL_PROMPT=0 gh api graphql \
                    -F owner="$2" -F repo="$3" -F branch="$4" \
                    -f query="query(\$owner: String!, \$repo: String!, \$branch: String!) { repository(owner: \$owner, name: \$repo) { ref(qualifiedName: \$branch) { target { ... on Commit { statusCheckRollup { contexts(first: 100) { nodes { __typename ... on CheckRun { status conclusion } ... on StatusContext { state } } } } } } } } }" \
                    2>/dev/null > "$5.tmp.$$" && mv "$5.tmp.$$" "$5"
            ' _ "$ci_lock" "$repo_owner" "$repo_name" "$branch" "$ci_cache_file" </dev/null >/dev/null 2>&1 &
            disown 2>/dev/null || true
        fi
    fi

    if [[ -n "$ci_json" ]]; then
        # Reshape into {statusCheckRollup: [...]} so the same jq works on both
        # PR-derived rollups and the GraphQL response.
        ci_summary=$(printf '%s' "$ci_json" \
            | jq '{statusCheckRollup: (.data.repository.ref.target.statusCheckRollup.contexts.nodes // [])}' 2>/dev/null \
            | jq -r '
                def is_failed:
                    (((.conclusion // "") | ascii_downcase) | (. == "failure" or . == "cancelled" or . == "timed_out" or . == "action_required" or . == "startup_failure" or . == "stale"))
                    or (((.state // "") | ascii_downcase) | (. == "failure" or . == "error"));
                def is_running:
                    (((.status // "") | ascii_downcase) | (. == "in_progress" or . == "queued" or . == "pending" or . == "waiting"))
                    or (((.state // "") | ascii_downcase) | (. == "pending"));
                (.statusCheckRollup // []) as $checks
                | ($checks | length) as $total
                | ($checks | map(select(is_failed)) | length) as $failed
                | ($checks | map(select(is_running)) | length) as $running
                | (if $total == 0 then "none"
                   elif $failed > 0 then "fail"
                   elif $running > 0 then "running"
                   else "pass" end) as $state
                | "\($state) \($failed) \($running) \($total)"
            ' 2>/dev/null)
        read -r ci_state ci_failed ci_running ci_total <<< "$ci_summary"
    fi

    # Render onto the right side. With no PR the right side starts empty, so the
    # CI badge becomes the only token; that keeps line 1 the source of truth.
    case "$ci_state" in
        pass)    right="${right:+${right} }${GREEN}CI ✓${RESET}" ;;
        fail)    right="${right:+${right} }${RED}CI ✗ ${ci_failed}/${ci_total}${RESET}" ;;
        running) right="${right:+${right} }${YELLOW}CI ● ${ci_running}/${ci_total}${RESET}" ;;
    esac
fi

# ── Render line 1 with right-aligned PR info ──

term_width="${COLUMNS:-120}"
left_len=$(visible_len "$left")
right_len=$(visible_len "$right")

pad=$(( term_width - left_len - right_len ))
[[ "$pad" -lt 1 ]] && pad=1

if [[ -n "$right" ]]; then
    printf '%b%*s%b\n' "$left" "$pad" "" "$right"
else
    printf '%b\n' "$left"
fi

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  LINES 2-3 — Model state + session economics                                 ║
# ║                                                                              ║
# ║  Line A (Model + lifecycle):                                                 ║
# ║    Model: Sonnet 4.6 (max) │ Ctx: 72% → 18% to compact │ Up 18m              ║
# ║                                                                              ║
# ║  Line B (Session economics):                                                 ║
# ║    Tokens In: 48k │ Cache 86% │ Tools: 15 Edits: 3 │ Cost: $0.42 ($1.42/min) │
# ║    │ Rate 5h: 23% 7d: 41%                                                    ║
# ║                                                                              ║
# ║  Each section is a small render_* function — easy to disable / re-order.     ║
# ╠══════════════════════════════════════════════════════════════════════════════╣

# ── Resolve effort + thinking: prefer live JSON values from stdin ──
# The JSON input now carries .effort.level and .thinking.enabled directly.
# Fall back to env var and settings.json for sessions started before this
# feature was available (older Claude Code builds).

effort="${json_effort:-}"
[[ -z "$effort" ]] && effort="${CLAUDE_CODE_EFFORT_LEVEL:-}"
if [[ -z "$effort" ]]; then
    effort=$(jq -r '.effortLevel // empty' ~/.claude/settings.json 2>/dev/null)
fi
thinking="${json_thinking:-}"
[[ -z "$thinking" ]] && thinking=$(jq -r '.alwaysThinkingEnabled // empty' ~/.claude/settings.json 2>/dev/null)

# ── Section renderers ──
# Each emits one composite segment (label + value, possibly chained) or nothing.
# All gate on their SHOW_* flag + data availability. Composition into a line
# happens at the bottom via append_raw.

render_model() {
    [[ "$SHOW_MODEL" == true && -n "$model" ]] || return 0
    local extras="$effort"
    [[ "$thinking" == "true" ]] && extras="${extras:+${extras}, }thinking"
    local label="${DIM}Model:${RESET} ${ORANGE}${model}${RESET}"
    [[ -n "$extras" ]] && label="${label} ${DIM}(${extras})${RESET}"
    printf '%s' "$label"
}

render_context() {
    [[ "$SHOW_CONTEXT" == true && -n "$used" ]] || return 0
    local pct_int; pct_int=$(printf '%.0f' "$used")
    local color; color="$(ctx_color "$used")"
    local out="${DIM}Ctx:${RESET} ${color}${pct_int}%${RESET}"
    # Compaction proximity arrow only shown when in the warning zone.
    local gap; gap="$(compact_gap "$used")"
    if [[ -n "$gap" ]]; then
        if [[ "$gap" -eq 0 ]]; then
            out="${out} ${DIM}→${RESET} ${RED}COMPACTING NEXT TURN${RESET}"
        else
            local gap_color; gap_color="$(ctx_color "$used")"
            out="${out} ${DIM}→${RESET} ${gap_color}${gap}%${RESET} ${DIM}to compact${RESET}"
        fi
    fi
    printf '%s' "$out"
}

render_session_age() {
    [[ "$SHOW_SESSION_AGE" == true && -n "${session_id:-}" ]] || return 0
    local start_file="$HOME/.claude/runtime/${session_id}/start-ts"
    [[ -s "$start_file" ]] || return 0
    local start; start=$(cat "$start_file" 2>/dev/null || echo 0)
    [[ "$start" -gt 0 ]] || return 0
    local age=$(( $(date +%s) - start ))
    [[ "$age" -lt 60 ]] && return 0  # noisy under a minute
    printf '%s' "${DIM}Up${RESET} ${GREEN}$(fmt_age "$age")${RESET}"
}

render_tokens_in() {
    [[ "$SHOW_TOKENS_IN" == true && -n "$total_in" && "$total_in" -gt 0 ]] || return 0
    # Compact format: k for thousands, M for millions.
    local n="$total_in" disp
    if   [[ "$n" -ge 1000000 ]]; then disp="$(awk -v n="$n" 'BEGIN { printf "%.1fM", n/1000000 }')"
    elif [[ "$n" -ge 1000    ]]; then disp="$(awk -v n="$n" 'BEGIN { printf "%.0fk", n/1000 }')"
    else                              disp="$n"
    fi
    printf '%s' "${DIM}Tokens In:${RESET} ${GREEN}${disp}${RESET}"
}

render_cache_ratio() {
    [[ "$SHOW_CACHE_RATIO" == true ]] || return 0
    [[ -n "$cache_create" || -n "$cache_read" ]] || return 0
    local pct; pct="$(cache_hit_pct "${cache_create:-0}" "${cache_read:-0}")"
    [[ -z "$pct" ]] && return 0
    local color; color="$(cache_color "$pct")"
    printf '%s' "${DIM}Cache${RESET} ${color}${pct}%${RESET}"
}

render_activity() {
    [[ "$SHOW_ACTIVITY" == true && -n "${session_id:-}" ]] || return 0
    local dir="$HOME/.claude/runtime/${session_id}"
    [[ -d "$dir" ]] || return 0
    local tools edits
    tools=$(cat "$dir/tool-count" 2>/dev/null || echo 0)
    edits=$(cat "$dir/edit-count" 2>/dev/null || echo 0)
    [[ "${tools:-0}" -eq 0 && "${edits:-0}" -eq 0 ]] && return 0
    local tcolor="$GREEN"
    [[ "${tools:-0}" -ge 20 ]] && tcolor="$RED"
    [[ "${tools:-0}" -ge 12 && "${tools:-0}" -lt 20 ]] && tcolor="$YELLOW"
    printf '%s' "${DIM}Tools:${RESET} ${tcolor}${tools}${RESET} ${DIM}Edits:${RESET} ${GREEN}${edits}${RESET}"
}

render_cost() {
    # Try cost field from JSON first; fall back to token-based estimation.
    local est_cost=""
    if [[ -n "$cost_usd" ]] && awk -v c="$cost_usd" 'BEGIN { exit (c+0 > 0) ? 0 : 1 }' 2>/dev/null; then
        est_cost=$(printf '%.4f' "$cost_usd")
        local out="${DIM}Cost:${RESET} ${ORANGE}\$${est_cost}${RESET}"
        if [[ -n "$wall_ms" && "$wall_ms" -gt 0 ]]; then
            local rate; rate=$(cost_per_min "$cost_usd" "$wall_ms")
            [[ -n "$rate" ]] && out="${out} ${DIM}(\$${rate}/min)${RESET}"
        fi
        printf '%s' "$out"
        return 0
    fi
    # Estimate from token counts + model-tier pricing ($/MTok).
    [[ -n "$total_in" && "${total_in:-0}" -gt 0 ]] || return 0
    local model_lc; model_lc=$(printf '%s' "${model:-}" | tr 'A-Z' 'a-z')
    local ip op cwp crp
    if   [[ "$model_lc" == *"opus"*  ]]; then ip=15;   op=75; cwp=18.75; crp=1.50
    elif [[ "$model_lc" == *"haiku"* ]]; then ip=0.80; op=4;  cwp=1.00;  crp=0.08
    else                                      ip=3;    op=15; cwp=3.75;  crp=0.30
    fi
    est_cost=$(awk -v ti="${total_in:-0}" -v to="${total_out:-0}" \
                   -v cc="${cache_create:-0}" -v cr="${cache_read:-0}" \
                   -v ip="$ip" -v op="$op" -v cwp="$cwp" -v crp="$crp" '
        BEGIN {
            reg = ti - cc - cr; if (reg < 0) reg = 0
            printf "%.4f", (reg*ip + to*op + cc*cwp + cr*crp) / 1000000
        }' 2>/dev/null)
    [[ -z "$est_cost" || "$est_cost" == "0.0000" ]] && return 0
    printf '%s' "${DIM}Cost~${RESET} ${ORANGE}\$${est_cost}${RESET}"
}

render_rate_limits() {
    [[ "$SHOW_RATE_LIMITS" == true ]] || return 0
    [[ -n "$rl_5h" || -n "$rl_7d" ]] || return 0
    local out="${DIM}Rate${RESET}"
    if [[ -n "$rl_5h" ]]; then
        out="${out} ${DIM}5h:${RESET} $(rl_color "$rl_5h")$(printf '%.0f' "$rl_5h")%${RESET}"
    fi
    if [[ -n "$rl_7d" ]]; then
        out="${out} ${DIM}7d:${RESET} $(rl_color "$rl_7d")$(printf '%.0f' "$rl_7d")%${RESET}"
    fi
    printf '%s' "$out"
}

# ── Compose lines ──
# Line A: lifecycle (what model, where in the session lifecycle)
# Line B: economics (what's been done, what it's costing, how much budget left)

line_a=""
line_b=""

for seg in "$(render_model)" "$(render_context)" "$(render_session_age)"; do
    [[ -n "$seg" ]] && append_raw line_a "$seg"
done

for seg in \
    "$(render_tokens_in)" \
    "$(render_cache_ratio)" \
    "$(render_cost)" \
    "$(render_rate_limits)"; do
    [[ -n "$seg" ]] && append_raw line_b "$seg"
done

[[ -n "$line_a" ]] && printf '%b\n' "$line_a"
[[ -n "$line_b" ]] && printf '%b\n' "$line_b"
exit 0
