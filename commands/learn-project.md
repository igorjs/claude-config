---
description: Deeply learn the current project (git history, PRs, JIRA, Confluence), store distilled topics in the memory system (routed per-project vs global), and export a navigable graph.json of the memory graph.
allowed-tools: Bash, Read, Grep, Glob, Write, Task, WebFetch
argument-hint: "[--refresh] [--graph-only] [--stage] [--from-staged] [--max-prs N] [--max-commits N]"
model: opus
effort: high
---

# Learn Project

Build a durable mental model of the repo you're in and persist it as memory facts. Read broadly (code, git history, PRs, and JIRA/Confluence when reachable), distill into topics, classify each fact as repo-specific or cross-project, and write it in the memory format from the system prompt's **Memory** section. Read-only on the project: the only writes are files under `.claude/memory/` (fact files plus a `graph.json` of the memory graph) and a single `.gitignore` line.

## Argument parsing

Parse `$ARGUMENTS`:

- `--refresh` → re-derive and supersede existing learned facts instead of skipping them.
- `--graph-only` → skip Phases 1-3; rebuild the project `graph.json` from current memory (Phase 4.5), then report. Use after hand-editing facts.
- `--stage` → run collection and analysis (Phases 0-2) but don't write to the live store or ask for confirmation. Write candidate facts to `<repo>/.claude/memory/staging/` for later review, then stop. See **Staging mode**. Use for unattended or session-end runs.
- `--from-staged` → skip collection; load candidates from `<repo>/.claude/memory/staging/`, run the normal confirm-and-write flow (Phases 3-4.5), then clear the staging area.
- `--max-prs N` (default 200) and `--max-commits N` (default: all, summarized) → bound scope on large repos.
- Anything else → ignore with a one-line warning; don't abort.

## Execution rules

1. Run every bash block for real. Don't simulate.
2. Read files before asserting facts about them (grounding).
3. Combine independent bash calls into a single tool call.
4. Never edit project code or config. Writes are limited to `.claude/memory/` files and one `.gitignore` line.
5. Dispatch subagents for collection and analysis with the Task tool: issue the independent Task calls in a single message so they run in parallel. Subagents return distilled structured findings, never raw dumps.
6. No silent truncation. If you cap commits/PRs or skip a source, the final report says so.
7. Never persist secrets. Tokens, keys, or credentials seen in configs/CI must never enter a memory fact.

## Phase 0: Preflight and scope

```bash
set -e
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "error: not in a git repo" >&2; exit 1; }
cd "$ROOT"
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || { u=$(git remote get-url origin 2>/dev/null); u=${u%.git}; REPO="$(basename "$(dirname "$u")")/$(basename "$u")"; }
COMMITS=$(git rev-list --count HEAD 2>/dev/null || echo 0)
echo "Repo:    $REPO"
echo "Root:    $ROOT"
echo "Commits: $COMMITS"

# capability probes
command -v gh   >/dev/null && gh auth status >/dev/null 2>&1 && echo "gh:   ok" || echo "gh:   UNAVAILABLE (PRs skipped)"
command -v acli >/dev/null && echo "acli: present" || echo "acli: absent"

# JIRA project keys referenced in history (histogram)
echo "JIRA keys in history:"
git log --oneline -500 2>/dev/null | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | sed -E 's/-[0-9]+$//' | sort | uniq -c | sort -rn | head || true
```

Then, before collecting:

- **Atlassian access:** if `mcp__atlassian__*` tools are available in this session, use them. Else if `acli` is present and authenticated, use it. Else mark JIRA/Confluence **unavailable** and record it for the report.
- **Targets:** resolve the JIRA project key(s) from the histogram and the Confluence space from README/links. If ambiguous, ask the user once.
- **Capture:** `REPO`, `ROOT`, scope caps, and which sources are reachable. You need these in every later phase.

## Phase 1: Collect (parallel subagents)

Dispatch these collectors in parallel. Each returns a compact structured summary (tight JSON or markdown) that cites paths/refs, NOT raw command output:

