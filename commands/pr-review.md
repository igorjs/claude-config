---
description: Review a PR (or current branch self-review) using grounding-review discipline + Conventional Comments. Posts findings as a pending GitHub review for human submit.
allowed-tools: Bash, Read, Grep, Glob, Write
argument-hint: "[PR number]"
model: opus
effort: max
---

# PR Review

Review a pull request with grounding-review discipline. Output a structured report, then orchestrate posting findings as inline comments on a **pending** GitHub review so the user picks the submit verb.

## Argument parsing

Parse `$ARGUMENTS`:

- Integer (e.g. `4265`, `#4265`) → explicit PR number, review that PR.
- Empty → **self-review mode**: resolve the PR for the current branch via `gh pr view --json number,headRefOid,author,headRefName -q '.number'`. If no PR exists, abort with `error: no PR found for current branch <name>; create one first or pass a PR number`.
- Anything else → abort with `error: pass an integer PR number or no args (self-review)`.

## Self-review awareness

GitHub rejects `APPROVE` and `REQUEST_CHANGES` events from the PR author. In self-review mode, the submit-verb question MUST only offer `comment` or `skip`. Detect by comparing `gh pr view --json author -q .author.login` against `gh api /user -q .login`.

## Voice rules (mandatory)

Invoke the `grounding-review` skill before drafting any finding, and load the `writing-style` skill alongside it (grounding-review depends on it for voice, banned words, and GitHub comment patterns). The full discipline lives in those two skills.

Comment bodies are read by another engineer, so they use the humane `writing-style` register (warm, contractions, constructive), NOT the terse operator voice from the "Concise & Direct" output style or system prompt `## Output`. Where those would conflict, `writing-style` wins for anything posted to GitHub. The non-negotiable points for inline comments posted to GitHub:

- **Conventional Comments label + decoration on every finding, PLAIN TEXT (no bold).** Start the body with `issue (non-blocking):`, `suggestion:`, `nitpick:`. NEVER wrap in `**...**`. Per writing-style: "a human typing fast doesn't wrap labels in `**`." Valid labels: `issue`, `suggestion`, `nitpick`, `question`, `thought`, `todo`. Valid decorations: `(blocking)`, `(non-blocking)`, `(if-minor)`.
- **1-2 sentences for non-blocking findings.** One ideal, two max. Blocking findings MAY run longer because there's a decision to argue.
- **Pick one pragmatic fix.** No "X, or Y" options. If both work, prefer the smallest diff and recommend that one.
- **Paraphrase, don't quote.** Block-quoting the README or source code is almost always longer than restating it in your own words.
- **Don't restate the diff or the anchor.** The author wrote the code; the comment is already on the line. Skip "this function adds X" and skip "at file:line" when the comment IS at that line.
- **Cause or consequence, not both.** State the cause; trust the reader to infer the consequence.
- **Drop intermediate-state padding.** "X is blank" beats "ships a blank X to the CSV".
- **No hedging.** Ban: "may actually be", "I'd lean toward", "that said", "worth noting", "it's worth mentioning", "one could argue".
- **No meta-justification.** "since X is a foot-gun" is reviewer-reasoning, not actionable info.
- **Casual register.** Fragments OK. Lowercase verbs fine.
- **No em dashes or en dashes.** Use commas, colons, or periods. Hard rule, also enforced in the system prompt and `writing-style`.

## Execution rules

1. Run every bash block for real. Don't simulate.
2. Read every file you cite, at the PR's head SHA (grounding-review evidence rule).
3. Combine independent bash calls into a single tool call.
4. Anchor every inline comment to a real `file:line` in the diff. If the line isn't in the diff (e.g. a referenced helper), make it a report-level finding instead.
5. Never auto-submit. Always create the review in `PENDING` state and ask the user how to submit.
6. Never post findings in the review body. The body is for a short human-voiced framing sentence or blank. All findings go inline.

## Step 1: Resolve PR and gather context

```bash
ARGS="$ARGUMENTS"
ARGS="${ARGS// /}"

if [ -z "$ARGS" ]; then
  PR_NUMBER=$(gh pr view --json number -q .number 2>/dev/null) || { echo "error: no PR for current branch" >&2; exit 1; }
else
  ARGS="${ARGS#\#}"
  case "$ARGS" in
    ''|*[!0-9]*) echo "error: pass an integer PR number or no args" >&2; exit 1 ;;
  esac
  PR_NUMBER="$ARGS"
fi

REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
HEAD_SHA=$(gh pr view "$PR_NUMBER" --json headRefOid -q .headRefOid)
PR_AUTHOR=$(gh pr view "$PR_NUMBER" --json author -q .author.login)
ME=$(gh api /user -q .login)
SELF_REVIEW=$([ "$PR_AUTHOR" = "$ME" ] && echo true || echo false)

REVIEW_JSON="/tmp/$REPO/pr-review-$PR_NUMBER.json"
mkdir -p "$(dirname "$REVIEW_JSON")"

echo "PR: $REPO#$PR_NUMBER"
echo "Head SHA: $HEAD_SHA"
echo "Author: $PR_AUTHOR (self-review: $SELF_REVIEW)"
echo "Review JSON: $REVIEW_JSON"

gh pr view "$PR_NUMBER"
gh pr diff "$PR_NUMBER"
```

