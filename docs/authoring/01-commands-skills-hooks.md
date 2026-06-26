# Authoring Commands, Skills, and Hooks

Three extension points let you add behavior to this config: slash commands, skills, and hooks. Each has a specific directory and a specific format. Templates below are derived from the real files.

## Slash commands

Commands live in `commands/<name>.md` and run as `/<name>` inside a session.

Frontmatter fields that appear in the existing commands:

| Field | Purpose |
|---|---|
| `description` | Short summary shown in the command picker. |
| `allowed-tools` | Comma-separated tools the command is permitted to use. |
| `effort` | Effort level: `low`, `medium`, `high`, `xhigh`. |
| `model` | Optional. Pin to a model (e.g., `opus`). Omit to inherit the session default. |
| `argument-hint` | Optional. Usage hint shown for `$ARGUMENTS`. |

The body is the instruction set Claude runs when the command is invoked. Write it as a numbered procedure or a set of rules. Reference `$ARGUMENTS` to access anything the user typed after the command name.

```markdown
---
description: One-line description of what this command does
allowed-tools: Bash, Read, Edit
effort: medium
---

# My Command

What it does and when to use it.

## Step 1

Instruction for Claude. Reference `$ARGUMENTS` here if needed.

## Step 2

Instruction for Claude.
```

`scope.md` adds `model: opus` because the planning interview needs that capability. `commit-and-push.md` omits `model` and inherits the session default. Only set `model` when the command always needs a specific model.

## Skills

Skills live in `skills/<name>/SKILL.md` and load on demand when the session decides a task matches.

The frontmatter has two fields:

| Field | Purpose |
|---|---|
| `name` | Machine identifier used to reference the skill. |
| `description` | The trigger. Claude reads this to decide whether to load the skill. |

The body is the content Claude gets when the skill loads: rules, templates, formats, decision tables. Write it as self-contained prose because the skill loads without surrounding context.

```markdown
---
name: my-skill
description: Use when doing X or Y. Covers rule-set Z.
---

# My Skill

Rules and formats go here.

## Section

- Rule one.
- Rule two.
```

The `description` field does all the targeting. Write it as a "use when..." sentence that names the task clearly. A vague description means the skill loads at the wrong time or not at all.

## Hooks

Hooks are shell scripts registered in `settings.json` under the `hooks` key. Each entry maps an event to one or more commands.

Events wired in this config: `SessionStart`, `PreToolUse`, `PostToolUse`, `UserPromptSubmit`, `PreCompact`, `Stop`, `SessionEnd`. `PreToolUse` and `PostToolUse` accept an optional `matcher` to filter by tool name (e.g., `"Bash"`, `"Read|Grep|Glob|Edit|Write|NotebookEdit"`).

**Registering a hook in `settings.json`:**

```json
"hooks": {
  "PreToolUse": [
    {
      "matcher": "Bash",
      "hooks": [
        {
          "type": "command",
          "command": "~/.claude/hooks/my-hook.sh"
        }
      ]
    }
  ]
}
```

**Input/output contract:**

Hook scripts receive a JSON payload on stdin. The `lib/common.sh` helper (sourced by every hook in this repo) provides `hi_field` for reading it:

```bash
. "$(dirname "$0")/lib/common.sh"

tool="$(hi_field '.tool_name')"              # PreToolUse: which tool fired
path="$(hi_field '.tool_input.file_path')"   # Read: the file being read
source="$(hi_field '.source')"               # SessionStart: "startup" or "resume"
```

To inject output back to Claude, write JSON to stdout:

```json
{
  "systemMessage": "Text shown to the user in the session.",
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "additionalContext": "Context injected into Claude's next turn."
  }
}
```

Use `jq -cn` to build the payload safely (the existing hooks do this). Exit 0 in all normal cases.

**Minimal hook template:**

```bash
#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Your Name
# SPDX-License-Identifier: MIT
. "$(dirname "$0")/lib/common.sh"

tool="$(hi_field '.tool_name')"

# Your logic here.

# Emit context when needed.
jq -cn --arg msg "your message" \
  '{ hookSpecificOutput: { hookEventName: "PreToolUse", additionalContext: $msg } }'

exit 0
```

Hook and settings changes take effect on a fresh session, not a resumed one. After editing `settings.json` or a hook script, run `cc fresh` (or plain `claude`). Resumed sessions run the config snapshot from their original startup; `cc` warns you when the config has drifted.

## See also

- [Internals: Launcher and Hooks](../internals/01-launcher-and-hooks.md): the hook lifecycle and launcher internals.
- [Decisions and Memory](../guides/03-decisions-and-memory.md): authoring memory facts.
- [Docs index](../index.md)