- **git-history**: contributors and ownership, churn hotspots (`git log --format= --name-only | sort | uniq -c | sort -rn`), commit-message and branch conventions, tags/releases, cadence.
- **code-structure**: top-level tree, entry points, languages, build/test/lint tooling, Dockerfiles / CI-CD configs, IaC, migration dirs and ORM models, `scripts/` and Makefile targets.
- **pull-requests** (if `gh` ok): `gh pr list --state all --limit <MAX_PRS> --json number,title,labels,body,author` — recurring themes, review norms, linked JIRA keys, notable decisions.
- **jira** (if reachable): epics, active sprints/boards, components, common labels for the project key(s).
- **confluence** (if reachable): pages on setup/onboarding, architecture, runbooks, and decisions in the project space; capture titles, URLs, and key points.

## Phase 2: Analyze into topics (parallel subagents)

Feed the Phase 1 findings to one analyst per cluster. Each emits **candidate facts**, where each fact has: `title`, `body` (the fact, then Why, then How to apply), proposed `type` (`project` for repo knowledge, `reference` for external pointers), `scope` (`repo` | `global`), proposed `links` edges, and `anchors` (repo-relative code locations the fact describes: dirs, files, or `file#symbol`).

Clusters:

- architecture & module map
- conventions & patterns (design patterns adopted, build/test/lint, branching, commit/PR)
- domain glossary
- decisions & active work (ADRs from PRs/commits + JIRA epics)
- infrastructure (CI/CD, deploy, cloud, IaC)
- setup (local dev and onboarding)
- scripts & tooling
- database schemas & models
- data access patterns

Keep facts atomic: one concept per fact. Drop low-signal or self-evident facts.

## Phase 3: Classify, dedupe, plan

- **Scope routing:** default `repo`. Mark `global` only when the fact is org/account-wide and not tied to this repo (company tooling, the Atlassian instance, standards seen across repos). A repo fact that contradicts a global one wins for this repo; note it with a `contradicts` edge.
- **Dedupe:** read the existing indexes — `<repo>/.claude/memory/MEMORY.md` and `~/.claude/memory/MEMORY.md` — and the relevant fact files. If a fact already exists: skip it, unless `--refresh`, in which case update the file or write a successor carrying a `supersedes` edge. Never blind-duplicate.
- **Plan:** show the user a concise table of candidate facts (title · scope · type · new/update/supersede). Ask once: "Write these to memory?" Proceed only on yes; honor a subset selection.

## Phase 4: Write memory

Project store, first time in this repo only:

```bash
mkdir -p "$ROOT/.claude/memory"
grep -qxF '.claude/memory/' "$ROOT/.gitignore" 2>/dev/null || printf '.claude/memory/\n' >> "$ROOT/.gitignore"
```

Then write each approved fact:

- One fact per file, kebab-case name, in the chosen store (`$ROOT/.claude/memory/` or `~/.claude/memory/`).
- Frontmatter: `name`, `description` (one-line when-to-use), `type`, `links:` with bare-basename edges (`supersedes`, `depends_on`, `relates_to`, `contradicts`), and `anchors:` listing the repo-relative code locations the fact describes (`src/auth/`, `src/auth/login.py`, or `src/auth/login.py#authenticate`).
- Body: the fact, then **Why:** and **How to apply:**. Use absolute dates for anything time-bound (`date +%F`).
- In the project store, do NOT name the repo in the fact text; it's implicit.
- Add or refresh the `- [Title](file.md): one-line hook` line in the right `MEMORY.md`. Mark superseded index entries `(superseded)`.
- Write a `project-overview` fact as the entry point, linked via `relates_to` to the main topic facts.

## Phase 4.5: Build the navigation graph

Regenerate `graph.json` **colocated with the project store's `MEMORY.md`** (`<repo>/.claude/memory/graph.json`) from the project facts (skip if the project store has no facts). This graph is project-level knowledge; the global store gets no graph. Deterministic and idempotent: overwrite on each run, and sort nodes and edges by `id` so diffs stay stable.