Capture: `REPO`, `PR_NUMBER`, `HEAD_SHA`, `SELF_REVIEW`, `REVIEW_JSON`. You'll need them for the API calls in Step 4. `REVIEW_JSON` resolves to `/tmp/<org>/<repo>/pr-review-<number>.json`, and its directory is created here so the Step 4 write succeeds.

## Step 2: Read changed files at HEAD

For each file in the diff, Read it (whole file or relevant region) before drafting any finding on it. Diff context alone is insufficient (grounding-review rule).

If the branch is checked out locally and the working tree matches `HEAD_SHA`, local Read is fine. Otherwise fetch via `gh api /repos/$REPO/contents/<path>?ref=$HEAD_SHA -H 'Accept: application/vnd.github.raw'`.

## Step 3: Draft the review report

Use the grounding-review Findings Format for the **report you show the user**. Use the condensed inline format (label + 1-3 sentences) for the **content that will go on GitHub**.

Report structure shown to user:

```
## PR #<number>: <title>

### Overview
1-3 sentences. What the PR does, in human voice.

### Strengths
- Terse bullets. Skip if there's nothing genuinely worth calling out; better blank than fake-praise.

### Findings
For each finding:

- **<label> (<decoration>):** `<file>:<line>`
  <1-3 sentence body matching the voice rules above>
  <optional ```suggestion block```>

### Verification Summary
| File | Read? | Lines Verified | Findings |
|---|---|---|---|
| ... | Yes | 12, 42 | #1, #3 |

Confidence: HIGH | MEDIUM | LOW
```

Severity classification, label choice, blocking-vs-non-blocking, and the categories (security, performance, reliability, maintainability, correctness, architecture, scope) follow grounding-review verbatim.

## Step 4: Orchestrate posting

**Ask the user, one question at a time** (memory rule):

**Q1**: "Post findings as a pending review? Which ones: all, a subset (list numbers), or none?"

Wait for response. If `none` or `skip`, stop here.

Build a JSON payload at `$REVIEW_JSON` (`/tmp/<org>/<repo>/pr-review-<number>.json`; the directory was created in Step 1):

```json
{
  "commit_id": "<HEAD_SHA>",
  "comments": [
    {"path": "...", "line": N, "side": "RIGHT", "body": "**label (decoration):** ..."},
    {"path": "...", "start_line": N, "start_side": "RIGHT", "line": M, "side": "RIGHT", "body": "..."}
  ]
}
```

**No `body` field on the pending review.** The author chooses their own framing when they submit from the GitHub UI. (If the user explicitly supplies a body, include it.)

Create the pending review:

```bash
gh api -X POST /repos/$REPO/pulls/$PR_NUMBER/reviews --input "$REVIEW_JSON" --jq '{id, state, html_url}'
```

Confirm `state: PENDING` and capture the review id + html_url. Show the user the link.

**Q2**: "Submit verb?"

- Not self-review: offer `approve` / `comment` / `request-changes` / `skip`
- Self-review: offer `comment` / `skip` only (GitHub rejects approve/request-changes from the author)

If `skip`, stop. The pending review stays for manual submit from the UI. Otherwise:

```bash
gh api -X POST /repos/$REPO/pulls/$PR_NUMBER/reviews/$REVIEW_ID/events -f event=<APPROVE|COMMENT|REQUEST_CHANGES>
```

Confirm the returned `state` flipped from `PENDING` to the corresponding terminal state.

## Step 5: Verify and report

Final user-facing message: one sentence per outcome.

- "Pending review id `<id>` created, 7 inline comments queued. Submit from the UI when ready."
- OR: "Submitted as `COMMENT` at <timestamp>. Author will get one notification."

## Anti-patterns to refuse

If you catch yourself doing any of these while drafting findings, stop and rewrite:

1. **Diff restatement.** "This change moves X into Y so that...". Delete the entire setup sentence and lead with the finding.
2. **Hedging stack.** "may actually be" + "I'd lean toward" + "that said" in a single comment is a tell.
3. **Meta-justification.** "since a non-timestamp string in a timestamp column is its own foot-gun". The recommendation is enough; trust the reader.
4. **Bullet-list explanation inside a 2-sentence finding.** If you reach for a bulleted list inside an inline comment, the finding is too big. Split or simplify.
5. **Posting findings in the review body** instead of inline.
6. **Auto-submitting** without the two-question orchestration.

## Tradeoffs intentionally accepted

- **Self-review submit is COMMENT-only.** Documented limitation of the GitHub API, not a bug to work around.
- **Once submitted, the review wrapper can't be deleted.** Body can be mutated via `PUT /reviews/{id}` but must remain non-empty for COMMENT/REQUEST_CHANGES state. Prefer leaving in PENDING until the body and findings are settled.
- **Conventional Comments labels are mandatory even on nits.** They cost a few characters; they buy bot/human triage.
