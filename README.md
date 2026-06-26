# pragmatic-claude

My personal [Claude Code](https://docs.claude.com/en/docs/claude-code) setup: a zsh launcher, session hooks, a custom system prompt, skills, slash commands, and a statusline. It lives at `~/.claude` and replaces the default config directory.

## Requirements

| Tool | Status | Why |
|---|---|---|
| `claude` on PATH | required | Claude Code itself |
| zsh | required for `cc` | the launcher is zsh-only; run `claude` directly from any shell without it |
| `git`, `jq`, `bash`, `shasum` | required | used by hooks and the install script |
| `python3` 3.9+ | required | all hooks run in Python |
| `rtk` (Rust Token Killer) | required | a PreToolUse hook routes every Bash command through it to cut token use |
| `gh` | optional | statusline PR and CI status |

## Install

Config lives at `~/.claude` (all paths are hardcoded to `$HOME/.claude`).

Quickest, no clone:

```bash
curl -fsSL https://raw.githubusercontent.com/igorjs/pragmatic-claude/main/install.sh | bash
```

Downloads the latest release (or `main` if none exists), backs up anything it replaces to `~/.claude/backups/`, runs `brew bundle`, adds the launcher to `~/.zshrc`, and opens a fresh shell. Pin a version or install files only:

```bash
PRAGMATIC_CLAUDE_REF=v0.1.0 curl -fsSL https://raw.githubusercontent.com/igorjs/pragmatic-claude/main/install.sh | bash
curl -fsSL https://raw.githubusercontent.com/igorjs/pragmatic-claude/main/install.sh | bash -s -- --no-setup
```

Prefer git? Clone fresh:

```bash
git clone https://github.com/igorjs/pragmatic-claude.git ~/.claude
```

Already have a `~/.claude` from Claude Code? Adopt it in place. The `.gitignore` is an allowlist, so sessions, caches, and runtime files stay ignored:

```bash
cd ~/.claude
git init
git remote add origin https://github.com/igorjs/pragmatic-claude.git
git fetch origin
git checkout -f main
```

Add the launcher to `.zshrc`:

```bash
source ~/.claude/shell/cc.zsh
```

Reload with `exec zsh`.

## Usage

```bash
cc                     # resume this directory's last session, or start fresh
ccd                    # same, with --dangerously-skip-permissions
cc fresh               # new session, no history
cc list                # recent sessions for this directory
cc clean               # resume with /model, /effort, /output-style overrides stripped
cc raw [id]            # resume verbatim, no fork or cleanup
cc worktree <branch>   # create/enter a git worktree, then start a session there
```

`cc` loads the system prompt, picks a model, and prunes old transcripts (keeps the newest 5).

`cc worktree` (also `ccd worktree`) creates or enters a worktree off the project's base branch. It names the folder after the JIRA key in the branch name, copies `.env`, reuses `node_modules` via hardlinks, sets upstream, and runs a daily background cleanup of merged or stale worktrees. Claude auto-resolves rebase conflicts (`--ai-resolve` is always set). Only available via `cc`/`ccd`.

## Docs

Full documentation: [`docs/index.md`](docs/index.md).

- **Concepts** (`docs/concepts/`): system prompt design and the memory system.
- **Guides** (`docs/guides/`): plan-and-implement, review and PR flow, decisions and memory.
- **Authoring** (`docs/authoring/`): writing commands, skills, and hooks.
- **Internals** (`docs/internals/`): launcher, hooks, model routing, and memory injection.

## System prompt

`prompts/SYSTEM_PROMPT.md` is passed as `--system-prompt-file` on every `cc` session. It sets the persona (senior principal engineer, security specialization) and the rules every session follows: terse output, voice rules for prose, `rtk` integration, model routing, TDD, verification, and the memory protocol. Edit it to change how sessions behave; changes take effect on the next fresh session.

## Commands

Slash commands live in `commands/`. See [docs/guides](docs/guides) for full usage.

- `/scope`: interview-driven planning; saves a verified, parallel-safe plan to `.claude/plans/` for `/implement`.
- `/implement`: executes a `/scope` plan or `/adr` blueprint with subagents and TDD, committing each work unit. `--auto` opens a PR.
- `/adr`: creates an Architecture Decision Record through investigate → draft → quality-gate → finalise. Saves to `.claude/adr/`.
- `/commit-and-push`: writes a commit message from the staged diff, commits signed, optionally rebases, then pushes.
- `/quick-review`: single-pass PR review using the `grounding-review` discipline, posted as a pending GitHub review.
- `/deep-review`: multi-agent PR review; spawns specialist subagents in parallel, consolidates findings, posts a pending review.
- `/address-pr-comments`: walks unresolved PR comments, applies fixes or drafts replies, then pushes and posts replies.
- `/learn-project`: analyses the repo (git history, code, PRs, JIRA/Confluence) and writes distilled facts to memory. Read-only; confirms before writing.

## Skills

Skills live in `skills/` and load on demand. See [docs/authoring/01-commands-skills-hooks.md](docs/authoring/01-commands-skills-hooks.md).

- `grounding-review`: review discipline; severity levels, Conventional Comments, proof ladder, verification summary.
- `grounding-research`: investigation discipline; citation rules (every claim sourced to file:line), structured findings, scope boundaries.
- `engineering-standards`: PR readiness, test types, mocking rules, incremental delivery, deployment flow.
- `writing-style`: voice rules for human-facing prose; spartan, active voice, contractions, no dashes.
- `session-handoff`: decision-first handoff so the next session picks up cold without rereading the thread.

## Memory

Two levels, both markdown:

- Global: `~/.claude/memory/`, for cross-project facts.
- Per-project: `<repo>/.claude/memory/`, kept local-only via `.gitignore`, injected at session start.

## Layout

- `settings.json`: Claude Code settings (hooks, permissions, env, statusline, plugins).
- `shell/`: the `cc`/`ccd` launcher and its modules (session resume, config-drift detection, transcript retention) plus `worktree.zsh`.
- `hooks/`: SessionStart, PreToolUse, PostToolUse, and other hooks (model auto-detect, read/edit guards, memory reminders).
- `statusline.sh`: statusline (git branch, PR/CI status, token usage).
- `output-styles/`: custom output styles.

## Notes

Config edits (`settings.json` or hooks) take effect on a fresh session only. After changing them, run `cc fresh` or plain `claude`. `cc` warns you when a resumed session runs on stale config. The repo tracks config files, not runtime state. The allowlist `.gitignore` keeps sessions, caches, plugin manifests, and credentials out of git.

## License

MIT. See `LICENSE`.
