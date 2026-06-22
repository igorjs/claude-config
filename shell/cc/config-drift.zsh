# cc module: config-drift tracking (conditional fork)
#
# Determines whether runtime config changed since a project last launched, so
# the default resume can fork to reload settings/plugins/hooks only when needed.
# Baseline is stored per-project under ~/.claude/cc-state/<project-slug>.

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
