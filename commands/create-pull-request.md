---
description: Create a pull request with pre-flight checks, a conventional-commit title, and the team PR template, following engineering-standards and writing-style.
allowed-tools: Bash, Read, Skill
argument-hint: "[--draft] [--base <branch>] [--ticket <ID>] [--yes]"
effort: high
---

# Create Pull Request

Push the current branch and open a pull request. The title is a conventional-commit summary, the body follows the team template, and both obey `engineering-standards` (readiness, size) and `writing-style` (voice, banned words, no dashes).

This creates a **new** PR. If one already exists for the branch, this stops and points you at `/address-pr-comments` or `/quick-review`.

## Argument flags

Parse these from `$ARGUMENTS` and set the env vars before Step 1:

- `--draft` → `DRAFT_FLAG=true` (open the PR as a draft)
- `--base <branch>` → `BASE_ARG=<branch>` (override the base branch)
- `--ticket <ID>` → `TICKET_ARG=<ID>` (force the ticket, skips branch auto-detect; pass `none` to omit the line)
- `--yes` or `-y` → `AUTO_CREATE=true` (skip the final confirmation gate)
- `--help` → print the usage block above and stop

No flags means: auto-detect base and ticket, then ask for confirmation before pushing and creating.

## Execution rules

1. Run every bash block for real. Do not simulate output; use the real result to drive the next step.
2. Do not assume git state, diff contents, or `gh` output. Check them.
3. Combine independent bash operations into single tool calls.
4. Never run destructive git commands (`reset --hard`, `push --force`, `clean -f`) or skip hooks (`--no-verify`).
5. Derive the title and body from the actual diff and commit log, never from the branch name alone or from memory.
6. Pass the PR body via `--body-file`, never `--body "..."`, to preserve formatting.

## Step 0: Load the skills (MUST run before drafting title or body)

Invoke both via the Skill tool before writing any prose:

- `writing-style`: voice, banned words, the "PR descriptions" guidance, and the golden rule (no em or en dashes). Every line of the title and body MUST follow it.
- `engineering-standards`: PR readiness criteria and size limits, enforced in Step 2.

The PR title and body are read by another engineer, so they use the humane `writing-style` register (warm, contractions, active voice), NOT the terse operator voice. Where they conflict, `writing-style` wins for anything posted to GitHub.

## Step 1: Establish context and resolve the base branch

```bash
set -euo pipefail

CURRENT_BRANCH=$(git branch --show-current)
if [ -z "$CURRENT_BRANCH" ]; then echo "ERROR: detached HEAD; checkout a branch first"; exit 1; fi

# Resolve base: flag > repo default (gh) > git symbolic-ref > main
if [ -n "${BASE_ARG:-}" ]; then
  BASE_BRANCH="$BASE_ARG"
else
  BASE_BRANCH=$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null \
    || git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' \
    || echo main)
fi

if [ "$CURRENT_BRANCH" = "$BASE_BRANCH" ]; then
  echo "ERROR: on the base branch ($BASE_BRANCH); create a feature branch first"; exit 1
fi

git fetch origin "$BASE_BRANCH" --quiet 2>/dev/null || true

LIAM_TMP="/tmp/create-pr/$(basename "$(git rev-parse --show-toplevel)")/$(echo "$CURRENT_BRANCH" | tr '/' '-')"
mkdir -p "$LIAM_TMP"
echo "Branch: $CURRENT_BRANCH -> $BASE_BRANCH"
echo "TMP: $LIAM_TMP"
```

Then check for an existing PR. If one exists, stop and report its URL:

```bash
EXISTING=$(gh pr view "$CURRENT_BRANCH" --json url,state -q 'select(.state=="OPEN") | .url' 2>/dev/null || true)
if [ -n "$EXISTING" ]; then
  echo "A PR already exists: $EXISTING"
  echo "Use /address-pr-comments or /quick-review instead."
  exit 0
fi
```

## Step 2: Pre-flight checks (engineering-standards)

```bash
# Commits ahead of base
AHEAD=$(git rev-list --count "origin/$BASE_BRANCH..HEAD" 2>/dev/null || echo 0)
# Size (additions + deletions)
SHORTSTAT=$(git diff --shortstat "origin/$BASE_BRANCH...HEAD")
CHANGED=$(echo "$SHORTSTAT" | grep -oE '[0-9]+ insertion|[0-9]+ deletion' | grep -oE '[0-9]+' | paste -sd+ - | bc 2>/dev/null || echo 0)
# Uncommitted work that would be left out of the PR
DIRTY=$(git status --porcelain | wc -l | tr -d ' ')
# Does the diff touch any test files?
TESTS=$(git diff --name-only "origin/$BASE_BRANCH...HEAD" | grep -ciE '(\.test\.|\.spec\.|_test\.|test_|/tests?/|/__tests__/)' || true)

echo "commits_ahead=$AHEAD changed_lines=${CHANGED:-0} dirty_files=$DIRTY test_files_touched=$TESTS"
```

Evaluate against `engineering-standards`, then decide:

