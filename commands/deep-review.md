---
description: Multi-agent PR review. A swarm of specialist reviewer subagents (logic, test, security, data, types, perf, plus conditional) run in parallel, consolidated and fact-checked, then posted as a pending GitHub review. Heavier than /quick-review.
allowed-tools: Bash, Read, Grep, Glob, Write, Task
argument-hint: "[PR number] [--all] [--quick] [--preset <name>] [--self] [--help]"
model: opus
effort: max
---

# Deep Review: Multi-Agent PR Review

Review a pull request with a swarm of specialist reviewer subagents run in parallel, each a focused `Task` agent under the `grounding-review` and `grounding-research` discipline. The orchestrating session consolidates, dedups, and fact-checks their findings, then posts them as a **pending** GitHub review (same posting flow as `/quick-review`). This is heavier and slower than `/quick-review`; use it for substantial, risky, or cross-cutting PRs.

Invoked as `/deep-review`. The remaining arguments are an optional PR number and flags.

## Help

If the arguments contain `--help`, print this and stop:

```
/deep-review - Multi-agent PR review with a specialist reviewer swarm

USAGE:
  /deep-review [PR_NUMBER] [options]

OPTIONS:
  --help            Show this help
  --all             Run every reviewer regardless of diff content
  --quick           Run only the core reviewers
  --preset <name>   Named reviewer set: security | architecture | data | docs | thorough
  --self            Local self-review (never posts to GitHub)

EXAMPLES:
  /deep-review               Review the current branch's PR (auto-selects reviewers)
  /deep-review 123           Review PR #123
  /deep-review 123 --all     PR #123 with every reviewer
  /deep-review --self        Self-review the current branch, no posting
```

## Reviewer Swarm

**Core reviewers** (run unless a preset narrows the set):

| Reviewer | Focus |
| --- | --- |
| logic | algorithm correctness, edge cases, off-by-one, normalisation, false positives/negatives |
| test | coverage gaps, missing scenarios, untested error paths, weak assertions, flakiness |
| security | auth, PII handling, crypto, injection, IDOR, leaked secrets |
| data | query/DAO correctness, N+1, missing indexes, transaction boundaries |
| types | `any`, unsafe casts (`as`), non-null assertions (`!`), weak typing (language-appropriate) |
| perf | N+1, unbounded data, connection leaks, work inside loops |

**Conditional reviewers** (added in `auto` mode when the diff shows the trigger):

| Reviewer | Trigger |
| --- | --- |
| architecture | new modules, dependency or layer changes, boundary violations |
| big-o | algorithms over collections, sorting, searching, graph traversal |
| complexity | deep nesting, large functions, tight coupling |
| integration | feature flags, events, external APIs, config, deployment changes |
| migration | database migrations, schema changes |
| docs | README changes, breaking changes, new public APIs |
| dedup | many similar files, or a large diff (>300 changed lines) |
| adr | an Architecture Decision Record is added or affected |

**Presets:** `security` = security+data+types+logic · `architecture` = architecture+complexity+big-o+dedup · `data` = data+migration+perf · `docs` = docs+adr · `thorough` = all.

## Execution rules (MUST)

