---
description: Interview-driven planning session with deep requirements gathering that produces a verified implementation plan.
allowed-tools: Bash, Read, Grep, Glob, Write, Task
argument-hint: "[topic | ./prompt.md] [--auto] [--help]"
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

OPTIONS:
  --auto   Autonomous: skip the interview, self-answer every decision with the
           recommended answer (recorded as assumptions), run the quality gate,
           and save the plan without pauses. Stops after saving; run /implement.
  --help   Show this help

Asks one question at a time with a recommended answer. Explores the codebase
and both memory stores (global ~/.claude/memory/ + project .claude/memory/, plus graph.json from /learn-project) to answer
questions itself before asking you. Walks decision trees, runs a 3-phase
quality gate, and produces a verified, self-contained plan broken into small
Work Units (some flagged parallel-safe) that you can run with /implement (or
the superpowers:executing-plans skill).
```

## Core Rules (MUST)

**Autonomous mode (`--auto`) replaces the interview.** When `--auto` is set, ask the user nothing: resolve every branch yourself by taking the answer you'd otherwise recommend, record it in an **Assumptions** list, and run straight through to saving the plan without the Step 3 and Step 6 confirmation pauses. Rules 4 and 6 still hold (walk the full decision tree; never write code), and the quality gate (Step 5) still runs. See **Autonomous Mode (`--auto`)** below. The rules below otherwise describe the default interactive mode.

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

**When a file path is provided, the file IS the context (MUST).** Do NOT explore the repo beyond what the file explicitly references. Skip the general repo exploration in Step 1 (no git log, no TODO scan, no manifest scan), but STILL read both memory stores (global `~/.claude/memory/` and the project `.claude/memory/`) — memory is always consulted. Beyond memory, read ONLY the file, then go straight to your first question based on its content. If the file references specific source files, modules, or APIs by name, you may read those, but do NOT go looking for things the file does not mention.

**Ignore `.gitignore`d files (MUST).** Don't read files matched by `.gitignore` (PDFs, build artefacts, binaries, vendor dirs, `.env`), even if the prompt file mentions them. Only read tracked source files.

## Autonomous Mode (`--auto`)

Enable when `--auto` appears in the arguments; strip it (like `--help`) before resolving the topic seed. `--auto` runs the entire scope without the interview, then stops after saving the plan — it never writes code (run `/implement` to build it). Concretely:

- **No questions.** For every decision Step 2 would ask, take the answer you would have recommended ("I'd recommend X because Y") and proceed. Still do the Step 1 research first — explore the codebase and both memory stores, since a preference or convention there may override your default choice.
- **Record assumptions.** Every self-made decision goes into an **Assumptions** list with its rationale, so the user can audit what was chosen for them. When you're genuinely split on a decision, record it as an `OPEN` assumption (with the leading option and why) rather than silently picking.
- **Skip the confirmation gates.** Do not pause at Step 3 ("Does this capture everything?") or Step 6 ("Does this plan look right?"). Fold the Design Summary and the Assumptions list into the saved plan instead.
- **Quality gate still runs (Step 5).** It needs no user input. If a phase still FAILs after its 3 iterations, STOP: do not save; report the failing checks and the assumptions made. No user is present to override a FAIL in `--auto`.
- **Save and report (Step 7).** On a passing gate, save the plan and quality report, persist the accepted decisions as memory, then tell the user the paths, the assumptions made (flag any `OPEN` ones), and to run `/implement` when ready.

## How It Works

### Step 1: Initial Context Gathering

**Skip this step if a file path was provided** (see Argument Resolution), EXCEPT still read both memory stores (the first bullet below) — memory is always consulted. Then go to Step 2 with the file content as your context.

With a plain-text topic seed, silently research before asking anything:

- Read BOTH memory stores (per the system prompt's Memory section): the global store `~/.claude/memory/MEMORY.md` (cross-project preferences, corrections, conventions) and, if present, the project store `.claude/memory/MEMORY.md` plus its `graph.json` (built by `/learn-project`). Load the relevant fact files from each. This is the durable knowledge: architecture, conventions, decisions, gotchas. Honor the typed edges; when a project fact contradicts a global one it wins for this repo, and surface any conflict bearing on the plan rather than silently choosing.
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

**In `--auto`:** gather the same context but ask nothing — go straight to Step 2 and self-resolve the decision tree, recording each choice as an assumption.

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

Ask: **"Does this capture everything? Anything to change?"** Do NOT proceed until confirmed. **In `--auto`, skip this gate:** fold the summary and the Assumptions list into the plan and proceed.

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

### Deliverables (Work Units)
Smallest independently-committable units, in dependency order. One WU = one small commit.
| WU | Title | Files | Requires | Parallel group | Done When |
|----|-------|-------|----------|----------------|-----------|
| WU-0 | [title] | path/to/types.ts | none | none | [observable acceptance] |
| WU-1 | [title] | path/to/a.ts, path/to/a.test.ts | WU-0 | P1 | ... |
| WU-2 | [title] | path/to/b.ts, path/to/b.test.ts | WU-0 | P1 | ... |
| WU-3 | [title] | path/to/index.ts | WU-1, WU-2 | none | ... |

### Parallel Groups
- **P1** (after WU-0): WU-1 and WU-2. Disjoint files, no shared state, safe to run concurrently by separate agents.
- **Sequential:** WU-0 first; WU-3 last (needs WU-1 and WU-2).

### Per-Work-Unit Detail
For each WU, in dependency order:

#### WU-N: [title]
- **Requires:** [WU-x, WU-y | nothing]
- **Files:** [exact paths, production + test]
- **Changes:** [concrete what-to-do]
- **Test scenarios:** [Gherkin Given/When/Then or TDD cycles this WU satisfies]
- **Done When:**
  - [ ] [observable acceptance criterion]

### Testing Strategy
- [What to test, which test files, what assertions]
```

