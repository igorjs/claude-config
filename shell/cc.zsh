# Claude Code launcher — drop-in replacement for ~/.zshrc's _claude that adds
# subcommand dispatch (clean / fresh / raw / list) while preserving the original
# resume-by-customTitle default behavior.
#
# Plays nice with your existing cc() and ccd() wrappers — they call _claude
# unchanged; this file just redefines _claude with extra capabilities.
#
# Subcommands (works under both cc and ccd):
#
#   cc                Default — resume the most recent session for $PWD whose
#                     customTitle matches the directory name. If none found,
#                     start fresh with that name. (Identical to your original.)
#
#   cc clean          Clone the latest matching transcript with config-override
#                     slash commands stripped, then resume the clone.
#                     Stripped: /model, /effort, /config, /output-style, /style.
#                     Result: conversation preserved, runtime config defaults
#                     back to ~/.claude/settings.json. Use after editing
#                     settings, plugins, or hooks.
#                     Original transcript is untouched.
#
#   cc fresh          Start a brand-new session (no resume). Use after big
#                     settings rewrites or when you want zero conversation
#                     baggage.
#
#   cc raw [sid]      Resume verbatim — no fork, no clean, preserves the
#                     original UUID and all frozen overrides. Defaults to the
#                     latest matching session if sid omitted.
#
#   cc list           Show recent sessions for $PWD with timestamps + titles.
#
#   ccd <any of the above> — same dispatch, with --dangerously-skip-permissions.
#
# Default-path extras:
#   - Auto-fork on config drift: if settings.json or any hook changed since this
#     project last launched, the default resume forks to reload config (mints a
#     new transcript). No change → plain resume, no new file. Baseline tracked
#     in ~/.claude/cc-state/<project-slug>.
#   - Retention: after every cc/ccd, keeps only the newest $CCD_KEEP transcripts
#     (default 5) per project, deleting older ones + sidecar + runtime state.
#     Set CCD_KEEP=0 to disable. Floor of 2 protects fork/clean parents.
#
# Install: source this file from ~/.zshrc *after* your existing _claude/cc/ccd
# definitions. It overrides _claude only; cc() and ccd() in your zshrc stay.
#   source ~/.claude/shell/cc.zsh

# ─── cache buster ──────────────────────────────────────────────────────────
# _cc_bust_cache lives in its own file so it can be reused/edited independently.
source "$HOME/.claude/shell/bust-cache.zsh"

# ─── _claude (overridden) ──────────────────────────────────────────────────
# Drop-in replacement that adds subcommand dispatch. All non-subcommand args
# (including --dangerously-skip-permissions from ccd) are passed through to
# `command claude` exactly as your original did.
_claude() {
    emulate -L zsh 2>/dev/null || true
    _cc_bust_cache
    clear

    local name="${PWD##*/}"
    # Claude derives the project-dir slug by replacing EVERY non-alphanumeric
    # char with "-" (not just "/"). E.g. ~/.claude → "-Users-isantos--claude".
    # Replacing only "/" misses paths containing "." "_" space, etc.
    local project_dir="$HOME/.claude/projects/${PWD//[^a-zA-Z0-9]/-}"

    # Separate leading flags from positional args. The subcommand must be the
    # first non-flag token so `ccd clean` (which expands to
    # `_claude --dangerously-skip-permissions clean`) works.
    local -a flags
    flags=()
    while (( $# > 0 )); do
        case "$1" in
            -*) flags+=("$1"); shift ;;
            *)  break ;;
        esac
    done

    case "${1:-}" in
        clean|--clean)
            shift
            _cc_clean_resume "$project_dir" "$name" "${flags[@]}" "$@"
            return $?
            ;;
        fresh|--fresh)
            shift
            print -- "→ cc: fresh session (no resume; settings.json applied)"
            _cc_config_stamp
            command claude "${flags[@]}" -n "$name" "$@"
            return $?
            ;;
        raw|--raw)
            shift
            local raw_sid="${1:-}"
            [[ -n "$raw_sid" ]] && shift
            [[ -z "$raw_sid" ]] && raw_sid="$(_cc_find_session_by_title "$project_dir" "$name")"
            if [[ -z "$raw_sid" ]]; then
                print -- "→ cc raw: no matching session — starting fresh"
                command claude "${flags[@]}" -n "$name" "$@"
            else
                print -- "→ cc raw: resuming $raw_sid (no fork, overrides preserved)"
                command claude "${flags[@]}" --resume "$raw_sid" -n "$name" "$@"
            fi
            return $?
            ;;
        list|ls|--list)
            _cc_list_sessions "$project_dir"
            return $?
            ;;
    esac

    # ── Default: replicate the original _claude behavior ──
    local session_id
    session_id="$(_cc_find_session_by_title "$project_dir" "$name")"

    if [[ -n "$session_id" ]]; then
        # Plain --resume freezes settings/plugins/hooks at the session's original
        # startup. If config changed since this project last launched, fork to
        # reload it (mints a new transcript; retention prunes the parent). No
        # drift → plain resume, no new file.
        local -a fork
        fork=()
        if [[ -n "$(_cc_config_drifted)" ]]; then
            fork=(--fork-session)
            print -- "→ cc: config changed — forking to reload settings/plugins/hooks"
        fi
        local _cc_err_tmp
        _cc_err_tmp=$(mktemp)
        command claude "${flags[@]}" -n "$name" --resume "$session_id" "${fork[@]}" "$@" 2>"$_cc_err_tmp"
        local _cc_rc=$?
        if grep -q "No conversation found" "$_cc_err_tmp" 2>/dev/null; then
            rm -f "$_cc_err_tmp"
            print -- "→ cc: session ${session_id:0:8}… not found — starting fresh"
            command claude "${flags[@]}" -n "$name" "$@"
        else
            cat "$_cc_err_tmp" >&2
            rm -f "$_cc_err_tmp"
        fi
    else
        _cc_config_stamp
        command claude "${flags[@]}" -n "$name" "$@"
    fi
}

