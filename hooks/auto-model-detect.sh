#!/usr/bin/env bash
# UserPromptSubmit hook: detect design/architecture intent in the prompt and
# nudge Claude (the main loop) to delegate the heavy thinking to an Opus
# subagent instead of doing it inline on Sonnet.
#
# Why not auto-switch the model? Claude Code's session model is set at session
# start (or via /model). A hook can't flip it mid-stream. But it *can* push
# Claude toward Agent(model: opus) invocations of design-oriented subagents.
. "$(dirname "$0")/lib/common.sh"

prompt="$(hi_field '.prompt')"
[[ -z "$prompt" ]] && exit 0

# Skip slash commands — those are explicit user intents, not natural prose.
case "$prompt" in
  /*) exit 0 ;;
esac

# Skip very short prompts — usually confirmations / one-word redirects.
if [[ ${#prompt} -lt 20 ]]; then
  exit 0
fi

# Word-boundary patterns. ERE, case-insensitive. Tuned for ADR / design work:
#   - explicit nouns: design, architecture, ADR, schema, tradeoff
#   - decision verbs: evaluate, compare, decide, choose between, plan, propose
#   - design-shaped questions: "should we", "how would you", "what's the best"
intent_re='(\b(design|architect|architecture|ADR|tradeoffs?|alternatives?|approach|strategy|paradigm|pattern|abstraction|refactor plan|migration|decompos|schema|modeling|data model|contract|interface design)\b|\b(evaluate|compare|brainstorm|propose|recommend|critique|review the approach|review the design)\b|\b(should we|how (would|should) (we|you|i)|what.?s the best|which (approach|design|pattern)|trade ?off|pros and cons)\b)'

if ! printf '%s' "$prompt" | grep -qE -i "$intent_re"; then
  exit 0
fi

msg="$(cat <<'MSG'
This prompt looks like design / architecture work. Your main session is on Sonnet for cost. Before reasoning inline, consider delegating to an Opus subagent — its full deliberation stays in the subagent's context, only the conclusion returns to yours.

Recommended subagents (invoke with the Agent tool, passing `model: "opus"`):
  - feature-dev:code-architect — feature/component design with codebase grounding
  - Plan — implementation planning for known-shape work
  - superpowers:brainstorming — ideation / requirements before any code

If the prompt is actually small-scope (e.g. quick choice between two named options), staying on Sonnet inline is fine. Use judgment.

Routing policy: Opus only when Sonnet wasn't enough — keep Opus under 20% of total usage. Routine/mechanical/formatting/search subagents default to Haiku (3x cheaper); escalate to Sonnet for real coding.
MSG
)"

emit_prompt_context "$msg"
exit 0
