#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Igor Santos
# SPDX-License-Identifier: MIT
set +e   # Never let an error silently kill the status line
# ╔══════════════════════════════════════════════════════════════════════════════════════════════╗
# ║  Claude Code Status Line                                                                     ║
# ║                                                                                              ║
# ║  Two-line minimalist status bar rendered below the Claude Code prompt.                       ║
# ║  Receives session data as JSON on stdin; outputs ANSI-colored text.                          ║
# ║                                                                                              ║
# ║  Line 1 (LEFT):  ~/path branch [$]                                                           ║
# ║  Line 1 (RIGHT): PR #42 CI ✗ JIRA @author CHANGES REQUESTED by name (1h ago)                ║
# ║  Line 2: Opus 4.8 (high) | Ctx [███░░░] 38% | 5h 23% (2h left) | $0.42 | Cache 99%           ║
# ║                                                                                              ║
# ║  Secondary segments self-suppress until actionable (CI only on fail/run, 7d                  ║
# ║  rate only >50%, compaction arrow only >65%, session age only >10m).                         ║
# ║  Configure via STATUSLINE_* env vars or the feature flags below.                             ║
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
SHOW_CACHE_RATIO="${STATUSLINE_SHOW_CACHE_RATIO:-true}"   # Cache hit ratio %
SHOW_RATE_LIMITS="${STATUSLINE_SHOW_RATE_LIMITS:-true}" # 5h quota (+ 7d when >50%)

CTX_BAR_WIDTH="${STATUSLINE_CTX_BAR_WIDTH:-10}"   # cells in the context bar (1 per 10%)

PR_CACHE_TTL="${STATUSLINE_PR_CACHE_TTL:-60}"        # Seconds before cached PR data is refetched
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

SEP="${DIM} | ${RESET}"           # Dim pipe between line-2 segments

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