1. Scan the project store fact files, and read any global facts referenced by their `links:` (so cross-store edges resolve).
2. **Nodes:** one `fact` node per fact (`id` = `fact:<basename>`, plus `kind`, `type`, `title`, `file`, `store`). One `code` node per distinct `anchors:` target (`id` = `code:<path>`, with `path` and an `exists` on-disk check). A global fact referenced by a project fact appears as a `fact` stub with `store: global`.
3. **Edges:** fact→fact from `links:` (resolve bare basenames to node ids; carry the edge `type`); fact→code from `anchors:` (`type: anchors`). A target that doesn't resolve is dangling: flag it in the report, don't fail (same rule as memory edges).
4. Write `graph.json` beside the project store's `MEMORY.md`:

```json
{
  "version": 1,
  "generated": "<date +%F>",
  "repo": "<REPO>",
  "nodes": [
    {"id": "fact:auth-flow", "kind": "fact", "type": "project", "title": "Auth flow", "file": "auth-flow.md", "store": "project"},
    {"id": "code:src/auth/login.py", "kind": "code", "path": "src/auth/login.py", "exists": true}
  ],
  "edges": [
    {"from": "fact:auth-flow", "to": "code:src/auth/login.py", "type": "anchors"},
    {"from": "fact:auth-flow", "to": "fact:session-model", "type": "relates_to"}
  ]
}
```

`graph.json` sits beside the project `MEMORY.md`, inside the memory store, so it's already git-ignored. With `--graph-only`, this is the only phase that runs after Phase 0.

## Staging mode (`--stage` and `--from-staged`)

These split collection from the write decision, so a run can happen unattended (for example, nudged at session end) and the human approves later. The staging area is `<repo>/.claude/memory/staging/`, inside the git-ignored memory dir.

**`--stage`** (collect now, decide later):

1. Run Phases 0-2 as normal to produce candidate facts.
2. Skip Phase 3's confirmation and Phase 4's live writes. Create `<repo>/.claude/memory/staging/` (and the one-time `.gitignore` line from Phase 4 if the store is new), then write each candidate to `<repo>/.claude/memory/staging/<kebab>.md` in the normal fact format, plus two extra frontmatter fields: `status: pending` and `staged: <date +%F>`, a `scope:` (`repo` | `global`), and, when it would update an existing fact, a `supersedes:` note.
3. Write or refresh `<repo>/.claude/memory/staging/STAGED.md` with one `- [Title](file.md): one-line hook` line per candidate.
4. Do NOT touch the live `MEMORY.md` or `graph.json`.
5. Report the count staged, the staging path, and: "Review with `/learn-project --from-staged`."

**`--from-staged`** (review and promote):

1. Skip Phases 0-2. Read every candidate in `<repo>/.claude/memory/staging/`.
2. Run Phase 3 against them: show the candidate table, dedupe against the live stores, and ask once "Write these to memory?" (honor a subset).
3. For approved candidates, run Phase 4 (write to the live store, dropping the `status`/`staged` staging fields; apply `supersedes`/updates; refresh `MEMORY.md`) and Phase 4.5 (rebuild `graph.json`).
4. Remove promoted candidates from staging. Leave any the user skipped; delete any the user rejects.
5. Report as in Phase 5.

## Phase 5: Report

One tight summary:

- Facts written / updated / superseded, per cluster and per store.
- Sources used, and **sources skipped with the reason** (e.g. "Confluence: no MCP and acli absent").
- The path to each store's `MEMORY.md`.
- The `graph.json` path, node and edge counts, and any dangling anchors or edges flagged during the build.

## Anti-patterns to refuse

1. Dumping raw `git log` / PR / JIRA output into memory. Facts are distilled, atomic, and actionable.
2. Silent skips. An unreachable source or applied cap must appear in the report.
3. Duplicating an existing fact instead of superseding or updating it.
4. Writing repo-specific detail into the global store, or cross-project facts into the project store.
5. Editing project code or config. Memory files plus one `.gitignore` line are the only writes.
6. Persisting secrets or tokens pulled from configs or CI.
7. Leaving `graph.json` stale or non-deterministic. Rebuild it whenever facts change, and sort nodes/edges so reruns produce clean diffs.
