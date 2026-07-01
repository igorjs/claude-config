---
description: Create architecture decision records (ADRs) with an optional execution blueprint, fact-checked through a 3-phase quality gate and saved to .claude/adr/.
allowed-tools: Bash, Read, Grep, Glob, Write, Task
argument-hint: "<topic> [--record-only] [--list] [--help]"
model: opus
effort: xhigh
---

# ADR: Decision Records with Execution Blueprints

Create a formal Architecture Decision Record (ADR) with an optional execution blueprint: an archivable decision record paired with an actionable implementation plan. The blueprint is its implementation plan.

Invoked as `/adr`. The remaining arguments are the topic and flags.

## Defaults

No external config; these are fixed:

- **Document:** Architecture Decision Record (ADR).
- **Directory:** `.claude/adr/`, git-ignored, created on first use (same pattern as memory and plans).
- **Filename:** `NNNN-{YYYYMMDD}-{kebab-title}.md` (zero-padded sequence + today's date + kebab title).
- **Companion files:** blueprint at `{base}-blueprint.md`, quality report at `{base}-quality.md`, same directory.

## Help

If the arguments contain `--help`, print this and stop:

```
/adr - Architecture Decision Records with execution blueprints

USAGE:
  /adr <topic> [options]

OPTIONS:
  --help         Show this help
  --record-only  Write the decision record without an execution blueprint
  --list         List existing ADRs in .claude/adr/

NOTE: every ADR should have a companion execution blueprint. Use --record-only
only when the blueprint comes in a follow-up session.

EXAMPLES:
  /adr "replace polling with WebSocket push"
  /adr "split monolith order service"
  /adr --record-only "deprecate v1 API"
  /adr --list

Records save to .claude/adr/ (git-ignored) as NNNN-{YYYYMMDD}-{kebab}.md.
```

## Execution Rules (MUST)

1. **Execute every bash block for real.** Don't simulate, summarise, or predict output; use the actual output to drive the next step.
2. **No caching.** Every invocation is a fresh run. Don't reuse results from prior conversations or training data.
3. **No skipping.** Execute steps in order. The only exception: steps guarded by a flag the user didn't set.
4. **No assumptions.** Don't guess file contents, command output, or environment state. Run the command and read the result.
5. **Follow the command's gates, not your own.** If a step says "ask the user", ask. If it doesn't, don't add a confirmation gate.
6. **Show real data.** Tables and reports are populated from actual command output, never placeholders.

## Flag Handling

- `--list`: list existing records in `.claude/adr/` (filenames + titles). If none exist, say so. Then stop.
- `--record-only`: run Stages 1-2 but skip the execution blueprint.

If no flags match, run the full workflow with the remaining text as the topic.

## Step 0: Load Writing Discipline (MUST, before any drafting)

Invoke the `writing-style` skill (voice, banned words, prose rules) and the `grounding-research` skill (evidence and citations). Every ADR title, context line, alternative, and rejection note MUST follow them. ADR-specific rules on top:

- **Data over opinion.** Support claims with file paths, metrics, query counts, or concrete scenarios.
- **Spartan and informative.** Every sentence adds information. Cut sentences that only add emphasis.

## Stage 1: Investigate (mandatory)

Build understanding before writing. Skipping this produces records that don't survive contact with the codebase.

1. **Read existing records** in `.claude/adr/` (if it exists) for precedent and numbering.
2. **Explore the codebase** with Read/Glob/Grep: modules and services affected by the topic, database schemas and migration history (if relevant), test patterns, configuration and deployment.
3. **Read memory stores if present** (optional enhancement, not required): if `~/.claude/memory/MEMORY.md` exists, read it for cross-project preferences, corrections, and conventions. If `.claude/memory/MEMORY.md` exists, read it plus its `graph.json` (from `/learn-project`) for project-level decisions, conventions, gotchas, and patterns. Load the relevant fact files from each store that is present. Use what you find to inform Considered Alternatives (reference a named pattern where one applies) and to avoid re-proposing something already rejected. If both stores are present: a project fact that contradicts a global one wins for this repo; surface any conflict bearing on the decision rather than silently choosing. If no memory store is present, skip this step silently and proceed on the codebase alone.
4. **Summarise findings to the user:** what's relevant to the topic, which areas are affected, existing patterns/constraints, and applicable patterns from memory if a memory store was present (with brief rationale).

**Knowledge capture:** if a project memory store is present at `.claude/memory/`, write any durable convention or gotcha revealed by exploration as a project memory fact now. If no memory store is present, skip this step silently.

Wait for the user to acknowledge before Stage 2.

## Stage 2: Draft

### Determine the filename

```bash
ROOT=$(git rev-parse --show-toplevel)
DIR="$ROOT/.claude/adr"
mkdir -p "$DIR"
grep -qxF '.claude/adr/' "$ROOT/.gitignore" 2>/dev/null || printf '.claude/adr/\n' >> "$ROOT/.gitignore"
N=$(ls "$DIR" 2>/dev/null | grep -oE '^[0-9]{4}' | sort -rn | head -1)
NEXT=$(printf '%04d' $(( 10#${N:-0} + 1 )))
echo "Next number: $NEXT   Date: $(date +%Y%m%d)"
```

Filename: `{NEXT}-{YYYYMMDD}-{kebab-title}.md` in `$DIR`. Write the record directly there (never to a temp/local scratch path).

### Decision Record

Write `{DIR}/{filename}` with Status **Proposed**, using this structure:

```markdown
# ADR-{NNNN}: {Title}

- **Status:** Proposed
- **Date created:** {YYYY-MM-DD}
- **Date modified:** {YYYY-MM-DD}

## Context
{Evidence-grounded background: file paths, metrics, concrete observations from Stage 1.}

## Decision Drivers
- {driver referencing concrete evidence}

## Considered Alternatives
### {Alternative} (effort: S | M | L | XL)
- {how it works}
- Trade-offs: {pros and cons}

## Decision
{The chosen alternative and why. State explicitly why each other alternative was rejected.}

## Consequences
- {positive, negative, and follow-up consequences}

## Architecture Diagrams
{Mermaid: a current-state diagram and a proposed-state diagram, plus sequence/state/ER diagrams as warranted.}
```

Requirements:

- At least 2 alternatives beyond the status quo (3 total minimum), each with a genuine effort estimate (S/M/L/XL) and real trade-offs.
- Decision drivers reference concrete evidence from Stage 1.
- The Decision section gives the reasoning for rejecting each alternative.
- **Diagrams:** keep them readable, label nodes meaningfully, pick the right type (flowchart for components, sequence for interactions, state for lifecycles, ER for schemas). Always include current-state and proposed-state.

**Knowledge capture:** if a project memory store is present at `.claude/memory/`, record the decision and each rejected alternative as memory facts (so future planning, including `/scope`, doesn't re-propose them). If no memory store is present, skip this step silently.

Present the draft. Revise in place on feedback. Repeat until the user explicitly approves.

### Execution Blueprint (skip if `--record-only`)

After the record is approved, write `{DIR}/{base}-blueprint.md` (`{base}` = filename without extension):

```markdown
# {ADR-NNNN} Execution Blueprint

- **Parent ADR:** {path to the decision record}

## System Snapshot
{Real paths discovered in Stage 1: modules, entry points, schemas, tests.}

## Work Units
### WU-0: {name}
- Requires: {WU-x, WU-y | nothing}
- Goal: {independently verifiable outcome}
- Files: {real path | action | purpose} (production + test)
- Verification: {literal, runnable command(s)}
- Tests: {Gherkin scenarios or TDD cycles, per engineering-standards}
- Done When:
  - [ ] {observable acceptance criterion}

## Ordering
| WU | Requires | Parallel group |
|---|---|---|
| WU-0 | none | none |
| WU-1 | WU-0 | P1 |
| WU-2 | WU-0 | P1 |

## Parallel Groups
- P1 (after WU-0): WU-1 and WU-2. Disjoint files, no shared state, safe to run concurrently by separate agents.
- Sequential: WU-0 first.

## Dependency Graph
{Mermaid graph generated from the Ordering table.}
```

Requirements: each work unit independently verifiable and committable as one small unit; file plans reference real existing paths; verification commands are literal (no placeholders); the Ordering table shows each WU's `Requires` and `Parallel group`; the test plan follows `engineering-standards`. Mark a shared `Parallel group` only when its members have no dependency on each other, touch disjoint files, and share no mutable state or ordering-sensitive step; otherwise leave them sequential. `/implement` consumes this blueprint exactly like a `/scope` plan: one small commit per WU, parallel-safe WUs dispatched to concurrent agents.

Present the blueprint. Revise in place until the user explicitly approves.

## Stage 3: Quality Gate (MUST)

After the user approves all drafts, run the three-phase gate before finalising. Don't skip it; don't finalise until it passes or the user explicitly overrides. Criteria are inline. Run Phase 1 first (Phases 2 and 3 read its report), then dispatch Phase 2 and Phase 3 in parallel: issue both Task calls in a single message so they run at once. Phase 2 and Phase 3 are independent, so they never run one at a time; the 1-before-(2,3) order is the only real dependency.

### Phase 1: Fact-Check

Spawn an **Explore** agent (`subagent_type: Explore`) with the record (and blueprint, if any), working under the `grounding-research` discipline (cite `file:line`, tag `[unverified]`). It verifies: file paths in the system snapshot and file plans exist; function/type signatures referenced are accurate; the plan is consistent with existing patterns; the work unit dependency graph is acyclic and each Parallel group's WUs have disjoint files with no dependency on each other; if a memory store was loaded in Stage 1, known gotchas related to the topic are accounted for. Returns a PASS/FAIL/WARN report. After it returns, if a project memory store is present at `.claude/memory/`, persist any durable gotcha as a memory fact; otherwise skip that step silently. **FAIL → revise and re-run (max 3).**

### Phase 2: Adversarial Review

Spawn a **general-purpose** agent with the record, blueprint, and the Phase 1 report. It challenges the decision: simpler alternatives, scope creep, over-engineering, missing error paths, blast radius, contradictions with the fact-check. After it returns, if a project memory store is present at `.claude/memory/`, record any rejected simpler alternative (with reasoning) as a memory fact; otherwise skip that step silently. **FAIL → revise and re-run (max 3).**

### Phase 3: Test Review

Spawn an **Explore** agent with the blueprint's test plan and the Phase 1 report (it runs in parallel with Phase 2). For a `--record-only` ADR with no blueprint tests, this is typically `PASS: N/A (no test plan)`. For a blueprint with Gherkin scenarios or TDD cycles, evaluate them against `engineering-standards`: regression-pinning, flakiness, boundary coverage, test independence, mock quality, assertion strength. **FAIL → revise the test plan and re-run (max 3).**

### Structural Checks

- [ ] Every Considered Alternatives entry has effort and trade-off detail.
- [ ] The Decision section explains why each rejected alternative was rejected.
- [ ] All work units (if a blueprint exists) have file plans with real paths.
- [ ] All verification commands are literal (no `<placeholders>`).
- [ ] No unresolved questions remain (or each is explicitly deferred to a named work unit).

### Gate Result

Present the result. FAILs block finalisation; WARNs are informational. If the user explicitly overrides a FAIL, record the override in the quality report file: `Quality gate override: proceeding despite FAIL on <check> because <reason>`.

```
## Quality Gate Result

**Fact-Check:**        PASS (N/N)
**Adversarial Review:** PASS (N/N)
**Test Review:**       PASS (N/N)  [or N/A]
[or: BLOCKED: N FAILs, M WARNs]
```

## Stage 4: Finalise

After the gate passes (or is overridden):

1. **Update the record:** Status Proposed → Accepted, and bump Date modified to today.
2. **Verify the blueprint** (if any): its Parent ADR reference points to the correct record path.
3. **Save the quality report** to `{DIR}/{base}-quality.md`.
4. **Refresh the memory graph:** if a project memory store is present at `.claude/memory/` and you wrote any memory facts for this decision, rebuild the project `graph.json` with `/learn-project --graph-only` so it stays current. If no memory store is present, skip this step silently.
5. **Report** the final file paths to the user.

### Kebab Title Convention

Lowercase all words, replace spaces and special characters with hyphens, collapse consecutive hyphens. "Replace Polling with WebSocket Push" → `replace-polling-with-websocket-push`.

## Implementing the Blueprint

The blueprint is a self-contained implementation plan. Implement it with `/implement {DIR}/{base}-blueprint.md` (or the `superpowers:executing-plans` skill while it's in use).
