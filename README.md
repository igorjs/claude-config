# claude-config

My personal [Claude Code](https://docs.claude.com/en/docs/claude-code) setup: a zsh launcher, session hooks, a custom system prompt, skills, slash commands, and a statusline. It lives at `~/.claude` and replaces the default config directory.

## Requirements

- Claude Code installed, with the `claude` command on your `PATH`.
- zsh. The `cc` launcher is zsh-only, but you can still run `claude` directly from any shell.
- `git`, `jq`, `bash`, and a SHA-256 tool (`shasum`).
- `python3` (3.9+) for the hooks and the tools under `scripts/`.
- `rtk` (Rust Token Killer). A PreToolUse hook routes every Bash command through it to cut token use.
- Optional: `gh` for the statusline's PR and CI status.

## Install

The repo has to live at `~/.claude`. Every path inside it is hardcoded to `$HOME/.claude`.

Fresh machine, no `~/.claude` yet:

```bash
git clone https://github.com/igorjs/claude-config.git ~/.claude
```

Already have a `~/.claude` that Claude Code created? Adopt it in place. The `.gitignore` is an allowlist, so your sessions, caches, and other runtime files stay ignored and untouched.

```bash
cd ~/.claude
git init
git remote add origin https://github.com/igorjs/claude-config.git
git fetch origin
git checkout -f main
```

Then add the launcher to your `.zshrc`:

```bash
source ~/.claude/shell/cc.zsh
```

Reload the shell with `exec zsh` and you're set.

## Usage

Start or resume a session with `cc`:

```bash
cc            # resume this directory's last session, or start fresh
ccd           # same, with --dangerously-skip-permissions
cc fresh      # new session, no history
cc list       # recent sessions for this directory
cc clean      # resume a copy with /model, /effort, /output-style overrides stripped
cc raw [id]   # resume verbatim, no fork or cleanup
```

`cc` loads the system prompt, picks a model, and prunes old transcripts (keeps the newest 5 by default).

## System prompt

`prompts/SYSTEM_PROMPT.md` is what `cc` passes to `claude` as the session system prompt (`--system-prompt-file`). It defines the persona (a senior principal engineer with a security specialization) and the operating rules every session follows:

- Output: terse and spartan, no filler or hedging.
- Writing: voice rules for human-facing prose.
- CLI environment: notes on `rtk` and the shell.
- Code: when to plan, model routing, test-driven development, verification, self-review.
- Security: a tiered policy for offensive-security requests.
- Memory: the two-level memory protocol (see below).

Edit this file to change how every `cc` session behaves. Changes apply on the next fresh session.

## Commands

Slash commands live in `commands/` and run as `/<name>` inside a session:

- `/commit-and-push`: write a commit message from the staged diff, commit it signed, optionally rebase onto the base branch, then push.
- `/pr-review`: review a PR (or the current branch as a self-review) using the `grounding-review` discipline and Conventional Comments, posted as a pending GitHub review for you to submit.
- `/address-pr-comments`: walk unresolved PR review comments one at a time, apply a fix or draft a reply, then push and post the replies with the new SHA.
- `/sanitize-personal-commits`: analyse business-hours commit timestamps, preview the fix, and apply on confirmation. Two stages, so history changes only when you approve.

## Skills

Skills live in `skills/` and load on demand when a task matches:

- `grounding-review`: review discipline. Severity levels, Conventional Comments labels, a proof ladder for different claim types, and a required verification summary.
- `writing-style`: voice rules for human-facing prose (PR descriptions, review comments, commit messages). Spartan, active voice, contractions, no dashes or filler.
- `session-handoff`: a decision-first handoff so the next session or person picks up cold without rereading the whole thread.

## Memory

Two levels, both markdown:

- Global at `~/.claude/memory/`, for cross-project facts.
- Per-project at `<repo>/.claude/memory/`, for facts that only apply inside one repo. Kept local-only via `.gitignore`, injected at session start.

## Layout

- `settings.json`: Claude Code settings (hooks, permissions, env, statusline, plugins).
- `shell/`: the zsh `cc`/`ccd` launcher and its modules (session resume, config-drift detection, transcript retention).
- `hooks/`: SessionStart, PreToolUse, PostToolUse, and other hooks (model auto-detect, read/edit guards, memory reminders).
- `statusline.sh`: the statusline (git branch, PR/CI status, token usage).
- `scripts/`: standalone tools. The Python ones need a venv: `cd <dir> && python3 -m venv .venv && .venv/bin/pip install -e .`.
- `output-styles/`: custom output styles.

## Notes

- Config edits (settings.json or hooks) take effect on a fresh session, not a resumed one. After changing them, run `cc fresh` or plain `claude`. `cc` warns you when a resumed session runs on stale config.
- The repo tracks the config files, not runtime state. The allowlist `.gitignore` keeps sessions, caches, plugin manifests, and credentials out of git.
- Commit signing for the `scripts/` tools comes from your global git config (`user.signingkey`, `commit.gpgsign`), not from this repo.

## License

MIT License. See `LICENSE`.
