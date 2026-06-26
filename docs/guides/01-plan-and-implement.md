# Plan and Implement

`/scope` and `/implement` split feature work into two phases: a verified design session that produces a plan, then a delegated execution that builds it. Neither command does both jobs.

## Planning with /scope

Run `/scope` with an optional topic seed or file path:

```bash
/scope "add --json flag to export command"
/scope ./tasks/feature-brief.md
```

`/scope` runs on Opus. It interviews you one question at a time, each with a recommended answer and a reason. Before asking anything, it reads the codebase, the global memory store at `~/.claude/memory/`, and the project store at `.claude/memory/` (if present). Anything it finds there, it answers itself instead of asking you.

Each answer opens new branches. `/scope` walks them in dependency order and won't jump topics while a branch has unresolved decisions.

When all branches are resolved, it runs a three-phase quality gate:

1. **Fact-check.** An Explore subagent verifies every file path, function signature, and import in the plan. It also checks the Work Unit dependency graph for cycles and confirms parallel-safe flags are accurate.
2. **Adversarial review.** A general-purpose subagent challenges the design: simpler alternatives, missing error paths, blast radius.
3. **Test review.** An Explore subagent checks the test plan against engineering standards: boundary coverage, flakiness risks, mock quality, assertion strength.

Each phase retries up to three times on FAIL before blocking. WARNs are surfaced but don't block.

After the gate passes and you approve, `/scope` saves the plan to `.claude/plans/<slug>.md` and the quality report to `.claude/plans/<slug>-quality.md`. It also persists the key decisions as project memory facts.

### Plan structure

The saved plan is self-contained. Its core is a Work Units table: smallest independently-committable pieces in dependency order, with parallel-safe groups marked explicitly.

```
| WU | Title | Files | Requires | Parallel group | Done When |
```

`/scope` only marks a Work Unit as parallel-safe when its file set is disjoint from every sibling in the group and it has no dependency on them. When unsure, it leaves the unit sequential. `/implement` re-verifies the flags before dispatching concurrent agents.

### Autonomous mode (--auto)

```bash
/scope "add --json flag to export command" --auto
```

`--auto` skips the interview. For every decision, `/scope` takes the answer it would have recommended, records it in an Assumptions list, runs the quality gate, and saves the plan without pausing. A gate FAIL stops the run; it reports the failing checks and the assumptions made. On success, it lists all assumptions so you audit the autonomous choices before running `/implement`.

## Implementing with /implement

`/implement` is execute-only. Pass it a plan file, a GitHub issue, a Jira ticket, a file spec, or plain text:

```bash
/implement .claude/plans/add-json-flag.md
/implement #42
/implement PROJ-123
```

With no arguments, it lists saved plans to pick from. If the reference isn't a ready plan with named files, ordered steps, acceptance criteria, and a test plan, it stops and tells you to run `/scope` or `/adr` first.

### Execution

`/implement` runs on Sonnet and delegates each Work Unit to a subagent via the Task tool. The orchestrator reads the plan, dispatches the Task, and reviews the result. It doesn't edit files directly.

**Execution order.** Work Units run in dependency order. When a parallel group's dependencies are all done, `/implement` verifies the file sets are disjoint, then dispatches the group as concurrent Sonnet Tasks in one message.

**TDD by default.** Each Work Unit cycles through red/green/refactor:

1. A subagent writes failing tests encoding the Gherkin scenarios. Tests must fail.
2. A subagent writes the minimal implementation to pass. Tests must pass.
3. A subagent refactors without changing behavior. Tests stay green.

Pass `--no-tdd` to write tests and implementation together instead.

**One commit per Work Unit.** After the orchestrator reviews a completed WU, it stages exactly that WU's files and runs `/commit-and-push -y`. Each deliverable becomes its own small commit, even when WUs ran concurrently.

**After all Work Units.** `/implement` runs a refinement pass: a self quick-review plus a SOLID/DRY/KISS/YAGNI simplify analysis, folded into refinement Work Units and executed autonomously. Then an adversarial subagent reviews the full branch diff. Blocking findings get fixed and re-validated. Non-blocking ones become follow-ups.

### Autonomous mode (--auto)

```bash
/implement .claude/plans/add-json-flag.md --auto
```

`--auto` executes Work Units in dependency order without pausing, then opens a PR once the adversarial review passes. If you're on the default branch, it creates a feature branch before the first commit. A gate FAIL blocks unless you also pass `--force` (logged to the quality report).

## Worked example

Feature: add a `--json` flag to a CLI export command. After `/scope`, the plan has four Work Units:

| WU | Title | Requires | Parallel group | Done When |
|----|-------|----------|----------------|-----------|
| WU-0 | Add output format type | none | none | Type compiles |
| WU-1 | JSON formatter | WU-0 | P1 | Tests pass; formats output correctly |
| WU-2 | Refactor table formatter | WU-0 | P1 | Tests pass; no behavior change |
| WU-3 | Wire `--json` flag in CLI | WU-1, WU-2 | none | Flag routes to correct formatter |

`/implement` processes them in order:

1. **WU-0** runs first. Subagent writes the output format type, goes through red/green/refactor. One commit.
2. **WU-1 and WU-2** are both in P1, both depend only on WU-0. Once WU-0 commits, `/implement` checks their file sets are disjoint, then dispatches both as concurrent Tasks. Two commits land.
3. **WU-3** waits for WU-1 and WU-2, then wires the flag in the CLI module. One commit.
4. Full validation runs: type-check, lint, tests.
5. Refinement pass reviews the diff and collapses anything speculative.
6. Adversarial review challenges the implementation against the plan.
7. In `--auto`, a PR opens. In interactive mode, the branch is ready for `/quick-review` or `/deep-review`.

## See also

- [Decisions and Memory](03-decisions-and-memory.md): when to use `/adr` instead of `/scope`, and how both memory stores feed planning.
- [Review and PR flow](02-review-and-pr-flow.md): reviewing the branch after `/implement` finishes.
- [Docs index](../index.md)
