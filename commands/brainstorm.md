---
description: Divergent discovery session that explores a raw idea, weighs approaches, and produces an approved design doc that hands off to /scope.
allowed-tools: Task, Read, Bash, Skill, Write, Edit, WebFetch
argument-hint: "[idea | PROJ-123 | ./prompt.md] [--ticket <id>] [--depth 0-2] [--adr] [--no-chain] [--help]"
model: opus
effort: xhigh
---

# Brainstorm: Divergent Discovery

Turn a raw idea into an approved design doc. Explore the problem, challenge the premise, weigh 2-3 approaches, and capture the "why" before any planning starts. This is the divergent counterpart to `/scope`: `/scope` converges a settled direction into a plan, `/brainstorm` finds the direction first.

Invoked as `/brainstorm`. The remaining arguments are an optional idea seed, ticket id, or file path.

The terminal state is a design doc plus an offer to run `/scope`. Do NOT write code, scaffold anything, or produce an implementation plan here. That's `/scope` and `/implement`.

## Help

If the arguments contain `--help`, print this and stop:

```
/brainstorm - Divergent discovery that produces a design doc

USAGE:
  /brainstorm [idea]              Start an interactive discovery session
  /brainstorm "offline mode"      Start with an idea seed
  /brainstorm PROJ-123            Pull a ticket and discover from it
  /brainstorm ./notes.md          Load the idea seed from a file

OPTIONS:
  --ticket <id>  Force ticket mode for <id> (skip seed/file detection).
  --depth <0-2>  How far to crawl ticket links: 0 ticket only, 1 direct
                 links (default), 2 one more hop. Always bounded.
  --adr        Route to /adr at the end instead of /scope (the direction
               carries a weighty architectural decision worth a formal record).
  --no-chain   Write the design doc and stop. Don't offer to run /scope.
  --help       Show this help

Asks one question at a time with a recommended answer. Given a ticket id, pulls the
ticket (description, comments, attachments, linked items) via a connected MCP or a
configured provider command, then explores the codebase in parallel before asking
you. Proposes 2-3 approaches, captures the decision in .claude/designs/<date>-<slug>.md,
then offers to chain into /scope (which reads the doc and skips what it already settled).
```

## Core Rules (MUST)

1. **Do NOT write code or an implementation plan.** The output is a design doc. Detailed file lists, Work Units, and test strategy belong to `/scope`.
2. **Ask ONE question at a time.** One question, a recommended answer, wait, then the next. The only exception is the first message, where you present context and the first question together.
3. **Explore before asking.** If the codebase settles a question, resolve it yourself and report what you found. Only ask about intent, constraints, and preferences the code can't answer.
4. **Challenge the premise.** Don't accept the framing at face value. Ask whether this is the right problem, whether a simpler direction meets the goal, and what "done" actually looks like.
5. **Present a design and get approval before writing the doc.** Hard gate, every time, even for a small idea. The design can be a few sentences, but you MUST present it and get a yes.

## Argument Resolution

Resolve the argument in this order:

1. **Ticket:** if `--ticket <id>` is set, or the argument matches a ticket key (`[A-Z][A-Z0-9]+-\d+`, e.g. `PROJ-123`) or a known tracker URL (Jira, Linear, GitHub issue), treat it as a ticket and go to Step 1.5 to pull it. `--ticket` forces ticket mode even for an ambiguous value.
2. **File path:** if it starts with `./`, `../`, `/`, or `~`, or ends with `.md`, `.txt`, `.yaml`, `.yml`, check whether it exists with the Read tool. If it exists, read it and use it as the idea seed; if not, treat it as a plain-text seed.
3. **Plain text:** otherwise the argument is the idea seed.
4. **No argument:** ask what we're exploring before anything else.

Strip `--ticket <id>`, `--depth <n>`, `--adr`, and `--no-chain` (like `--help`) before resolving the seed. Don't read `.gitignore`d files even if the seed or ticket mentions them.

## How It Works

### Step 0: Load skills

