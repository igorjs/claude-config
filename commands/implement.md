---
description: Execute an approved plan or ADR blueprint (from /scope or /adr) on Sonnet, delegating edits to subagents and committing each unit. Then runs one refinement pass (self quick-review + SOLID/DRY/KISS/YAGNI simplify, re-planned and executed autonomously) and an adversarial review. Execute-only; it does not design new scope.
allowed-tools: Bash, Read, Grep, Glob, Write, Edit, Task
argument-hint: "[plan | adr-blueprint | #issue | KEY-123 | ./spec.md | text] [--auto] [--no-tdd] [--force] [--help]"
model: sonnet
effort: xhigh
---

# Implement: Execute a Verified Plan

Execute an approved implementation plan or ADR blueprint. **This command is execute-only: it does NOT design or plan new scope.** Produce the plan with `/scope` (or `/adr` for an architectural decision) first, then implement it here. The one exception is the Step 8 refinement pass, which re-plans and applies behaviour-preserving cleanups to the code it just wrote (never new features).

Invoked as `/implement`. The remaining arguments are the task reference and flags.

## Help

If the arguments contain `--help`, print this and stop:

```
/implement - Execute an approved plan or ADR blueprint

USAGE:
  /implement                  List saved plans and pick one to execute
  /implement <task-reference> [options]

TASK SOURCES:
  Plan file      /implement .claude/plans/user-avatar-upload.md
  ADR blueprint  /implement .claude/adr/0001-20260625-websocket-push-blueprint.md
  GitHub issue   /implement #42   |   /implement https://github.com/org/repo/issues/42
  Jira ticket    /implement PROJ-123   (via Atlassian MCP/acli, when reachable)
  File spec      /implement ./tasks/feature-spec.md
  Plain text     /implement "Add user avatar upload"

OPTIONS:
  --help     Show this help
  --auto     Autonomous: execute Work Units in dependency order (parallel-safe ones
             concurrently), commit each, open a PR
  --no-tdd   Write tests alongside implementation instead of red/green/refactor
  --force    In --auto mode, override quality-gate FAILs (logged)

PLANNING: /implement never designs. If the reference isn't a ready plan, it
stops and tells you to run /scope or /adr first.

REFINEMENT: after implementing, /implement runs one pass (self quick-review +
SOLID/DRY/KISS/YAGNI simplify, executed autonomously) then an adversarial
review, before finishing (or opening the PR in --auto).
```

## Execution Rules (MUST)

1. **Execute every bash block for real.** Don't simulate or predict output; drive the next step from real output.
2. **No caching.** Every invocation is a fresh run. Don't reuse results from prior conversations or training data.
3. **No skipping.** Execute steps in order. The only exception: steps guarded by a flag the user didn't set.
4. **No assumptions.** Don't guess file contents, command output, or environment state. Run it and read the result.
5. **Follow the command's gates, not your own.** If a step says "ask the user", ask. If it doesn't, don't add a gate.
6. **Show real data.** Tables and reports come from actual command output, never placeholders.

## Step 1: Resolve the Task Reference

**No task reference given (empty, or only flags)?** Run the Plan Picker:

```bash
ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
found=0
for f in "$ROOT"/.claude/plans/*.md "$ROOT"/.claude/adr/*-blueprint.md; do
  [ -f "$f" ] || continue
  case "$f" in *-quality.md) continue;; esac
  found=1
  title=$(grep -m1 '^#\{1,\} ' "$f" | sed 's/^#\{1,\} *//')
  st=$(grep -m1 -iE 'status' "$f" | grep -ioE 'proposed|accepted|implemented' | head -1)
  printf '%s\t[%s]\t%s\n' "${f#"$ROOT"/}" "${st:-?}" "${title:-untitled}"
done
[ "$found" = 0 ] && echo "NO_PLANS"
```

Present the rows as a numbered menu (index, status, title, path), listing unexecuted entries (`Proposed`/`Accepted`) first and `Implemented` last. Ask the user to pick a number, or to preview one first (Read it, show the summary, then re-ask). If the output is `NO_PLANS`, stop and tell the user to run `/scope` or `/adr` to create one. Use the chosen file as the task reference, then continue below. Any flags passed (e.g. `--auto`) still apply to the chosen plan.

Otherwise, resolve `$ARGUMENTS` (minus flags) by format:

- **Plan/blueprint file** (`.claude/plans/*.md` or `.claude/adr/*-blueprint.md`, or any path ending `.md`): Read it. This is the plan.
- **GitHub issue** (`#N`, or a github.com issue URL): `gh issue view <N> --json title,body,url,labels,state`.
- **Jira ticket** (`ABC-123`): use `mcp__atlassian__*` tools if available, else `acli` if present, else ask the user to paste the ticket. (Same availability rule as `/learn-project`.)
- **Other file path:** Read it.
- **Plain text:** the text is the task statement.

