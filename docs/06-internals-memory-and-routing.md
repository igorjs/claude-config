# Internals: Model Routing and Memory

The session model defaults to Sonnet. Two systems shape which model handles a given task: a static policy in the system prompt, and a hook that detects design intent at prompt submission. Memory is a two-level typed graph stored in plain markdown files.

## Model Routing

The policy lives in `prompts/SYSTEM_PROMPT.md`. Three tiers:

**Sonnet** is the session default. The `cc` launcher sets it at session start and it covers most coding work.

**Haiku** is the default for spawned subagents on mechanical, formatting, or search tasks. It's 3x cheaper. Escalate to Sonnet when the subagent does real coding, and to Opus when it needs architecture.

**Opus** handles deep architectural planning only, and only when Sonnet wasn't enough. Keep Opus under 20% of total usage.

### Plan-mode routing

The system prompt directs: enter plan mode first for design work (new features, non-trivial refactors, architecture decisions). `settings.json` sets `"useAutoModeDuringPlan": true`, which puts auto mode in effect during plan mode. The system prompt states this combination routes plan mode to Opus and execution to Sonnet.

### auto-model-detect.sh

`hooks/auto-model-detect.sh` runs on every `UserPromptSubmit` event, wired in `settings.json` under the `UserPromptSubmit` hook list. It can't flip the session model mid-stream (Claude Code doesn't support that). Instead it detects design intent and injects a context message nudging Claude toward an Opus subagent.

The script skips slash commands and prompts under 20 characters. For natural-prose prompts it applies an extended-regex pattern (case-insensitive) that matches:

- Design nouns: `design`, `architecture`, `ADR`, `schema`, `tradeoffs`, `migration`, `data model`, `interface design`, and related terms.
- Decision verbs: `evaluate`, `compare`, `brainstorm`, `propose`, `critique`, `review the approach`.
- Design-shaped questions: `should we`, `how would/should we/you/I`, `what's the best`, `which approach/design/pattern`, `pros and cons`.

On a match, the hook emits a prompt context message reminding Claude the session runs on Sonnet and recommending one of two delegation paths: the `Plan` agent (via `Agent` tool with `model: "opus"`) for implementation planning with codebase grounding, or `superpowers:brainstorming` (Skill tool) for ideation before any code. For narrow prompts (a quick choice between two named options) staying inline on Sonnet is fine. No match: the hook exits silently.

## Memory Protocol

Memory is a two-level typed graph. Both levels share the same file format.

### Levels

| Level | Path | Scope | Committed to git? |
|---|---|---|---|
| Global | `~/.claude/memory/` | Cross-project | Yes, part of this repo |
| Per-project | `<repo>/.claude/memory/` | One repo only | No, git-ignored in each repo |

The project store is injected at session start. The global store's index is read on demand.

### File format

One fact per file. Filenames are kebab-case (e.g. `commits-must-be-signed.md`). Every file opens with YAML frontmatter:

```yaml
---
name: fact-name
description: one-line trigger hint for when to use this fact
type: user | feedback | project | reference
links:
  supersedes: old-fact-name
  depends_on: prerequisite-name
  relates_to: neighbor-name
  contradicts: conflicting-name
anchors:           # optional; mainly used in the project store
  - src/auth/login.py#authenticate
  - src/auth/
---
```

Edge values are bare basenames with no path and no extension. For `feedback` and `project` type facts, the body follows a fixed structure: the rule first, then a **Why:** section and a **How to apply:** section.

### Index

Each store has a `MEMORY.md` at its root. One line per fact:

```
- [Title](file.md): one-line hook
```

The index is for navigation only. Don't duplicate edge declarations here.

### Edge types

| Edge | Direction | Meaning |
|---|---|---|
| `supersedes` | new → old | The authoring fact replaces the target. Act on the chain head; treat superseded facts as historical. |
| `depends_on` | authoring → prerequisite | Load the prerequisite before acting on this fact. |
| `relates_to` | symmetric | Pull the neighbor for related context. |
| `contradicts` | symmetric | Both facts are live but conflict. Surface the conflict; don't silently choose one. |

Each edge is stored once on the authoring node. Reverse links are inferred by scanning frontmatter at load time, not stored explicitly.

Traversal depth is 1 for all edge types except `supersedes`, which is followed fully (chain head wins). A project fact that contradicts a global fact wins for that repo. Dangling basenames (the target isn't in the store) are surfaced, not dropped.

### graph.json

`/learn-project` generates `<repo>/.claude/memory/graph.json` alongside the project `MEMORY.md`. It's the navigable export of the project memory graph: nodes are facts and referenced code locations, edges are `links:` between facts plus `anchors:` from facts to code. The global store doesn't get a graph. See [Decisions and Memory](03-decisions-and-memory.md) for how to query and use it day-to-day.

## See also

- [Decisions and Memory](03-decisions-and-memory.md): using memory day-to-day and the `/learn-project` command.
- [Internals: Launcher and Hooks](05-internals-launcher-and-hooks.md): the `cc` launcher that sets the session model.
- [Docs index](index.md)