The Testing Strategy MUST follow the `engineering-standards` skill (test types, isolation, TDD red/green/refactor, no coverage decrease).

**Work Unit sizing (MUST).** Each WU is one coherent commit: small enough to review on its own, following the `engineering-standards` size limits and incremental-delivery guidance. Prefer more, smaller WUs over a few large ones; `/implement` commits each separately. The `Files` column lists production and test files. The `Requires` column is the dependency edge `/implement` topologically orders and cycle-checks.

**Parallel-safety (MUST mark explicitly).** Assign a shared `Parallel group` label only when every member of the group:
1. has no dependency on another member (none appears in another's `Requires`),
2. touches a disjoint set of files (no file in two members), and
3. shares no mutable runtime state and no ordering-sensitive step (e.g. sequential DB migrations).

If any condition fails, leave the WUs ungrouped (they run sequentially). When unsure, leave sequential: a wrong parallel flag makes `/implement` run concurrent agents over the same files and corrupt the working tree. `/implement` re-verifies the flags before dispatching, but the plan should not assert parallelism it can't justify.

### Step 5: Quality Gate (MUST)

After producing the plan, run the three-phase gate. Do NOT skip it. Do NOT ask the user to verify it. Do NOT proceed to Step 6 until it passes. The criteria are inline below; spawn one agent per phase, sequentially, via the Task tool.

#### Phase 1: Fact-Check

Spawn an **Explore** agent (`subagent_type: Explore`) with the full plan and these criteria. It works under the `grounding-research` discipline (cite `file:line`, structured findings, tag `[unverified]` when it can't confirm):

- Every referenced file path exists.
- Function/type signatures and imports in the plan match the real code.
- The plan is consistent with existing patterns and conventions.
- Downstream consumers of changed code are identified.
- The test infrastructure the plan assumes actually exists.
- The Work Unit dependency graph is acyclic, and each Parallel group's WUs have disjoint files with no dependency on each other (the parallel-safe flags are accurate).

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

**In `--auto`, skip this step:** there is no approval pause. After the gate passes, go straight to Step 7; a gate FAIL stops the run (Step 5) instead of prompting for an override. The rest of this step is the default interactive flow.

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
   - **In `--auto`:** also list the **Assumptions** made (especially any `OPEN` ones) so the user can audit the autonomous choices before running `/implement`.

## Adapting to Complexity

- **Simple change (1-2 files):** 3-5 questions. Don't over-interview a trivial change.
- **Medium feature (3-10 files):** 8-15 questions. Focus on integration points and edge cases.
- **Large feature (new module, architecture):** 15-25 questions. Cover dependencies, rollout, migration.
- **Bug fix:** replace design questions with diagnosis: reproduction steps, error messages, root-cause hypotheses. Still provide recommended answers.