If a fetch fails, ask the user to paste the task content.

## Step 2: Execute-Only Gate (MUST)

Decide whether the resolved reference is a **ready, executable plan**: it names concrete files to change, an ordered set of steps or Work Units, acceptance criteria, and a test plan (Gherkin scenarios or TDD cycles).

- A `/scope` plan or `/adr` blueprint → ready. Proceed.
- A spec/issue/ticket detailed enough (explicit files, steps, acceptance criteria, tests) → ready. Proceed.
- **Anything else** (raw text, a thin issue/ticket, a vague request) → **STOP.** Tell the user: "This isn't a ready plan. Run `/scope` (or `/adr` for an architectural decision) to produce one, then `/implement` it." Do NOT generate a plan inline; planning is `/scope` and `/adr`'s job. (The Step 8 refinement pass is the sole exception, and only to re-plan refactors of code already written, never new scope.)

## Step 3: Load Standards and Context

- Invoke the `engineering-standards` skill (testing requirements, mocking, PR readiness, deployment), the `grounding-research` skill (verify before asserting), and `writing-style` (for any prose, e.g. commit messages and the PR body).
- Read the project memory: `.claude/memory/MEMORY.md`, relevant fact files, and `graph.json` (from `/learn-project`) for conventions, gotchas, and prior decisions.
- Read every file the plan references before changing it (grounding).
- **Detect the stack** to know the verify commands: check `tsconfig.json` / `package.json` (TS/JS), `pyproject.toml` / `setup.py` (Python), `go.mod` (Go), `Cargo.toml` (Rust). Derive the type-check / lint / test commands from what you find.