# Render a context-usage progress bar of `width` cells, one cell per (100/width)%.
# Filled cells use █, empty cells ░. Fill rounds to the nearest cell and clamps
# to [0, width]. Caller wraps it in color. Usage: ctx_bar 38 10  ->  ████░░░░░░
ctx_bar() {
    local used="${1%%.*}" width="${2:-10}"
    [[ -z "$used" ]] && used=0
    local filled=$(( (used * width + 50) / 100 ))
    [[ "$filled" -lt 0 ]] && filled=0
    [[ "$filled" -gt "$width" ]] && filled=$width
    local empty=$(( width - filled )) bar="" i
    for ((i = 0; i < filled; i++)); do bar="${bar}█"; done
    for ((i = 0; i < empty;  i++)); do bar="${bar}░"; done
    printf '%s' "$bar"
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

# Append a pre-rendered segment to a named line variable, inserting SEP between
# segments. Usage: append_raw line_2 "$(render_model)"
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
        @sh "cache_create=\(.context_window.current_usage.cache_creation_input_tokens // "")",
        @sh "cache_read=\(.context_window.current_usage.cache_read_input_tokens // "")",
        @sh "rl_5h=\(.rate_limits.five_hour.used_percentage // "")",
        @sh "rl_5h_reset=\(.rate_limits.five_hour.resets_at // "")",
        @sh "rl_7d=\(.rate_limits.seven_day.used_percentage // "")",
        @sh "json_effort=\(.effort.level // "")",
        @sh "json_thinking=\(if .thinking.enabled then "true" else "" end)",
        @sh "json_pr_number=\(.pr.number // "" | tostring | if . == "null" then "" else . end)",
        @sh "json_pr_review=\(.pr.review_state // "")",
        @sh "json_worktree_branch=\(.worktree.branch // "")",
        @sh "json_git_worktree=\(.workspace.git_worktree // "")",
        @sh "json_repo_owner=\(.workspace.repo.owner // "")",
        @sh "json_repo_name=\(.workspace.repo.name // "")",
        @sh "cost_usd=\(.cost.total_cost_usd // "")",
        @sh "wall_ms=\(.cost.total_duration_ms // "")"
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
        # Pass is silent; only failing/running CI surfaces.
        case "$ci_state" in
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
    # Pass is silent; only failing/running CI surfaces.
    case "$ci_state" in
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
# ║  LINE 2 — Model state + session economics                                    ║
# ║                                                                              ║
# ║  Opus 4.8 (high) | Ctx [███░░░] 38% | 5h 23% (2h left) | $0.42 | Cache 99%    ║
# ║                                                                              ║
# ║  Each section is a small render_* function — easy to disable / re-order.     ║
# ╠══════════════════════════════════════════════════════════════════════════════╣

# Effort + thinking come straight from the JSON input (.effort.level / .thinking.enabled).
effort="${json_effort:-}"
thinking="${json_thinking:-}"

# ── Section renderers ──
# Each emits one composite segment or nothing, gating on its SHOW_* flag + data.
# Composition into line 2 happens at the bottom via append_raw.

render_model() {
    [[ "$SHOW_MODEL" == true && -n "$model" ]] || return 0
    local extras="$effort"
    [[ "$thinking" == "true" ]] && extras="${extras:+${extras}, }thinking"
    local label="${ORANGE}${model}${RESET}"
    [[ -n "$extras" ]] && label="${label} ${DIM}(${extras})${RESET}"
    printf '%s' "$label"
}

render_context() {
    [[ "$SHOW_CONTEXT" == true && -n "$used" ]] || return 0
    local pct_int; pct_int=$(printf '%.0f' "$used")
    local color; color="$(ctx_color "$used")"
    local bar; bar="$(ctx_bar "$used" "$CTX_BAR_WIDTH")"
    local out="${DIM}Ctx${RESET} ${color}[${bar}] ${pct_int}%${RESET}"
    # Compaction proximity arrow only surfaces in the warning zone (>65%).
    local gap; gap="$(compact_gap "$used")"
    [[ "${pct_int:-0}" -le 65 ]] && gap=""
    if [[ -n "$gap" ]]; then
        if [[ "$gap" -eq 0 ]]; then
            out="${out} ${DIM}→${RESET} ${RED}COMPACTING NEXT TURN${RESET}"
        else
            out="${out} ${DIM}→${RESET} ${color}${gap}%${RESET} ${DIM}to compact${RESET}"
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
    [[ "$age" -lt 600 ]] && return 0   # hide under 10 minutes
    printf '%s' "${DIM}Up${RESET} ${GREEN}$(fmt_age "$age")${RESET}"
}

render_cache_ratio() {
    [[ "$SHOW_CACHE_RATIO" == true ]] || return 0
    [[ -n "$cache_create" || -n "$cache_read" ]] || return 0
    local pct; pct="$(cache_hit_pct "${cache_create:-0}" "${cache_read:-0}")"
    [[ -z "$pct" ]] && return 0
    local color; color="$(cache_color "$pct")"
    printf '%s' "${DIM}Cache${RESET} ${color}${pct}%${RESET}"
}

render_cost() {
    [[ -n "$cost_usd" ]] || return 0
    awk -v c="$cost_usd" 'BEGIN { exit (c + 0 > 0) ? 0 : 1 }' 2>/dev/null || return 0
    local est_cost; est_cost=$(printf '%.4f' "$cost_usd")
    local out="${ORANGE}\$${est_cost}${RESET}"   # $ is the cue; no label
    if [[ -n "$wall_ms" && "$wall_ms" -gt 0 ]]; then
        local rate; rate=$(cost_per_min "$cost_usd" "$wall_ms")
        [[ -n "$rate" ]] && out="${out} ${DIM}(\$${rate}/min)${RESET}"
    fi
    printf '%s' "$out"
}

# Always-on 5h quota: used % colored by threshold, plus time until the window resets.
render_rate_5h() {
    [[ "$SHOW_RATE_LIMITS" == true && -n "$rl_5h" ]] || return 0
    local out="${DIM}5h${RESET} $(rl_color "$rl_5h")$(printf '%.0f' "$rl_5h")%${RESET}"
    if [[ -n "$rl_5h_reset" ]]; then
        local left=$(( rl_5h_reset - $(date +%s) ))
        [[ "$left" -gt 0 ]] && out="${out} ${DIM}($(fmt_age "$left") left)${RESET}"
    fi
    printf '%s' "$out"
}

# Trailing 7d quota — surfaces only once it crosses 50% (5h has its own segment).
render_rate_7d() {
    [[ "$SHOW_RATE_LIMITS" == true && -n "$rl_7d" ]] || return 0
    awk -v v="${rl_7d:-0}" 'BEGIN { exit (v + 0 > 50) ? 0 : 1 }' 2>/dev/null || return 0
    printf '%s' "${DIM}Rate 7d:${RESET} $(rl_color "$rl_7d")$(printf '%.0f' "$rl_7d")%${RESET}"
}

# ── Compose line 2 ──
# model · ctx bar · 5h quota · cost · cache · age · 7d-rate. Secondary segments
# self-suppress; empties are skipped so separators never double up.
line_2=""
for seg in \
    "$(render_model)" \
    "$(render_context)" \
    "$(render_rate_5h)" \
    "$(render_cost)" \
    "$(render_cache_ratio)" \
    "$(render_session_age)" \
    "$(render_rate_7d)"; do
    [[ -n "$seg" ]] && append_raw line_2 "$seg"
done
[[ -n "$line_2" ]] && printf '%b\n' "$line_2"
exit 0
