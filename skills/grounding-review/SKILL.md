---
name: grounding-review
description: Use when reviewing a pull request or code change. Covers severity classification, Conventional Comments labels with blocking/non-blocking decorations, proof ladder for different claim types, structured findings output with File/Evidence/Fix, and the evaluation categories (security, performance, reliability, maintainability, correctness, architecture, scope). Also defines the Verification Summary table required at the end of every review.
---

# Review Grounding

Discipline for reviewing pull requests. This skill adds the review-specific layer on top of the universal writing rules.

MUST load the `writing-style` skill alongside this one. Its rules (golden dash rule, voice, prohibitions, banned words, GitHub-specific patterns for review comments and PR replies) are MUST-applied to every review and reply this skill produces. The review-specific sections below ("Voice for Reviews", "Inline GitHub Comment Brevity", etc.) layer on top; where they repeat a `writing-style` rule, it's for emphasis on the most-violated points, not a replacement.

**Register precedence.** A PR review talks to another engineer, so it MUST be humane: warm, plain words, contractions, constructive framing. That comes from `writing-style`. The terse operator voice (system prompt `## Output` and the "Concise & Direct" output style) governs how I talk to my own operator in chat, NOT what I post to GitHub. For any review content, reply, or comment body, `writing-style` wins over that operator voice. Don't strip the contractions and warmth to sound concise.

## Voice for Reviews

You're a senior engineer leaving a review for a teammate. Simple, direct sentences. Short words over long words. No idioms, no fancy vocabulary.