- **`AHEAD` = 0** → abort. There is nothing to open a PR for.
- **`DIRTY` > 0** → warn: those changes are uncommitted and won't be in the PR. Ask whether to proceed, commit first (`/commit-and-push`), or stop.
- **`CHANGED` > 1000** → this exceeds the hard size limit. Ask the user to justify or split before continuing.
- **`CHANGED` > 500** → note it is above the soft limit; suggest splitting, but continue if they accept.
- **`TESTS` = 0** → note the diff adds no tests. Confirm this is intentional (docs, config, pure refactor) before continuing; the readiness criteria expect tests for behaviour changes.

Report the readiness picture in one short block, then continue.

## Step 3: Gather the diff and commit history

```bash
echo "=== diff stat ==="
git diff --stat "origin/$BASE_BRANCH...HEAD"
echo "=== commit log ==="
git log "origin/$BASE_BRANCH..HEAD" --format='%h %s'
git diff "origin/$BASE_BRANCH...HEAD" > "$LIAM_TMP/pr-diff.txt"
echo "Full diff: $LIAM_TMP/pr-diff.txt ($(wc -l < "$LIAM_TMP/pr-diff.txt") lines)"
```

Read `$LIAM_TMP/pr-diff.txt` with the Read tool. This is the source of truth for the title and body. If it is large, read it in chunks; do not skip it.

## Step 4: Detect the ticket (optional)

```bash
if [ -n "${TICKET_ARG:-}" ]; then
  TICKET="$TICKET_ARG"   # may be the literal "none"
else
  # First PROJECT-1234 style token in the branch name
  TICKET=$(echo "$CURRENT_BRANCH" | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | head -1 || true)
fi
echo "TICKET=${TICKET:-<none>}"
```

- If `TICKET` is a real ID (not empty, not `none`) → include `Ticket: <ID>` as the first line of the body.
- If empty → the branch has no ticket. Ask the user once for a ticket ID; if they don't have one, omit the line entirely.
- If `none` → omit the line, don't ask.

## Step 5: Generate the title (conventional commits)

Derive the title from the diff and commit log gathered in Step 3.

- Format: `type(scope): summary`, e.g. `feat(auth): add SSO retry logic`. Scope is optional.
- Types: `feat`, `fix`, `refactor`, `perf`, `docs`, `test`, `build`, `ci`, `chore`.
- Imperative mood ("add", not "added" or "adds"), no trailing period, under 72 characters.
- The summary states the **effect** of the change, not a list of files.
- The ticket goes in the body, not the title.

## Step 6: Generate the body (MANDATORY template)

Fill this template exactly. Keep the section order. Follow `writing-style` throughout: active voice, contractions, no banned words, no em or en dashes, no "This PR..." filler.

```markdown
Ticket: PROJECT-1234

## Summary

<Why are we doing this? 1-2 sentences, active voice. Focus on the why, not the what. The bug being fixed, the requirement, the motivation. Do not echo the title.>

## What Changed

- <Bullets in plain terms. Describe concepts and context, not files. Give the reviewer what they need to follow the change. 3-8 bullets, grouped logically.>

## Notes for reviewers

- <Optional. Oddities, trade-offs, intentional tech debt, anything that needs human context. Drop this whole section if there's nothing to add.>

## Related work

- <Optional. Cross-references to other PRs or tickets. Drop this whole section if there's nothing to add.>
```

Rules for filling it:

1. **`Ticket:` line**: include only when Step 4 found a real ID; otherwise delete the line so the body starts at `## Summary`.
2. **Summary**: the why, not the what. One or two sentences. If the title is `fix(cache): stop stale reads after invalidation`, the Summary explains why stale reads mattered, not that you changed the cache.
3. **What Changed**: every bullet maps to something real in the diff. Group by concept, don't enumerate files. Use the same terms the code uses (if it's a "handler", don't call it a "controller").
4. **Notes for reviewers**: drop the heading entirely if empty. Don't leave "N/A".
5. **Related work**: drop the heading entirely if empty.
6. No trailing "generated by" footer. No test-count noise. If CI covers it, the reviewer sees CI.

Write the finished body to a file:

```bash
cat > "$LIAM_TMP/pr-body.md" << 'PRBODY_EOF'
<the filled template goes here>
PRBODY_EOF
echo "Body written: $LIAM_TMP/pr-body.md"
```

## Step 7: Confirm

Unless `AUTO_CREATE=true`, show the user the resolved title, the rendered body, base branch, and draft flag. Ask for confirmation or edits. Apply edits to `$LIAM_TMP/pr-body.md` before continuing.

## Step 8: Push and create

```bash
git push -u origin "HEAD:refs/heads/$CURRENT_BRANCH"

gh pr create \
  --title "$TITLE" \
  --body-file "$LIAM_TMP/pr-body.md" \
  --base "$BASE_BRANCH" \
  ${DRAFT_FLAG:+--draft}
```

## Step 9: Report

```bash
PR_URL=$(gh pr view "$CURRENT_BRANCH" --json url -q .url 2>/dev/null || true)
echo "PR: $PR_URL"
```

Show the PR URL and a one-line summary (title, base, draft state). Done.
