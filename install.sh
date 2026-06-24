#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Igor Santos
# SPDX-License-Identifier: MIT
#
# Installer for igorjs/claude-config — drops the tracked config into ~/.claude
# without a git clone. Quick start:
#
#   curl -fsSL https://raw.githubusercontent.com/igorjs/claude-config/main/install.sh | bash
#
# Source of truth: the latest GitHub release by default, or CLAUDE_CONFIG_REF
# (any tag/branch/sha). Falls back to the main branch when no release exists.
# Existing tracked files are backed up before being replaced; runtime state
# (sessions/, projects/, history, plugins/) is never touched.
set -euo pipefail

REPO="igorjs/claude-config"
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
REF="${CLAUDE_CONFIG_REF:-}"
SKIP_DEPS=0
SKIP_SHELL=0

if [ -t 1 ]; then
    C_B=$'\033[1;34m'; C_Y=$'\033[1;33m'; C_R=$'\033[1;31m'; C_0=$'\033[0m'
else
    C_B=""; C_Y=""; C_R=""; C_0=""
fi
log()  { printf '%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
warn() { printf '%swarning:%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

print_help() {
    cat <<'EOF'
Install igorjs/claude-config into ~/.claude (no git clone).

Usage:
  curl -fsSL https://raw.githubusercontent.com/igorjs/claude-config/main/install.sh | bash
  curl -fsSL .../install.sh | bash -s -- [flags]
  ./install.sh [flags]

Env:
  CLAUDE_CONFIG_REF=<tag|branch|sha>  source ref (default: latest release, else main)
  CLAUDE_HOME=<dir>                   install target (default: $HOME/.claude)

Flags:
  --ref <ref>    same as CLAUDE_CONFIG_REF
  --skip-deps    skip 'brew bundle'
  --skip-shell   skip editing ~/.zshrc
  --no-setup     skip all setup steps (install files only)
  -h, --help     show this help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --skip-deps)  SKIP_DEPS=1 ;;
        --skip-shell) SKIP_SHELL=1 ;;
        --no-setup)   SKIP_DEPS=1; SKIP_SHELL=1 ;;
        --ref)        shift; REF="${1:-}" ;;
        --ref=*)      REF="${1#--ref=}" ;;
        -h|--help)    print_help; exit 0 ;;
        *)            die "unknown option: $1 (try --help)" ;;
    esac
    shift
done

[ -n "$CLAUDE_HOME" ] || die "CLAUDE_HOME is empty"
command -v curl >/dev/null 2>&1 || die "curl is required"
command -v tar  >/dev/null 2>&1 || die "tar is required"

resolve_tarball_url() {
    if [ -n "$REF" ]; then
        printf 'https://codeload.github.com/%s/tar.gz/%s\n' "$REPO" "$REF"
        return
    fi
    local api tag
    api="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null || true)"
    tag="$(printf '%s' "$api" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    tag="${tag%%$'\n'*}"
    if [ -n "$tag" ]; then
        printf 'https://codeload.github.com/%s/tar.gz/refs/tags/%s\n' "$REPO" "$tag"
    else
        warn "no GitHub release found; falling back to the main branch"
        printf 'https://codeload.github.com/%s/tar.gz/refs/heads/main\n' "$REPO"
    fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

url="$(resolve_tarball_url)"
log "Downloading $url"
curl -fsSL "$url" -o "$TMP/config.tar.gz" || die "download failed: $url"
tar -xzf "$TMP/config.tar.gz" -C "$TMP" || die "could not extract archive"

SRC="$(find "$TMP" -mindepth 1 -maxdepth 1 -type d -name '*claude-config*' | head -1)"
[ -n "$SRC" ] || SRC="$(find "$TMP" -mindepth 1 -maxdepth 1 -type d | head -1)"
[ -d "$SRC" ] || die "could not locate extracted source directory"

mkdir -p "$CLAUDE_HOME"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$CLAUDE_HOME/backups/install-$STAMP"
backed_up=0

log "Installing config into $CLAUDE_HOME"
shopt -s dotglob nullglob
for src in "$SRC"/*; do
    name="$(basename "$src")"
    case "$name" in
        .git|.github|.DS_Store) continue ;;
    esac
    dest="$CLAUDE_HOME/$name"
    if [ -e "$dest" ]; then
        mkdir -p "$BACKUP"
        cp -R "$dest" "$BACKUP/"
        rm -rf "$dest"
        backed_up=1
    fi
    cp -R "$src" "$dest"
done
shopt -u dotglob nullglob

# --- setup -----------------------------------------------------------------

if [ "$SKIP_DEPS" -eq 0 ]; then
    if command -v brew >/dev/null 2>&1; then
        log "Installing dependencies (brew bundle)"
        # </dev/null is required: when this script is run via `curl ... | bash`,
        # the script itself arrives on stdin. brew reads stdin and would consume
        # the rest of the script, so setup steps after this would silently never
        # run. Redirecting keeps brew off the script stream.
        brew bundle --file "$CLAUDE_HOME/Brewfile" </dev/null || warn "brew bundle reported errors"
    else
        warn "Homebrew not found; skipping deps. See https://brew.sh, then: brew bundle --file $CLAUDE_HOME/Brewfile"
    fi
fi

if [ "$SKIP_SHELL" -eq 0 ]; then
    ZSHRC="$HOME/.zshrc"
    if [ -f "$ZSHRC" ] && grep -qF 'shell/cc.zsh' "$ZSHRC"; then
        log "Your .zshrc already sources cc.zsh"
    else
        zshrc_backup=""
        if [ -f "$ZSHRC" ]; then
            cp "$ZSHRC" "$ZSHRC.bak-$STAMP"
            zshrc_backup=" (backup: $ZSHRC.bak-$STAMP)"
        fi
        # Single quotes are intentional: write the literal $HOME so zsh expands
        # it at runtime, not the install-time value.
        # shellcheck disable=SC2016
        printf '\n# claude-config launchers (cc/ccd)\nsource "$HOME/.claude/shell/cc.zsh"\n' >> "$ZSHRC"
        log "Added cc.zsh source to your .zshrc${zshrc_backup}"
    fi
fi

# --- summary ---------------------------------------------------------------

log "Done."
printf '\n'
printf 'Installed to: %s\n' "$CLAUDE_HOME"
[ "$backed_up" -eq 1 ] && printf 'Replaced files backed up to: %s\n' "$BACKUP"
printf '\nNext steps:\n'
printf '  - Install the claude CLI if needed: npm i -g @anthropic-ai/claude-code (or the native installer)\n'

# Drop into a fresh login shell so the new config is active immediately.
# Only when interactive and shell setup ran. Reconnect stdin to the terminal
# (</dev/tty) so this works under `curl ... | bash`, where stdin is the pipe.
# exec replaces this process, so nothing runs after it.
if [ "$SKIP_SHELL" -eq 0 ] && [ -t 1 ] && [ -e /dev/tty ]; then
    USER_SHELL="${SHELL:-/bin/zsh}"
    log "Reloading your shell ($USER_SHELL)"
    exec "$USER_SHELL" -l </dev/tty
fi
