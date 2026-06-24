---
description: Interview-driven planning session with deep requirements gathering that produces a verified implementation plan.
allowed-tools: Bash, Read, Grep, Glob, Write, Task
argument-hint: "[topic | ./prompt.md] [--help]"
model: opus
effort: xhigh
---

# Scope: Interactive Design Interview

Interview the user relentlessly about every aspect of this plan until you reach a shared understanding. Walk down each branch of the design tree, resolving dependencies between decisions one by one. The output is a verified, self-contained implementation plan, ready to run with `/implement` (or the `superpowers:executing-plans` skill while it's in use).

Invoked as `/scope`. The remaining arguments are an optional topic seed or file path.

## Help

If the arguments contain `--help`, print this and stop:

```
/scope - Interview-driven planning that produces an implementation plan

USAGE:
  /scope [topic]              Start interactive planning
  /scope "user auth system"   Start with a topic seed
  /scope ./prompt.md          Load topic seed from a file

ARGUMENTS:
  If the argument is a file path (starts with ./ or / and the file exists),
  read the file content and use it as the topic seed. Prepare detailed
  prompts in a file instead of typing them inline.

Asks one question at a time with a recommended answer. Explores the codebase
and the project's .claude/memory/ (+ graph.json from /learn-project) to answer
questions itself before asking you. Walks decision trees, runs a 3-phase
quality gate, and produces a verified, self-contained plan you can run with
/implement (or the superpowers:executing-plans skill).
```

## Core Rules (MUST)

1. **Ask ONE question at a time.** Not two, not a batch. One question, wait for the answer, then the next. The only exception: the very first message, where you present initial context and the first question.
2. **Provide your recommended answer with every question.** Format: "Question? **I'd recommend X** because Y." The user can accept, reject, or modify. This keeps the conversation moving instead of stalling on open-ended questions.
3. **If a question can be answered by exploring the codebase, explore instead of asking.** Read the files, grep for patterns, check the config and the project memory. Only ask the user about decisions, preferences, and constraints that aren't in the code.
4. **Walk the decision tree.** Each answer may open new branches. Track which branches are resolved and which are still open. Don't jump to unrelated topics while a branch has unresolved dependencies.
5. **Do NOT produce the implementation plan until all branches are resolved.** The user invoked `/scope` because they want thorough design, not a quick answer.
6. **Do NOT write any code.** This is a planning session. The output is a plan file, not implementation.

## Argument Resolution

If the argument looks like a file path (starts with `./`, `../`, `/`, or `~`, or ends with `.md`, `.txt`, `.yaml`, `.yml`), check whether the file exists with the Read tool:

- **File exists:** read its content and use it as the topic seed.
- **File does not exist:** treat the argument as a plain-text topic seed.

This happens before Step 1. The loaded content replaces the raw argument as the topic seed.

**When a file path is provided, the file IS the context (MUST).** Do NOT explore the repo beyond what the file explicitly references. Skip the general exploration in Step 1 (no git log, no TODO scan, no manifest scan, no memory scan). Read ONLY the file, then go straight to your first question based on its content. If the file references specific source files, modules, or APIs by name, you may read those, but do NOT go looking for things the file does not mention.

**Ignore `.gitignore`d files (MUST).** Don't read files matched by `.gitignore` (PDFs, build artefacts, binaries, vendor dirs, `.env`), even if the prompt file mentions them. Only read tracked source files.

## How It Works

### Step 1: Initial Context Gathering

**Skip this step if a file path was provided** (see Argument Resolution). Go straight to Step 2 with the file content as your context.

With a plain-text topic seed, silently research before asking anything:

- Read the project memory if present: `.claude/memory/MEMORY.md`, the relevant fact files, and `graph.json` (built by `/learn-project`). This is the durable project knowledge: architecture, conventions, decisions, gotchas.
- Check recent git log for context.
- If the topic seed mentions files, modules, or features, read them.
- Read the README and whatever build manifest exists (`package.json`, `pyproject.toml`, `go.mod`, `Cargo.toml`, etc.) for project context.
- Read `TODO.md` (or an equivalent) if it exists.

Then present what you found and ask the first question:

```
I looked at [what you explored] and here's what I understand so far:
- [key finding 1]
- [key finding 2]

First question: [question]? **I'd recommend [X]** because [reason from codebase].
```

### Step 2: Decision Tree Interview

Ask questions one at a time. Each question should follow from the previous answer (don't jump topics), include your recommended answer with reasoning, and resolve a specific branch.

Types of questions, in roughly this order (adapt):

- **Goal clarification:** What does "done" look like? Who is this for?
- **Scope boundaries:** What's explicitly out of scope? What should this NOT do?
- **Existing patterns:** "I found [pattern] in the codebase. Follow it or break from it? **I'd recommend following it** because [reason]."
- **Architecture decisions:** "Two approaches: A does [X] but [downside]. B does [Y] but [cost]. **I'd recommend A** because [reason]."
- **Dependencies:** "This depends on [system]. How should it interact? **I'd recommend [approach]** because I see [evidence in code]."
- **Edge cases:** "What happens when [failure scenario]? **I'd recommend [handling]** because [reason]."
- **Migration/rollout:** "How do we get from current state to the new state? **I'd recommend [strategy]** because [reason]."

Between questions, explore the codebase if the answer reveals new areas. Report what you found before asking the next question.

**Knowledge capture (memory).** When exploration reveals a durable convention or gotcha about the codebase (true regardless of this plan), persist it as a project memory fact right then, per the system prompt's Memory section: a kebab-case file in `.claude/memory/` with `name`/`description`/`type: project`/`links:`/`anchors:` (to the files), plus its `MEMORY.md` index line. Track each confirmed *plan decision* in the running plan draft; those are persisted at Step 7, not now.

### Step 3: Confirm Understanding

When all branches are resolved, summarise:

```
## Design Summary

**Goal:** [one sentence]

### Decisions Made
1. [Decision]: [what was chosen] (because [reason])
2. ...

### Out of Scope
- [what was explicitly excluded]

### Open Risks
- [anything flagged but accepted]
```

Ask: **"Does this capture everything? Anything to change?"** Do NOT proceed until confirmed.

### Step 4: Generate Implementation Plan

Produce a self-contained plan that `/implement` (or the `superpowers:executing-plans` skill) can consume directly:

```
## Implementation Plan

**Status:** Proposed | **Date:** <YYYY-MM-DD>

### Architecture
[High-level design. Reference specific files and functions found during research.]

### Files to Create/Modify
| File | Action | Purpose |
|------|--------|---------|
| path/to/file.ts | modify | [what changes and why] |
| path/to/new.ts  | create | [what it does] |

### Implementation Order
1. [Step]: [what to do] (depends on: nothing | step N)
   - Specific changes: [concrete description]
2. ...

### Testing Strategy
- [What to test, which test files, what assertions]
```

The Testing Strategy MUST follow the `engineering-standards` skill (test types, isolation, TDD red/green/refactor, no coverage decrease).

### Step 5: Quality Gate (MUST)

After producing the plan, run the three-phase gate. Do NOT skip it. Do NOT ask the user to verify it. Do NOT proceed to Step 6 until it passes. The criteria are inline below; spawn one agent per phase, sequentially, via the Task tool.

#### Phase 1: Fact-Check

Spawn an **Explore** agent (`subagent_type: Explore`) with the full plan and these criteria. It works under the `grounding-research` discipline (cite `file:line`, structured findings, tag `[unverified]` when it can't confirm):

- Every referenced file path exists.
- Function/type signatures and imports in the plan match the real code.
- The plan is consistent with existing patterns and conventions.
- Downstream consumers of changed code are identified.
- The test infrastructure the plan assumes actually exists.

Returns a structured PASS / FAIL / WARN report. **After it returns**, persist any durable gotcha it found as a memory fact. **If any FAILs:** revise the plan and re-run Phase 1 (max 3 iterations). Don't proceed until it passes.

#### Phase 2: Adversarial Review

Spawn a **general-purpose** agent with the full plan and the Phase 1 report. It challenges the design:

- Is there a simpler alternative that meets the goal?
- Scope creep or over-engineering?
- Missing error paths or failure handling?
- Blast radius: what could this break?
- Contradictions with the fact-check report.

Returns a structured report. **After it returns**, record any rejected simpler alternative (with reasoning) in the plan's Risks section. **If any FAILs:** revise and re-run Phase 2 (max 3 iterations).

#### Phase 3: Test Review

Spawn an **Explore** agent with the plan's Testing Strategy and the Phase 1-2 reports. It evaluates the proposed tests against the `engineering-standards` testing requirements:

- Regression-pinning and boundary coverage.
- Flakiness risks.
- Test independence (each test creates its own data, no shared seed).
- Mock quality (mock at the boundary; don't mock another service's tables).
- Assertion strength.

Returns a structured report. **After it returns**, persist any durable test-quality pattern as a memory fact. **If any FAILs:** revise the test plan and re-run Phase 3 (max 3 iterations).

#### Quality Gate Result

Present all three reports:

```
## Quality Gate Result

**Fact-Check:**        PASS (N/N checks passed)
**Adversarial Review:** PASS (N/N challenges passed)
**Test Review:**       PASS (N/N checks passed)
[or: BLOCKED: N FAILs, M WARNs]
```

WARNs are shown for awareness but do not block.

### Step 6: User Approval

After the gate passes, present the full plan and the gate reports. Ask:

**"Quality gate passed. Does this plan look right? Anything to change before I save it?"**

If there are WARNs, highlight them: **"Note: N warnings flagged (see report). None are blocking."**

Do NOT save until the user explicitly approves. If they request changes, revise the affected parts, re-run the quality gate (Step 5), and present again.

**Override:** if the gate has FAILs and the user says to proceed anyway, record the override in the quality report file: `Quality gate override: proceeding despite FAIL on <check> because <user's reason>`.

### Step 7: Save & Next Steps

Only after the user approves. First time in this repo, create the plans dir and ignore it (same pattern as memory):

```bash
ROOT=$(git rev-parse --show-toplevel)
mkdir -p "$ROOT/.claude/plans"
grep -qxF '.claude/plans/' "$ROOT/.gitignore" 2>/dev/null || printf '.claude/plans/\n' >> "$ROOT/.gitignore"
```

Then:

1. Save the plan to `.claude/plans/<topic-slug>.md` and the gate reports to `.claude/plans/<topic-slug>-quality.md`.
2. Persist the plan's accepted key decisions as project memory facts (`type: project`, `anchors:` to the files they touch), update `MEMORY.md`, then refresh the graph with `/learn-project --graph-only`.
3. Tell the user:
   - "Saved to `.claude/plans/<topic-slug>.md`"
   - "Implement it when ready: `/implement .claude/plans/<topic-slug>.md` (or the `superpowers:executing-plans` skill)."
   - "Want to capture the key decisions in an ADR (`/adr`)?" (if architectural)

## Adapting to Complexity

- **Simple change (1-2 files):** 3-5 questions. Don't over-interview a trivial change.
- **Medium feature (3-10 files):** 8-15 questions. Focus on integration points and edge cases.
- **Large feature (new module, architecture):** 15-25 questions. Cover dependencies, rollout, migration.
- **Bug fix:** replace design questions with diagnosis: reproduction steps, error messages, root-cause hypotheses. Still provide recommended answers.