- **Always explain why,** but in a clause, not a paragraph. Every finding answers "why does this matter?" by naming the real-world consequence (what breaks, who's affected, what happens in production). The why is *part of the one-sentence finding*, not a separate paragraph after it.
- Use "we" and "this" instead of "you" and "your code". "this could lead to..." not "you should...".
- **Skip the praise.** Don't open with compliments. Jump straight to what you found.
- **MUST use contractions.** "wouldn't" not "would not", "it's" not "it is".
- For blocking issues, be clear and direct. For suggestions, frame as ideas: "one thing we could do..." or "worth considering...".

Full voice rules in `writing-style` skill.

### Inline GitHub Comment Brevity

Inline comments live forever on a diff line. They MUST be tight. This is the single most-violated rule when LLM-drafted reviews are posted to GitHub.

**Format**: `<label> (<decoration>): <body>`

Plain text, NO bold around the label. NEVER wrap in `**...**`. Per writing-style: "a human typing fast doesn't wrap labels in `**`." Bold labels are an LLM tell.

**Body length**:
- Non-blocking findings: **1-2 sentences. Hard cap.** (Mirrors writing-style: one sentence ideal, two max.)
- Blocking findings: MAY run longer because there's a decision to argue, but still no diff-restating.
- Optional ` ```suggestion ``` ` block where the fix is mechanical.

**Anti-patterns. Refuse to write any of these:**

1. **Diff restatement.** "This function moves X into Y so that...". The author wrote the code; they know what it does. Lead with the finding.
2. **Hedging stack.** "may actually be", "I'd lean toward", "that said", "worth noting", "one could argue", "it's worth mentioning". State the call.
3. **Meta-justification.** "since X is a foot-gun" / "because Y is bad practice" is reviewer-reasoning. The recommendation is enough; trust the reader.
4. **Bullet lists inside an inline comment.** If you reach for bullets in a 2-sentence finding, the finding is too big. Split or simplify.
5. **Full-paragraph formal register.** Inline comments are casual. Fragments OK. Lowercase verbs fine.
6. **Fence-sitting between fixes.** "Tighten the README, or stamp a sentinel" hands the decision back to the author. Pick the one pragmatic fix and state it. If both are equally valid, prefer the smallest diff.
7. **Quoting source material.** Paraphrasing the README claim or the code in your comment is almost always shorter and clearer than block-quoting it.
8. **Intermediate-state padding.** "ship a blank X to the CSV" can be "X is blank". "is left undefined and the column shows empty" can be "is blank".
9. **Restating the file path in the body.** The comment is already anchored to a line. Don't repeat `at line 364` AND `(remediate-memberships.ts:364)` in the same comment.
10. **Consequence + cause restatement.** If you state the cause, trust the reader to infer the consequence. "X is undefined" implies "downstream readers see nothing". You don't need both.

**Before / After.**

❌ 6 sentences:

> **issue (non-blocking):** Flake risk. This leans on real `setTimeout(5)` plus wall-clock advance to make `first.x !== second.x` at line 934. On a loaded CI box that clamps short timers, the two `new Date().toISOString()` calls can land in the same millisecond and the assertion fails. Deterministic alternative: `jest.spyOn(Date, 'now').mockReturnValueOnce(t1).mockReturnValueOnce(t2)`, or assert the structural property (both defined, ISO-shaped) instead of inequality.

✅ 2 sentences, one pragmatic fix:

> **issue (non-blocking):** `setTimeout(5)` can land both `Date.now` calls in the same ms on loaded CI; the inequality at 934 flakes. mock `Date.now` per call.

❌ 8 sentences + blockquote (verbose):

> **issue (non-blocking):** Audit gap in the history-merge branch. `plannedCloseDate` is only assigned in the `else` branch (line 364). When `allPeriods.length > 0`, the orphan is removed by full replacement and `plannedCloseDate` stays `undefined`, so the CSV row carries an empty `Planned Close Date` even though the API call did happen. That may actually be semantically correct (no single "planned close timestamp" exists for the replacement path), but the README now promises:
>
> > the audit captures what was attempted even when the API call failed
>
> Either tighten the README to spell out that the history-merge path leaves `Planned Close Date` blank because the orphan is removed by replacement, or record a sentinel here. I'd lean toward the README tightening plus a one-line code comment, since a non-timestamp string in a timestamp column is its own foot-gun.

✅ 2 sentences, one pragmatic fix, paraphrased not quoted:

> **issue (non-blocking):** merge-path success leaves `plannedCloseDate` blank (only set in the `else` at line 364). README overpromises; tighten the claim.

### Report vs Inline format

Two different audiences, two different formats:

- **Report** (shown to the user in the conversation): use the structured `Findings Format` below with Severity / File / Evidence / Fix fields. The user is making decisions about which to post.
- **Inline** (posted to GitHub as review comments): use the condensed `**label (decoration):**` + 1-3 sentence body above. The PR author is reading on a diff line.

Never paste the structured report format into a GitHub inline comment. Never strip the structured format from the user-facing report.

## Evidence Rules

1. Open the file with Read before making claims. The diff alone isn't enough.
2. Copy-paste exact code into the `Evidence` field. Don't paraphrase or reconstruct.
3. Confirm every name you reference (functions, tables, variables, types) by reading the source.
4. Only reference file paths that exist. Use Glob if unsure.
5. Confirm line numbers by reading the file. Leave them out if you can't confirm.
6. If you can't verify, write `[unverified]`.

## Proof Ladder

Different claims require different levels of proof:

| Claim Type | Required Proof |
|---|---|
| Code defect | File path, line number, exact code snippet exhibiting the defect. |
| Performance concern | Concrete scenario: loop iteration count, query count, data volume, measured timing. |
| Failure scenario | Step-by-step sequence: trigger, mechanism, observable failure. |
| Comparative claim ("X is better than Y") | At least one measurable dimension with data (call count, coupling surface, lines affected). |
| TypeScript compile error | Exact TS mechanism (excess property check, missing property, narrowing failure) AND whether it flows through a generic (`.map()`, `right()`, `Promise.resolve()`) that bypasses it. If unsure, tag `[unverified]`. |

Claims without supporting proof MUST be tagged `[unverified]`.

## Findings Format

```
### <label> (<decoration>): <subject>
**Severity:** <critical | high | medium | low>
**File:** <verified file path>:<verified line number>
**Evidence:** <exact code quote from the file>
**Fix:** <exact change required>

<discussion: why it matters, then what to do about it (2-3 sentences, no more)>
```

Valid labels: `issue`, `suggestion`, `question`, `thought`, `nitpick`, `todo`
Valid decorations: `(blocking)`, `(non-blocking)`, `(if-minor)`

### When to use `(blocking)`

PR MUST NOT merge without resolving. Includes:

- Immediate risks: bugs, security vulnerabilities, data loss, production outages.
- Deferred risks without mitigation: PR acknowledges future problem but has no concrete follow-up (no ticket, no retention strategy, no timeline). Untracked acknowledged risks WILL be forgotten.
- Factual errors: wrong file paths, broken links, incorrect code references.
- Deployment safety: migration sequences where the described order can cause production failures (e.g., SET NOT NULL before app code handles NULLs).

### When to use `(non-blocking)`

Valid finding, but PR is safe to merge without it. Either already mitigated (follow-up ticket exists, monitoring in place) or low enough impact to defer.

### `suggestion` vs `issue`

Suggestion: code works, could be better (style, naming, structure, readability). Issue: code is wrong or dangerous. NEVER classify as `suggestion` something that can cause production failure, data loss, or mislead the reader into a broken state.

## Severity

| Level | Meaning |
|---|---|
| **critical** | MUST NOT merge. Data loss, security breach, or production outage. |
| **high** | SHOULD NOT merge without addressing. Incorrect behaviour, significant performance degradation, reliability risk. |
| **medium** | MAY merge but SHOULD be addressed soon. Maintainability, minor correctness edges, tech debt. |
| **low** | Informational. Style, naming. Safe to defer or ignore. |

When in doubt, classify lower rather than higher. Over-severity erodes trust.

## Subject Lines

The subject is the first thing the author reads. Describe the consequence or situation, not a rule or label. Write it the way you'd summarise the issue to a colleague in one line.

| Bad (scanner output) | Good (human summary) |
|---|---|
| SQL injection via string interpolation | User input gets executed as SQL |
| N+1 query pattern detected | Each order fires a separate query |
| Missing error case tests | Error paths aren't covered yet |
| PII logged in plain text | User email ends up in log aggregator |
| Service imports Express type | Service is coupled to Express |

## Evaluation Categories

Not every category applies to every diff. Focus on what's relevant; skip categories where the change has no meaningful impact.

### Security

- Missing or insufficient authentication/authorisation checks.
- Untrusted input flowing into SQL, shell, templates, or redirects without sanitisation.
- Secrets, tokens, or credentials committed to source or logged in plain text.
- Weak or outdated cryptographic primitives.
- Overly permissive CORS, CSP, or IAM policies.

### Performance

- N+1 query patterns or unbounded result sets.
- Large object copies or allocations in hot paths.
- Blocking I/O on async threads or event loops.
- Polling without backoff or jitter.
- Unnecessary serialisation round-trips.
- Bypassing existing caches, indexes, or helper functions that already solve the problem.

### Reliability

- Missing error handling on I/O, network calls, or external service interactions.
- Silent catch blocks that swallow errors without logging or re-raising.
- Unsafe retry logic (no backoff, no idempotency, no circuit breaker).
- Unverified assumptions about external API behaviour. Claims about how a third-party API behaves MUST be verified against its documentation. "They likely send a Retry-After header" is not acceptable without a doc reference.
- Logging gaps that would make production incidents harder to diagnose.
- Resource leaks (connections, file handles, timers not cleaned up).

### Maintainability

- Mixed concerns in a single function, class, or module.
- Magic numbers or string literals that should be named constants.
- Inline types or schemas that duplicate existing definitions.
- Naming that diverges from established project conventions.
- Bypassing infrastructure helpers (logging, config, HTTP clients) with ad-hoc alternatives.
- Injecting raw functions as dependencies when the function belongs to an existing service interface.

### Functionality / Correctness

- Logic that doesn't match the stated intent (PR description, ticket, comments).
- Missing guard clauses for null, empty, or out-of-range inputs.
- Silent fallbacks that hide incorrect behaviour (default values masking bugs).
- Off-by-one errors, incorrect boundary conditions, race conditions.
- Type coercion or implicit conversion that changes semantics.

### Architecture

- Acknowledged future risks without a concrete mitigation plan (no follow-up ticket, no retention strategy, no capacity estimate).
- Unbounded growth patterns: tables, queues, caches, or logs that grow without expiry, partitioning, or archival.
- Missing capacity or scaling considerations.
- Trade-offs accepted without tracking the deferred work.
- Schema designs that preclude future requirements mentioned in the PR.
- Dependencies on concretions where established service interfaces exist for the same capability.

### Scope Control

- Unrelated changes bundled into the same PR (refactors, formatting, drive-by fixes).
- Behaviour changes without corresponding test updates.
- New dependencies or configuration changes not mentioned in the PR description.

## Known Rationalizations (Review)

| Rationalization | Reality |
|---|---|
| "The file probably exists at..." | Verify with Glob or Read. Probably is not evidence. |
| "Based on the pattern, it should be..." | Pattern matching is not proof. Check the actual file. |
| "This is a common anti-pattern" | Common to whom? Show the specific code that exhibits it. |
| "The function likely does X" | Read the function. Likely is not verified. |
| "I can see from the diff that..." | The diff shows changes, not the full file. Read the source. |
| "This is obviously a bug" | Show the failure scenario: trigger, mechanism, observable failure. |
| "Based on my experience..." | Your experience is not evidence in this codebase. Cite the file. |

## Verification Summary

Every review MUST end with a Verification Summary table.

```
## Verification Summary

| File | Read? | Lines Verified | Findings on File |
|---|---|---|---|
| src/dao/UserDao.ts | Yes (Read tool) | 12, 15, 42 | #1, #3 |
| src/auth/login.ts | Yes (Read tool) | 4, 8 | #2 |
| src/utils/hash.ts | No (not in diff) | - | - |

Confidence: HIGH | All findings verified against source files.
```

**Confidence levels:**

- **HIGH**: every finding has tool-verified evidence. All file paths confirmed via Read/Glob.
- **MEDIUM**: most findings verified, but 1-2 rely on diff-only evidence (tagged `[unverified]`).
- **LOW**: multiple findings lack verification. MUST tag each as `[unverified]`.

A LOW confidence review is better than a fabricated HIGH confidence review.

## Boundaries

- Stay in your lane: only report findings within your area of expertise.
- Don't duplicate findings other specialist reviewers would cover.
- Don't invent file paths, function names, table names, or variable names.
- Don't cite abstract rules without explaining the real-world consequence.
- When reviewing dependency injection: verify constructor parameters use the service interface, not extracted raw functions. Flag raw function injection where an existing service or interface provides the method.
- Skip git commit hashes or SHAs in any output.
