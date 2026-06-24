# Memory Graph Protocol

Memory lives in `~/.claude/memory/`: one fact per file, indexed by `MEMORY.md`.
Facts are nodes; typed edges in frontmatter make memory a graph. Follow this
protocol whenever reading or writing memory.

## Node format

Each fact file has frontmatter (`name`, `description`, `type` where
`type ∈ {user, feedback, project, reference}`) plus a `links:` block, then the
body (rule, then `**Why:**` and `**How to apply:**` for feedback/project facts).

```yaml
---
name: prefer-no-emdash
description: Igor dislikes em-dashes in prose
type: feedback
links:
  supersedes: [old-punctuation-pref]
  depends_on: []
  relates_to: [output-style-concise]
  contradicts: []
---
```

- Edge values are **bare basenames** (no `.md`, no path). Empty arrays may be omitted.
- Only these four edge types exist: `supersedes`, `depends_on`, `relates_to`, `contradicts`.

## Edge semantics

- `supersedes` (directional, new→old): this fact replaces the target. Act only
  on the chain head; treat superseded facts as historical.
- `depends_on` (directional, fact→prerequisite): this fact holds only given the
  target. Load the target for context.
- `relates_to` (symmetric): loose association. Pull neighbors for context.
- `contradicts` (symmetric): the two facts are in tension. If both are live
  (neither superseded), surface the conflict instead of silently choosing.

## Storage & reverse links

Edges are stored once, on the authoring node. Never write back-edges
(`superseded_by`, etc.) to disk — infer them by scanning frontmatter at load
time. Memory is small (<100 files), so a full scan is cheap.

## Traversal (when loading a relevant fact)

1. Load the fact.
2. Follow `supersedes` to the head of the chain (full depth).
3. Pull `depends_on` targets (depth 1).
4. Pull `relates_to` neighbors (depth 1).
5. Check `contradicts` for live conflicts; surface any.

Default depth is 1 for everything except `supersedes` chains. No multi-hop
fan-out unless explicitly asked.

## Integrity

- An edge naming a non-existent file is a dangling edge: surface it when
  encountered; do not fail loading.
- Ignore self-edges (a file listing itself).
- `supersedes` cycles are not expected; if one is detected while following a
  chain, stop and surface it rather than looping.

## Worked example

Five facts showing every edge type:

- `prefer-no-emdash` (feedback): `supersedes: [old-punctuation-pref]`,
  `relates_to: [output-style-concise]`
- `old-punctuation-pref` (feedback): historical; reached only via the reverse
  of `prefer-no-emdash`'s supersedes edge.
- `output-style-concise` (user): no outgoing edges.
- `gd-deploy-target` (project): `depends_on: [gd-uses-aws]`
- `gd-uses-aws` (project): no outgoing edges.

Loading `prefer-no-emdash`: follow supersedes to confirm it is the head (it is),
note `old-punctuation-pref` as historical, pull `output-style-concise` as
related context. Loading `gd-deploy-target` also pulls `gd-uses-aws`.
