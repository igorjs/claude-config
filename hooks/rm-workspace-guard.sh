#!/usr/bin/env bash
set -euo pipefail

CMD=$(jq -r '.tool_input.command // ""' -)
[[ -z "$CMD" ]] && exit 0

WORKSPACE="$HOME/Workspace"
CLAUDE_DIR="$HOME/.claude"

is_allowed() {
  local path="${1/#\~/$HOME}"
  [[ "$path" != /* ]] && path="$(pwd)/$path"
  [[ "$path" == "$WORKSPACE" || "$path" == "$WORKSPACE/"* ]] && return 0
  [[ "$path" == "$CLAUDE_DIR" || "$path" == "$CLAUDE_DIR/"* ]] && return 0
  return 1
}

in_rm=false
outside=()
IFS=' ' read -ra tokens <<< "$CMD"

for token in "${tokens[@]}"; do
  [[ -z "$token" ]] && continue
  if [[ "$token" == "rm" || "$token" == */rm ]]; then
    in_rm=true; continue
  fi
  if [[ "$token" == ";" || "$token" == "&&" || "$token" == "||" || "$token" == "|" || "$token" == "&" ]]; then
    in_rm=false; continue
  fi
  if [[ "$in_rm" == true ]]; then
    [[ "$token" == -* ]] && continue
    is_allowed "$token" || outside+=("$token")
  fi
done

if (( ${#outside[@]} > 0 )); then
  joined=$(IFS=', '; echo "${outside[*]}")
  jq -n --arg r "rm blocked: $joined is outside ~/Workspace/** and ~/.claude/**" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
fi
