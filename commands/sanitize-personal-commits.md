---
description: Analyse business-hours commits and preview the fix, then apply on confirmation. Two stages, on-demand, so history changes only when you approve.
allowed-tools: Bash
argument-hint: "[--all] [--squash] [--rewrite-only] [git push args]"
---

# Sanitize Personal Commits

Run the sanitize-personal-commits engine in two stages. **analyse** finds the
commits in the hard cap (Sydney Mon-Fri 09:00-17:00) and computes the exact fix
(scattered off-hours timestamps, or a squash), prints a summary, and persists the
plan. **apply** executes that persisted plan verbatim: back up HEAD, rewrite or
squash, re-sign, then `git push`. You always see the analysis and confirm before
anything changes.

Two nested windows govern timestamps: the hard cap (09:00-17:00) is inviolable.
The soft cap (08:00-18:00) is preferred-avoid: the 08:00-09:00 / 17:00-18:00
buffer is a tolerated fallback (a warning, not a failure) that absorbs DST shifts.

The plan is deterministic: placement is seeded from the commit SHAs, so the
preview matches what apply will write. The rewrite range can include already-pushed
commits; when it does, the engine backs up the original HEAD to a
`backup/pre-sanitize-<timestamp>` branch and force-pushes with lease. It only
rewrites a range that is solely your own commits.

The engine lives at `~/.claude/scripts/sanitize-personal-commits/sanitize-personal-commits`
and owns all logic: locking, signing checks, the planner, the plan file, the
backup branch, and the push. This command orchestrates the two stages.

## Argument parsing

`$ARGUMENTS` is forwarded to the **analyse** stage, which splits its own flags from
the trailing `git push` args:

- `--all` → analyse the entire history (root..HEAD), re-signing every commit, instead of only from the first violation.
- `--squash` → collapse each contiguous run of business-hours commits into a single commit dated after 17:00, folding it into the immediately following same-day after-17:00 commit when one exists (which keeps its date), otherwise synthesizing one new commit. The combined message is AI-generated to describe the changes only.
- `--rewrite-only` → apply will rewrite/squash but not push.
- Everything else (`origin`, branch refs, `-u`, etc.) is forwarded to the eventual `git push`.

`apply` takes no arguments: it reads the plan that `analyse` wrote.

## Execution rules

1. Run the engine for real. Do not simulate.
2. Run **analyse** first, print its summary, and STOP to get explicit confirmation before running **apply**.
3. The engine decides whether a force-push is needed and adds `--force-with-lease` itself. Do not add `--force` yourself; forward only the push args the user passed.
4. Report each stage's outcome from its exit code; do not second-guess it.
5. After a successful apply that rewrote history, always offer to delete the backup branch.

## Step 1: Analyse

```bash
ENGINE="$HOME/.claude/scripts/sanitize-personal-commits/sanitize-personal-commits"
out=$(python3 "$ENGINE" analyse $ARGUMENTS 2>&1)
rc=$?
printf '%s\n' "$out"
echo "analyse exit: $rc"
```

## Step 2: Interpret the analysis

Map the analyse exit code:

- `0` — a plan was written (or there were no business-hours commits, a no-op that would just push). Proceed to Step 3.
- `2` — not in a git repo.
- `3` — another instance holds the lock for this repo; safe to retry once it frees.
- `5` — the planner could not fit the commits into valid timestamps. Nothing changed.
- `7` — the range contains commits by another author, or merge commits with `--squash`; refused. Nothing changed.
- `8` — `--squash` only: no after-17:00 slot at or before now (you ran it mid-workday). Re-run after 17:00. Nothing changed.

For any non-zero code, surface the engine's stderr verbatim and STOP (do not apply). A `3` is safe to retry.

If the summary says "no business-hours commits", tell the user there is nothing to sanitize (apply would only push) and confirm whether to proceed.

## Step 3: Confirmation gate

The summary is already printed (violations + planned fix + the push that would run).
Ask the user: `Apply this plan? [y/N]` and wait for the answer.

On anything other than an explicit yes, discard the plan and stop:

```bash
git_dir=$(git rev-parse --absolute-git-dir)
rm -f "$git_dir/sanitize-personal-commits-plan.json"
echo "Discarded. Nothing was changed."
```

## Step 4: Apply

On explicit yes, execute the persisted plan:

```bash
ENGINE="$HOME/.claude/scripts/sanitize-personal-commits/sanitize-personal-commits"
out=$(python3 "$ENGINE" apply 2>&1)
rc=$?
printf '%s\n' "$out"
echo "apply exit: $rc"
```

Map the apply exit code:

- `0` — applied and pushed (or, with `--rewrite-only`, applied without pushing). If it rewrote history, the engine prints `BACKUP_BRANCH=<name>`.
- `2` / `3` — not a git repo / lock held.
- `4` — signing not configured (`commit.gpgsign` + `user.signingkey` required). Nothing applied.
- `6` — backup failed, the rewrite/squash failed (engine restored the original HEAD), or scatter mode found an unstaged-changes working tree (stash/commit first, or use `--squash`). Nothing pushed.
- `9` — the plan is stale (HEAD moved since analyse) or missing. Re-run analyse.

For any non-zero apply code, surface the engine's stderr verbatim and stop.

## Step 5: Offer to delete the backup branch

Only on apply exit `0` and only when the output contains a `BACKUP_BRANCH=` line:

```bash
backup=$(printf '%s\n' "$out" | sed -n 's/^BACKUP_BRANCH=//p')
```

If `$backup` is set, ask: "Applied and pushed. Delete the backup branch `$backup`? [y/N]". On an explicit yes, run `git branch -D "$backup"`. Otherwise leave it as a recovery point.

## Notes

- The deterministic preview means `analyse` can be re-run safely; each run prints the same timestamps (scattered across plausible off-hours) and overwrites the plan file. The AI-generated squash message is fixed at analyse time, so apply uses exactly the message you saw.
- Merge commits and commits authored by someone else are never rewritten; they anchor ordering. A foreign commit in range aborts analyse (exit `7`); so does a merge commit with `--squash`.
- Scatter apply uses `git filter-branch`, which needs a clean working tree (exit `6` otherwise). `--squash` rebuilds via `git commit-tree`, verifies the final tree is byte-identical, and moves the branch with `reset --soft`, so it tolerates uncommitted changes.
- Commits that land in the 08:00-09:00 / 17:00-18:00 buffer print a `WARNING` to stderr but do not fail. Surface those warnings.
- The engine reads the hard/soft caps and timezone from `sanitize_personal_commits/windows.py` (`HARD_*_HOUR`, `SOFT_*_HOUR`). Change them there.