**Knowledge capture:** when you discover a durable convention or gotcha, write it as a project memory fact (per the system prompt's Memory section).

## Step 4: Quality Gate (conditional)

If the plan came from `/scope` or `/adr` it already has a companion `*-quality.md` report; trust it and skip to Step 5. Otherwise (a file/issue/ticket spec), run the inlined 3-phase gate before executing:

1. **Fact-Check** (`Explore` agent, under `grounding-research`): every referenced path exists, signatures/imports match, downstream consumers identified, test infra present.
2. **Adversarial Review** (`general-purpose` agent + the fact-check report): simpler alternatives, scope creep, missing error paths, blast radius.
3. **Test Review** (`Explore` agent, under `engineering-standards`): regression-pinning, flakiness, independence, mock quality, assertion strength.

Max 3 iterations per phase; revise on FAIL. A FAIL blocks execution unless the user explicitly overrides (or `--auto --force`). Record gotchas and rejected alternatives as memory facts.

## Step 5: Execute (delegated subagents, reviewed)

**Delegation (MUST):** this command runs on Sonnet. The orchestrating session reads the plan and delegates each implementation chunk to a subagent via the Task tool (`model: "sonnet"`), then reviews the result. Delegation keeps each chunk in a fresh, isolated context (no bleed between cycles) and lets independent chunks run in parallel; the orchestrator spends its turn reviewing, not editing. The deep design reasoning already happened in `/scope` or `/adr`, so execution doesn't need Opus.

Every Task prompt MUST include: the full plan content, the specific cycle/step/Work Unit, its Gherkin scenarios, the test-structure rules below, the verify command, the design principles below, and grounding rules ("read files before modifying, match existing style, verify imports resolve, don't guess types, apply SOLID/DRY/KISS/YAGNI").

**Design principles (MUST).** Every change, and every Task prompt, applies:
- **SOLID:** one responsibility per unit, small focused interfaces, depend on abstractions only at real seams (no abstraction without a second caller).
- **DRY:** factor out genuine duplication once it recurs (rule of three); don't couple unrelated code that only looks alike.
- **KISS:** the simplest design that passes the tests and reads clearly; fewer moving parts wins.
- **YAGNI:** build only what the plan requires now. No speculative hooks, flags, config, or generality.

When SOLID's abstraction pulls against KISS/YAGNI, favour the simplest thing that meets the plan. These principles are also the lens for the refinement pass (Step 8).

**Execution unit (MUST): the plan's Work Units.** Execute one Work Unit (deliverable) at a time in dependency order; each WU becomes one small commit.

**Parallel dispatch (decide from the plan's flags).** Read the plan's `Parallel Groups`. When a group's dependencies are all complete, dispatch its WUs as concurrent subagents: issue the Task calls in a single message (multiple tool uses) so they run at once. WUs with no group, or whose dependencies aren't done yet, run one at a time. Before dispatching concurrently, VERIFY rather than trust the flags: the group's WUs must have disjoint `Files` lists and no dependency on each other. If the files overlap, or the plan has no parallel annotations (older plans), fall back to sequential; never run two agents that write the same file at once. When running concurrently, scope each WU's verify command to its own test files (the full suite runs in Step 7) so an in-progress sibling WU can't trip another's tests.

**Test structure (from `engineering-standards`):** every test follows Arrange-Act-Assert with `// Arrange` / `// Act` / `// Assert` comments mapping to the scenario's Given/When/Then; one action per test; use parameterised tests (`test.each`, `pytest.mark.parametrize`, table-driven) when scenarios share AAA structure but differ in data.

**With TDD (default).** For each cycle within a Work Unit (in dependency order):

1. **RED** - Sonnet Task: "Write ONLY the failing tests encoding this Gherkin scenario, AAA-structured. Don't touch production code." Then run the verify command: tests MUST fail (if they pass, the test proves nothing - fix it).
2. **GREEN** - Sonnet Task: "Write ONLY the minimal implementation to pass." Run verify: tests MUST pass (on failure, spawn a follow-up Task with the error output).
3. **REFACTOR** - Sonnet Task: "Clean up without changing behaviour; tests stay green." Run verify.
4. **Orchestrator review:** read the modified files; confirm changes match the plan, doc comments explain WHY, no unplanned side effects.

**Without TDD (`--no-tdd`).** For each logical file group: one Sonnet Task implements code + tests together (tests still encode the Gherkin scenarios); run verify; the orchestrator reviews as above.

**Commit after each Work Unit (MUST): small commits.** After the orchestrator review passes for a WU, stage exactly that WU's files (`git add <the WU's Files list>`), then run `/commit-and-push -y` (auto-confirmed, so it doesn't pause between units). Staging per-WU yields one small commit per deliverable even when WUs ran concurrently and their changes coexist in the working tree. Confirm the WU's files are committed afterwards (they no longer appear in `git status --porcelain`). One coherent commit per WU. If commit fails, retry once, then stop and report.

## Step 6: Autonomous Mode (`--auto`)

`--auto` executes Work Units in dependency order, committing each, then opens a PR. It commits and pushes without pausing, so:

- **Branch first.** If on the default branch, create a feature branch before any commit (never auto-commit to the default branch). Never `--no-verify`, never force-push.
- A FAIL in Step 4 blocks; `--force` overrides it (logged to the quality report).

**Cycle check (MUST, before executing).** Verify the Work Unit dependency graph is acyclic:

1. Build the adjacency list from the plan's Work Units table (`WU-N -> [Requires]`).
2. Count incoming edges per WU; seed a queue with the zero-incoming WUs.
3. Process the queue: mark each WU resolved, decrement the count of every WU it enables, enqueue any that hit zero.
4. If any WU is unresolved, those form a cycle: name them, break the cycle (extract shared logic into a new WU, merge, or reverse an edge), and re-check.

Report the result: `Cycle check: PASS (N WUs resolve in topological order)` or how a detected cycle was fixed.

**Per Work Unit (or parallel batch), in dependency order:**

1. Confirm all WUs in the "Requires" column are done.
2. If the next ready WUs share a `Parallel group` (and pass the disjoint-files verification from Step 5), dispatch them as concurrent Sonnet Tasks in one message; otherwise execute the single WU (WU-0 types first; then the RED/GREEN/REFACTOR flow per cycle, or a single Task for `--no-tdd`), delegated to Sonnet.
3. **Post-WU review:** changes match each WU's spec and file plan; doc comments explain WHY; no files outside the file plan touched.
4. Commit each WU separately: stage that WU's files, run `/commit-and-push -y`, then confirm its files are committed.
5. Mark each WU's "Done When" checkboxes in the plan file.

**Error handling:** if a WU fails (verify fails, wrong output, or commit fails) after 3 fix retries, **stop**. Don't continue to dependent WUs. Report the failed WU, the error, and the remaining WUs.

## Step 7: Validate

Run the project's checks (from Step 3 detection), e.g. type-check, lint, and tests. In `--auto`, run the full suite (not just affected) and, on failure, spawn a Sonnet Task to fix the responsible WU, then amend via `/commit-and-push -ya` (max 3 attempts; if still failing, stop and do NOT open a PR).

- Fix and re-validate until green.
- **Doc audit:** every new/modified function has a doc comment explaining WHY; add any that are missing.
- **Update status:** change the plan's `Status: Proposed` to `Status: Implemented`.
- **Memory capture:** record notable errors and their fixes as memory facts.

In `--auto`, after validation passes, continue to the refinement pass (Step 8). The PR opens at the end of Step 9, after the refinement and adversarial review pass, not here.

## Step 8: Refinement Pass (one pass, autonomous)

Once the implementation is green, run ONE refinement pass over the code you just produced. It runs autonomously (no pause, in interactive and `--auto` alike) and executes exactly once per `/implement` invocation; re-validation never re-enters this step. It refines existing code; it does NOT add new scope (YAGNI keeps `/implement` execute-only). Apply the same commit safety as Step 6: if on the default branch, create a feature branch before committing; never commit to the default branch; never force-push.

1. **Self quick-review (local).** Apply the `grounding-review` discipline to the branch diff: severity-classified findings, each with `file:line` evidence. Keep it local; don't post anything. Fix only the findings you hold with HIGH confidence (clear bug, dead code, obvious simplification). Leave low-confidence or speculative findings for the adversarial review (Step 9); don't guess.
2. **Simplify & refactor analysis.** Read the changed files through the Design principles (SOLID, DRY, KISS, YAGNI). List concrete, behaviour-preserving changes: collapse needless indirection, delete dead or speculative code, dedupe real repetition, flatten tangled control flow, tighten names. Skip anything that changes behaviour or adds abstraction with no second caller.
3. **Re-plan.** Fold the high-confidence fixes and accepted simplifications into a small set of refinement Work Units (same shape as a `/scope` plan: `Files`, `Requires`, `Done When`). Scope is limited to code already written. If a finding implies new feature work, record it as a follow-up; don't build it.
4. **Execute autonomously.** Run the refinement Work Units like `--auto`: TDD where it applies, behaviour-preserving refactors keep tests green, commit each WU with `/commit-and-push -y`. Then re-run the validation checks from Step 7 (type-check/lint/test only, not the status flip or the continue-to-Step-8 handoff); they MUST stay green.

Run this pass once. Don't loop: Step 9 is the backstop for whatever remains.

## Step 9: Adversarial Review (MUST)

This reviews the IMPLEMENTED work, not the plan: Step 4's adversarial review ran before execution against the plan; this one runs after, against the diff. Spawn an adversarial reviewer (`general-purpose` agent, under the `grounding-review` discipline) with the full branch diff, the plan, and the refinement notes. Its job is to break the work, not bless it:

- **Correctness:** bugs, off-by-one, unhandled errors, regressions the tests miss.
- **Behaviour drift:** did any simplification or refactor change observable behaviour?
- **Principles:** remaining SOLID/DRY/KISS/YAGNI violations, leftover speculative code, needless abstraction.
- **Scope:** anything built beyond the plan; anything the plan required but is missing.
- **Tests:** weak assertions, missing boundary or regression coverage, flakiness.

It returns severity-classified findings with `file:line` evidence and a fix per finding. Apply the fixes you hold with HIGH confidence plus every blocking correctness/security finding; re-run the Step 7 validation checks after applying them. Surface the rest as known follow-ups: don't silently drop them, and don't start a second refinement loop.

**Finish.** In interactive mode, report the applied fixes and unresolved follow-ups to the user; leave the PR to them. In `--auto`, once the Step 7 validation checks are green after the adversarial fixes, open the PR with `gh pr create` (title and body from the plan and commit history, in the `writing-style` voice), listing the unresolved non-blocking findings under a "Follow-ups" heading.

## Decision Rules

| Scenario | Action |
| --- | --- |
| Reference isn't a ready plan | STOP; tell the user to run `/scope` or `/adr` first (Step 2) |
| Task is ambiguous | Ask the user before executing |
| Plan needs new dependencies | List them and ask for approval (vet maintenance/license/CVEs) |
| Touches auth/security code | Flag for extra review; be conservative |
| Requires a DB migration | Execute the migration as its own unit with a rollback note |
| Validation fails | Fix and re-validate before reporting done |
| `--auto`: WU fails after 3 retries | Stop; report the failed WU and the remaining WUs |
| `--auto`: validation fails after 3 fixes (including Step 8/9 re-validations) | Stop; report; do NOT open a PR |
| `--auto`: on the default branch | Create a feature branch before the first commit |
| `--auto`: commit/push fails | Stop; report (auth, hooks, etc.) |
| Refinement (Step 8) implies new feature scope | Record as a follow-up; don't build it (YAGNI) |
| Adversarial review (Step 9) finds a blocking issue | Fix it, re-validate, then finish; report non-blocking findings as follow-ups |
| Refinement or adversarial fix would change behaviour | Don't fold it into the refactor; treat it as a separate fix and re-validate |