# ─── helpers (prefixed _cc_ to avoid namespace pollution) ──────────────────

# ── config-drift tracking (conditional fork) ──
# Fingerprint of everything that determines runtime config: settings.json plus
# every hook script. Matches session-init.sh's hash so the two agree.
_cc_config_hash() {
    { cat "$HOME/.claude/settings.json" 2>/dev/null
      find "$HOME/.claude/hooks" -name '*.sh' -type f -print0 2>/dev/null \
        | sort -z | xargs -0 cat 2>/dev/null
    } | shasum -a 256 2>/dev/null | cut -c1-16
}

# Per-project marker holding the config hash the project's session last ran.
_cc_config_marker() { print -- "$HOME/.claude/cc-state/${PWD//[^a-zA-Z0-9]/-}"; }

# Record current config as this project's baseline (call when launching a
# session that already runs current config: fresh / clean / new).
_cc_config_stamp() {
    local m; m="$(_cc_config_marker)"
    mkdir -p "${m:h}" 2>/dev/null
    _cc_config_hash > "$m" 2>/dev/null
}

# Echo "1" if config changed since this project's baseline; ALWAYS re-stamps to
# the current hash. Empty output = unchanged. Used to decide --fork-session.
_cc_config_drifted() {
    local m cur stored
    m="$(_cc_config_marker)"; cur="$(_cc_config_hash)"; stored="$(cat "$m" 2>/dev/null)"
    mkdir -p "${m:h}" 2>/dev/null; print -- "$cur" > "$m" 2>/dev/null
    [[ "$stored" != "$cur" ]] && print -- 1
}