Load `writing-style` (voice, banned words, no dashes; the design doc and every question follow it) and `grounding-research` (cite `file:line`, tag `[unverified]` when you can't confirm; governs the context digest and any self-answering).

### Step 1: Frame the idea and check scope

Restate the idea in one or two sentences so we agree on what we're exploring.

**Scope check (MUST).** If the idea is several independent subsystems (e.g. "a platform with chat, billing, and analytics"), stop and flag it. Help decompose into independent pieces, name how they relate and what order to build them, then brainstorm the first piece through the normal flow. Don't design a tangle.

### Step 1.5: Pull the ticket (ticket mode only)

Run this only when Argument Resolution found a ticket. Skip it entirely for a plain idea or file seed.

**Connect (layered).** Find a way to reach the tracker, in order:

1. **MCP:** search for a connected ticket tool (`ToolSearch` for Jira, Linear, Atlassian, or issue tools). If one is connected, use it.
2. **Provider command:** else look for a configured fetch command. Read `.claude/brainstorm.config` (or the repo's existing tracker config) for a per-tracker command with an `{id}` placeholder, for example `jira issue view {id} --raw` or `linear issue {id} --json`, and run it with Bash. A public tracker URL with no auth can be read with `WebFetch`. A page that needs auth or JavaScript rendering that `WebFetch` can't handle can be opened with the `agent-browser` MCP, if it's connected: `open` the url, then `snapshot` for the accessibility tree and `screenshot` for visual content.
3. **Neither:** stop and tell the user how to connect one (an MCP server or a provider command), then offer to continue with the ticket id as a plain-text seed. Do NOT fabricate ticket contents.

**Crawl (bounded, never infinite).** Gather, then stop:

- The ticket itself: title, description, status, and comments.
- Attachments: read images visually and PDFs or docs as pages. For an attachment the tracker exposes only as a web link, open it with the `agent-browser` MCP (if connected) and `snapshot` or `screenshot` it. Note and skip binaries and anything the tracker doesn't expose.
- One hop of direct links: linked issues, sub-tasks, parent epic, and linked PRs. `--depth` controls this (0 = ticket only, 1 = direct links (default), 2 = one more hop). Clamp `--depth` to the range 0 to 2, so the crawl is never unbounded.
- Bounds: cap total related items at about 15, dedup visited tickets by id, and stop early when a hop adds nothing new.

**Discover in parallel.** Fan out discovery agents over the gathered sources (issue the Task calls in one message so they run at once, per Step 2): the ticket body plus comments, batches of linked items, and the attachments. Each returns a short cited summary (the source id or url, and the facts that bear on the work). These feed the Step 2 digest alongside the codebase exploration.

The ticket's title and description become the idea seed for Step 1's framing. Record the ticket id and link so Step 7 can note them in the design doc.

### Step 2: Explore context in parallel

Fan out `Explore` agents to map what the dialogue needs. **Dispatch them in parallel: issue all the Task calls in a single message so they run at once.** Read-only exploration has no shared state, so parallel is always the default here.

Scale the fan-out to the idea: one agent for a tiny change, up to about four for a broad feature. Give each a distinct area, for example:

- Existing patterns and prior art for this kind of change.
- Integration points and the consumers a change would touch.
- Constraints: config, conventions, and anything in the code that limits the options.

Consolidate the returns into a short cited digest (a few bullets, each with `file:line`). This grounds the questions that follow so you ask about intent, not about facts the code already holds. In ticket mode, fold the Step 1.5 ticket findings into the same digest, citing the source id or url for those.

### Step 3: Interactive discovery

Ask questions one at a time, each with a recommended answer and reasoning, each following from the last. Cover:

- **Purpose:** why this, why now? What breaks or stays broken without it?
- **Success criteria:** what does "done" look like, observably?
- **Constraints:** technical, product, or time limits that rule options in or out.
- **Non-goals:** what this explicitly won't do.

Between questions, explore further if an answer opens a new area, and report what you found before the next question.

Scale the depth: 2-4 questions for a small idea, more for a broad one. Don't over-interview a simple thing.

### Step 4: Propose approaches

Present 2-3 distinct approaches with their trade-offs. Lead with your recommendation and say why. Keep each approach to what matters: what it does, its main cost, and what it rules out. Let the user pick or push back.

### Step 5: Route check

Look at the chosen direction. If it hides a weighty, hard-to-reverse architectural decision (a data model, a public contract, a cross-cutting dependency), flag it and offer `/adr` for the deep record: **"This carries an architectural call worth a formal record. Route to /adr for that decision? I'd recommend yes because it's hard to reverse."** Otherwise the handoff target is `/scope`. `--adr` forces the `/adr` route.

### Step 6: Present the design

Present the design in sections scaled to complexity: a few sentences where it's straightforward, more where it's nuanced. Cover the problem, the chosen approach, the key components and their boundaries, the main risks, and what's out of scope. Ask after each section whether it looks right. Revise until the user approves. Do NOT write the doc before approval.

### Step 7: Write the design doc

On approval, save to `.claude/designs/<YYYY-MM-DD>-<slug>.md`. First time in this repo, create the dir and ignore it (same pattern as `/scope`'s plans):

```bash
ROOT=$(git rev-parse --show-toplevel)
mkdir -p "$ROOT/.claude/designs"
grep -qxF '.claude/designs/' "$ROOT/.gitignore" 2>/dev/null || printf '.claude/designs/\n' >> "$ROOT/.gitignore"
```

Structure:

```markdown
# <title>

Date: <YYYY-MM-DD>
Status: Approved (design), pending planning
Ticket: <id and link, if ticket mode; omit otherwise>

## Problem
<why, success criteria, non-goals>

## Context
<cited digest: code file:line from Step 2, and ticket sources from Step 1.5 if any>

## Approaches considered
<2-3, trade-offs, which was chosen>

## Decision
<the chosen approach and why, with rejection notes for the others>

## Components and boundaries
<the units and their interfaces, kept light; /scope does the detailed Work Units>

## Risks and open questions
<what's flagged but accepted, and what /scope still needs to decide>

## Routing note
<-> /adr for <decision>, or -> /scope>
```

Save the file. Don't auto-commit.

### Step 8: Self-review

Look at the doc with fresh eyes and fix inline:

- **Placeholders:** any TBD, TODO, or vague requirement? Fill it.
- **Consistency:** do the sections agree? Does the Decision match the Problem?
- **Scope:** is this focused enough for one plan, or does it need decomposition?
- **Ambiguity:** could a requirement read two ways? Pick one and make it explicit.

### Step 9: Human review gate

Tell the user: **"Design doc written to `<path>`. Give it a read and tell me if you want changes before we plan."** Wait. If they request changes, make them and re-run Step 8.

### Step 10: Handoff

Once approved, unless `--no-chain`:

- **`/scope` route:** ask **"Run `/scope` now? It'll read the design doc and skip what we already settled."** On yes, invoke `/scope` pointed at the doc path.
- **`/adr` route** (from Step 5 or `--adr`): ask **"Run `/adr` now to record that decision?"** On yes, invoke `/adr` with the doc as context.

With `--no-chain`, print the doc path and the suggested next command, then stop.
