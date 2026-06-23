---
description: Rewrite any business-hours timestamps on unpushed commits, then push. On-demand replacement for the old git-push-guard PreToolUse hook.
allowed-tools: Bash
argument-hint: "[--dry-run] [git push args]"
---

# Git Push (timestamp-guarded)

Run the git-push-guard engine on demand: rewrite the committer/author dates of
any unpushed commits that fall in the forbidden window (Sydney Mon-Fri
08:00-18:00), re-sign them, then `git push`. This used to run automatically as a
`PreToolUse` hook; it's now explicit so a push only rewrites history when you ask.

The engine lives at `~/.claude/scripts/git-push-guard/git-push-guard` and owns
all the logic: per-repo locking, signing checks, the rewrite planner, and the
push itself. This command is a thin wrapper.

## Argument parsing

`$ARGUMENTS` is passed straight through to the engine, which splits its own
flags from the trailing `git push` args:

- `--dry-run` → show the planned rewrites and the push that would run, change nothing.
- Everything else (`origin`, branch refs, `--force-with-lease`, `-u`, etc.) is forwarded to `git push`.

No args means: rewrite if needed, then `git push` with no extra args (uses the branch's upstream).

## Execution rules

1. Run the engine for real. Do not simulate.
2. Never add `--force` / `--force-with-lease` yourself. Forward only what the user passed.
3. The engine rewrites history with `git filter-branch` only when forbidden-window commits exist and signing is configured. It restores via `ORIG_HEAD` on failure.
4. Report the engine's outcome from its exit code; do not second-guess it.

## Step 1: Run the guard

```bash
python3 "$HOME/.claude/scripts/git-push-guard/git-push-guard" $ARGUMENTS
rc=$?
echo "git-push-guard exit: $rc"
```

## Step 2: Interpret the result

Map the exit code to a one-line outcome for the user:

- `0` — pushed (or, with `--dry-run`, preview shown). If commits were rewritten, the engine logs each to `~/.claude/logs/git-push-guard.log`.
- `2` — not in a git repo.
- `3` — another guard instance holds the lock for this repo; retry once it frees.
- `4` — signing not configured (`commit.gpgsign` + `user.signingkey` required). Nothing was rewritten or pushed.
- `5` — the rewrite planner could not fit the commits into valid timestamps. Nothing pushed.
- `6` — `git filter-branch` failed; the engine reset to `ORIG_HEAD`. Nothing pushed.

For any non-zero code, surface the engine's stderr verbatim and stop. Don't retry automatically (except to tell the user a `3` is safe to retry).

## Notes

- Preview first with `/git-push --dry-run` when you want to see which commits would move before rewriting.
- Merge commits and commits authored by someone else are never rewritten; they anchor ordering.
- The engine reads the forbidden window and timezone from `git_push_guard/windows.py`. Change it there, not here.