# ── retention (bound disk) ──
# Keep only the newest $CCD_KEEP transcripts (default 5) for the current
# project; delete older ones plus their tool-result sidecar + runtime state.
# CCD_KEEP=0 disables. A floor of 2 protects fork/clean parents (always the 2nd
# newest). find+stat+sort — no zsh glob qualifiers (those misbehave non-interactively).
_cc_prune() {
    local keep=${CCD_KEEP:-5}
    [[ "$keep" -le 0 ]] && return 0
    (( keep < 2 )) && keep=2
    local pd="$HOME/.claude/projects/${PWD//[^a-zA-Z0-9]/-}"
    [[ -d "$pd" ]] || return 0
    local -a ranked
    ranked=( ${(f)"$(find "$pd" -maxdepth 1 -name '*.jsonl' -type f 2>/dev/null \
                       -exec stat -f '%m %N' {} + 2>/dev/null | sort -rn | cut -d' ' -f2-)"} )
    (( ${#ranked} > keep )) || return 0
    local f sid
    for f in "${(@)ranked[keep+1,-1]}"; do
        sid="${f:t:r}"
        rm -f  "$f" 2>/dev/null
        rm -rf "$pd/$sid" "$HOME/.claude/runtime/$sid" 2>/dev/null
    done
}

# Find the most recent .jsonl in $project_dir whose body contains the
# customTitle for $name. Exactly matches the original _claude's lookup,
# extracted into a function so the subcommands can reuse it.
_cc_find_session_by_title() {
    local project_dir="$1" name="$2"
    [[ -d "$project_dir" ]] || return 0
    local match_file
    match_file=$(grep -rl "\"customTitle\":\"$name\"" "$project_dir"/*.jsonl(N) 2>/dev/null \
                  | xargs ls -t 2>/dev/null | head -1)
    [[ -n "$match_file" ]] && print -- "${match_file:t:r}"
}

# UUID pattern check — excludes "memory/" and other non-session dirs.
_cc_is_uuid() {
    [[ "$1" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]
}

# Enumerate transcripts under $project_dir, newest first.
# Output: lines of "<mtime>\t<sid>\t<title>".
_cc_enumerate_sessions() {
    local project_dir="$1"
    [[ -d "$project_dir" ]] || return 0
    find "$project_dir" -mindepth 1 -maxdepth 1 -name '*.jsonl' -type f 2>/dev/null |
      while IFS= read -r f; do
          local sid="${f##*/}"; sid="${sid%.jsonl}"
          _cc_is_uuid "$sid" || continue
          local ts
          ts=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)
          # Pull customTitle from the transcript (cheap — usually in the first few lines).
          local title
          title=$(grep -m1 -oE '"customTitle":"[^"]*"' "$f" 2>/dev/null | head -1 \
                    | sed 's/"customTitle":"//; s/"$//')
          printf '%s\t%s\t%s\n' "$ts" "$sid" "${title:-(no title)}"
      done | sort -rnu -k1,1
}

_cc_list_sessions() {
    local project_dir="$1"
    if [[ ! -d "$project_dir" ]]; then
        print -- "no sessions for ${PWD##*/}"
        return 0
    fi
    print -- "Recent sessions for ${PWD##*/}:"
    _cc_enumerate_sessions "$project_dir" | head -10 |
      while IFS=$'\t' read -r ts sid title; do
          local when
          when=$(date -r "$ts" '+%Y-%m-%d %H:%M' 2>/dev/null \
                 || date -d "@$ts" '+%Y-%m-%d %H:%M' 2>/dev/null)
          printf '  %s  %s  %s\n' "$when" "${sid:0:8}…" "$title"
      done
}

# Clone the latest matching transcript with config-override slash commands
# stripped, then resume the clone. Conversation preserved, runtime config
# resets to settings.json defaults.
#
# Stripped (type=system, subtype=local_command):
#   /model, /effort, /config, /output-style, /style
#
# NOT stripped:
#   - corresponding stdout entries (just display text — harmless on replay)
#   - other slash commands (/clear, /resume, /mcp, /plugin, /permissions, …)
#   - permission-mode entries (security-relevant; user should re-grant)
_cc_clean_resume() {
    local project_dir="$1" name="$2"
    shift 2

    local old_sid
    old_sid="$(_cc_find_session_by_title "$project_dir" "$name")"
    if [[ -z "$old_sid" ]]; then
        print -- "→ cc clean: no matching session for '$name' — starting fresh"
        command claude -n "$name" "$@"
        return $?
    fi

    local old_jsonl="$project_dir/$old_sid.jsonl"
    if [[ ! -f "$old_jsonl" ]]; then
        print -- "→ cc clean: transcript missing at $old_jsonl"
        return 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        print -- "→ cc clean: jq required but not found"
        return 1
    fi
    if ! command -v uuidgen >/dev/null 2>&1; then
        print -- "→ cc clean: uuidgen required but not found"
        return 1
    fi

    local new_sid
    new_sid="$(uuidgen | tr 'A-Z' 'a-z')"
    local new_jsonl="$project_dir/$new_sid.jsonl"

    local strip_re='<command-name>/(model|effort|config|output-style|style)</command-name>'

    local total_in
    total_in=$(wc -l < "$old_jsonl" | tr -d ' ')

    jq -c --arg pat "$strip_re" '
        select(.type != "system" or ((.content // "") | test($pat) | not))
    ' "$old_jsonl" > "$new_jsonl" || {
        print -- "→ cc clean: jq filter failed"
        rm -f "$new_jsonl"
        return 1
    }

    local total_out stripped
    total_out=$(wc -l < "$new_jsonl" | tr -d ' ')
    stripped=$((total_in - total_out))

    # Rewrite sessionId fields so the harness sees a coherent transcript.
    local tmp="$new_jsonl.tmp"
    jq -c --arg sid "$new_sid" '
        if .sessionId then .sessionId = $sid else . end
    ' "$new_jsonl" > "$tmp" && mv "$tmp" "$new_jsonl"

    # Mirror the tool-results sidecar dir (symlinks save space; same content).
    if [[ -d "$project_dir/$old_sid" ]]; then
        mkdir -p "$project_dir/$new_sid"
        for f in "$project_dir/$old_sid"/*(N); do
            [[ -e "$f" ]] || continue
            ln -sf "$f" "$project_dir/$new_sid/${f:t}" 2>/dev/null
        done
    fi

    print -- "→ cc clean: cloned ${old_sid:0:8}… → ${new_sid:0:8}… (stripped $stripped override entries)"
    print -- "→ cc clean: settings.json + plugins + hooks reload from current config"
    _cc_config_stamp
    command claude --resume "$new_sid" -n "$name" "$@"
}

# ─── public wrappers ────────────────────────────────────────────────────────
# cc/ccd both dispatch through _claude. Each carries the custom system prompt;
# ccd adds --dangerously-skip-permissions. (These are the leading flags _claude
# splits off and passes through to `command claude`.)
cc()  { _claude --system-prompt-file "$HOME/.claude/SYSTEM_PROMPT.md" "$@"; local rc=$?; _cc_prune; return $rc; }
ccd() { _claude --dangerously-skip-permissions --system-prompt-file "$HOME/.claude/SYSTEM_PROMPT.md" "$@"; local rc=$?; _cc_prune; return $rc; }