1. Run every bash block for real. Don't simulate.
2. No caching: every invocation is a fresh run, even if you reviewed this PR earlier in the conversation. The code may have changed.
3. No skipping (except steps guarded by a flag the user didn't set).
4. No assumptions: run the command and read the result.
5. Follow the command's gates, not your own.
6. Show real data: tables and reports come from actual output, never placeholders.
7. **No selective filtering at presentation.** After consolidation (Step 4) you present EVERY surviving finding; the user decides what to post in Step 6. (Consolidation's dedup/drop rules are the only removals, and they happen in Step 4, not by hiding findings in Step 5.)
8. **Never ask whether to run.** Invoking `/deep-review` IS the instruction to run; start immediately.

## Voice rules

Invoke the `grounding-review` and `writing-style` skills before drafting any finding (same discipline as `/quick-review`). Non-negotiables for anything posted to GitHub: Conventional Comments label + decoration in **plain text** (`issue (blocking):`, `suggestion:`, `nitpick:`, never bold); 1-2 sentences for non-blocking findings; one pragmatic fix, not a menu; no hedging; no meta-justification; no em or en dashes.

## Step 1: Resolve PR and gather context

```bash
ARGS="$ARGUMENTS"
FLAGS=$(echo "$ARGS" | grep -oE '\-\-[a-z]+( [a-z]+)?')   # for reference; parse flags from $ARGUMENTS
PR_ARG=$(echo "$ARGS" | tr ' ' '\n' | grep -E '^#?[0-9]+$' | head -1 | tr -d '#')

if [ -z "$PR_ARG" ]; then
  PR_NUMBER=$(gh pr view --json number -q .number 2>/dev/null) || { echo "error: no PR for current branch; pass a PR number" >&2; exit 1; }
else
  PR_NUMBER="$PR_ARG"
fi

REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
HEAD_SHA=$(gh pr view "$PR_NUMBER" --json headRefOid -q .headRefOid)
PR_AUTHOR=$(gh pr view "$PR_NUMBER" --json author -q .author.login)
ME=$(gh api /user -q .login)
SELF_REVIEW=$([ "$PR_AUTHOR" = "$ME" ] && echo true || echo false)

REVIEW_JSON="/tmp/$REPO/deep-review-$PR_NUMBER.json"
mkdir -p "$(dirname "$REVIEW_JSON")"

echo "PR: $REPO#$PR_NUMBER  head: $HEAD_SHA  self-review: $SELF_REVIEW"
echo "Review JSON: $REVIEW_JSON"

gh pr view "$PR_NUMBER"
gh pr diff "$PR_NUMBER"
```

Capture `REPO`, `PR_NUMBER`, `HEAD_SHA`, `SELF_REVIEW`, `REVIEW_JSON`. `--self` forces self-review mode (never posts), regardless of authorship.

## Step 2: Select reviewers

- `--quick` → core reviewers only.
- `--all` → every core + conditional reviewer.
- `--preset <name>` → that preset's set.
- otherwise (`auto`, default) → all core reviewers, plus each conditional reviewer whose trigger appears in the diff from Step 1 (grep the diff for migration dirs, schema files, feature flags, new modules, ADR files, >300 changed lines, etc.). Report which reviewers you selected and why.

## Step 3: Spawn the reviewer swarm (parallel Task subagents)

Spawn the selected reviewers **in parallel** (one message, multiple `Task` calls), each as a `general-purpose` subagent with `model: "sonnet"`. Each reviewer prompt MUST include: its focus area (from the table), the PR diff and `HEAD_SHA`, and the `grounding-review` + `grounding-research` discipline. Instruct each to:

- Read every file it cites at `HEAD_SHA` (diff context alone is insufficient); quote exact code with `file:line`; tag anything unconfirmed `[unverified]`.
- Stay within its focus; don't report issues another reviewer owns.
- Return findings as a JSON array, one object per finding:

```json
{"file": "...", "line": N, "side": "RIGHT", "label": "issue", "decoration": "blocking",
 "category": "security", "confidence": "HIGH", "evidence": "<exact code>", "body": "<1-2 sentence finding>"}
```

Collect every reviewer's JSON. If a reviewer returns nothing, record it ran with zero findings (not a failure).

## Step 4: Consolidate and fact-check

Merge all findings, then (this is where removals happen):

- **Dedup across reviewers:** same file + nearby lines + same concern → keep the one with the stronger label, drop the rest.
- **Merge same-line findings:** two+ findings within 3 lines → one comment at the highest severity, combining the points.
- **Drop out-of-scope:** a finding on a file not in the PR diff is dropped UNLESS the PR's change breaks it (typecheck failure, runtime error, broken import). Preexisting-style nits outside the diff are dropped.
- **Filter already-addressed:** fetch existing review comments (`gh api --paginate /repos/$REPO/pulls/$PR_NUMBER/comments`), drop findings that duplicate one, and attribute by name ("already raised by @user").
- **Fact-check (orchestrator):** for each surviving finding, read the file at `HEAD_SHA` and confirm the evidence appears at the cited line; resolve or remove `[unverified]` tags; correct drifted line numbers; drop fabricated findings.
- **Drop non-actionable:** `thought`/positive observations with no "do X" → always drop; `nitpick` → drop from an APPROVE review unless asked.
- **Verdict + confidence:** APPROVE / REQUEST_CHANGES / COMMENT / INCONCLUSIVE. **INCONCLUSIVE (never APPROVE)** if the swarm failed to run; say why. Confidence HIGH/MEDIUM/LOW.

## Step 5: Present the consolidated report

Present ALL surviving findings (rule 7), using the `/quick-review` report shape:

```
## PR #<number>: <title>
<files> | +<additions> -<deletions>

### Overview
1-3 sentences, human voice.

### Reviewers
Which reviewers ran, and findings per reviewer (e.g. security: 2, logic: 1, perf: 0).

### Findings
Numbered, ordered blocking > non-blocking > suggestion > nitpick. Per finding:
- **<label> (<decoration>):** `<file>:<line>`  [confidence]
  <1-2 sentence body in the voice rules>

### Verification Summary
| File | Read? | Lines verified | Findings |

**Verdict:** <...>  **Confidence:** <...>
```

## Step 6: Orchestrate posting

If `--self` (or self-review with nothing postable), stop here: the report IS the deliverable, no GitHub posting.

Otherwise ask **one question at a time**:

- **Q1:** "Post which findings as a pending review? all / none / a subset (numbers)." If `none`, stop.
- Build the payload at `$REVIEW_JSON` (`{"commit_id": "<HEAD_SHA>", "comments": [{"path","line","side","body"}, ...]}`, body starting with the plain-text Conventional Comment label, no review `body`), then create the pending review:

```bash
gh api -X POST /repos/$REPO/pulls/$PR_NUMBER/reviews --input "$REVIEW_JSON" --jq '{id, state, html_url}'
```

- **Pre-post verification (MUST):** before this call, re-read each selected finding's file at `HEAD_SHA`, confirm the evidence is at the cited line (correct silently if it drifted, drop if absent), and confirm the PR is still OPEN and not CONFLICTING (`gh pr view "$PR_NUMBER" --json state,mergeable`). Don't post on a merged/closed/conflicting PR.
- **Q2:** "Submit verb? approve / comment / request-changes / skip." Self-review offers only `comment` / `skip` (GitHub rejects approve/request-changes from the author). On `skip`, leave it PENDING. Otherwise:

```bash
gh api -X POST /repos/$REPO/pulls/$PR_NUMBER/reviews/$REVIEW_ID/events -f event=<APPROVE|COMMENT|REQUEST_CHANGES>
```

Never fabricate URLs; use the `html_url` the API returns.

## Step 7: Capture and wrap up

- Persist each POSTED blocking/non-blocking finding as a project memory fact (`type: project`, tag it a review gotcha, `anchors:` to the file), deduping against existing memory first. Skip suggestions/nitpicks/thoughts and anything not posted.
- If non-self-review and the PR has unaddressed review threads, offer to run `/address-pr-comments $PR_NUMBER`.
- Final message: one line per outcome (pending review id + count, or submitted verb + timestamp).

## Anti-patterns to refuse

1. Presenting a padded review: dedup, merge, and drop per Step 4, but never hide a surviving finding from the user in Step 5.
2. APPROVE when the swarm didn't actually run. Zero findings from a broken swarm is INCONCLUSIVE, not LGTM.
3. Auto-submitting without the two-question orchestration.
4. Posting findings in the review body instead of inline.
5. Fabricated evidence, line numbers, or URLs. Verify against the file at HEAD; use API-returned URLs.
