# SPDX-FileCopyrightText: 2026 Igor Santos
# SPDX-License-Identifier: MIT
#
# Dependencies for this ~/.claude config (hooks, scripts/, shell/, statusline).
# Install with:  brew bundle --file ~/.claude/Brewfile
#
# Not available via Homebrew, install separately:
#   - claude  (Claude Code)  https://docs.claude.com/en/docs/claude-code  (npm i -g @anthropic-ai/claude-code, or the native installer)

# Core: required by hooks, scripts/, and the cc launcher
brew "git"          # used everywhere; the sanitize tool and hooks drive git directly
brew "jq"           # JSON parsing in hooks and statusline.sh
brew "python@3.13"  # hooks and scripts/ tools (requires-python >=3.9)
brew "rtk"          # CLI proxy that a PreToolUse hook routes every Bash command through

# Statusline and PR/CI integration
brew "gh"           # statusline PR and CI status (optional but recommended)
brew "node"         # statusline shows the active Node version

# zsh ships with macOS; the `cc` launcher is zsh-only. Uncomment to pin a Homebrew zsh.
# brew "zsh"

# macOS ships bash 3.2; the hooks use no bash 4+ features so the system bash works.
# Uncomment for a modern bash.
# brew "bash"
