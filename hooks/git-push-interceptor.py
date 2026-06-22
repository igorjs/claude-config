#!/usr/bin/env python3
"""PreToolUse hook: run git-push-guard sanitization before any `git push`.

Uses shlex to tokenize commands, respecting quote boundaries. Detects:
  - direct `git push`
  - chained / piped / sub-shelled invocations
  - wrapped invocations: `rtk git push`, `env FOO=bar git push`, `nohup git push`
  - nested invocations: `bash -c "git push"`, `eval "git push"`
  - cwd shifts: `cd X && git push`, chained `cd`, `git -C X push`, `pushd X`

Does NOT inspect external script contents (e.g. `./deploy.sh`) — script
internals are out of scope.
"""
from __future__ import annotations
import json
import os
import shlex
import subprocess
import sys
from pathlib import Path

WRAPPER = Path.home() / ".claude" / "hooks" / "git-push-guard" / "git-push-guard"

# Transparent wrapper commands: their first non-flag argument is the actual command
WRAPPERS = {
    "rtk", "env", "nohup", "time", "nice", "caffeinate", "command",
    "exec", "proxychains", "proxychains4", "stdbuf", "unbuffer",
}

# Shell wrappers whose `-c <string>` argument should be recursively parsed
SHELL_WRAPPERS = {"bash", "sh", "zsh", "ash", "dash"}

# Eval-like commands: parse their joined arguments as a nested command
EVAL_LIKE = {"eval"}

# git flags that consume a following positional token as their value
GIT_FLAGS_WITH_VALUE = {
    "-C", "-c", "--git-dir", "--work-tree", "--namespace",
    "--super-prefix", "--exec-path",
}

# Shell command separators (treat as pipeline boundaries)
COMMAND_SEPARATORS = {";", "&&", "||", "|", "&", "\n", "(", ")"}


def tokenize(command: str):
    """Return shlex tokens, respecting quotes. None on parse error."""
    try:
        lex = shlex.shlex(command, posix=True, punctuation_chars=True)
        lex.whitespace_split = True
        return list(lex)
    except ValueError:
        return None


def split_into_commands(tokens):
    """Yield argv lists for each command in the pipeline."""
    current = []
    for tok in tokens:
        if tok in COMMAND_SEPARATORS:
            if current:
                yield current
                current = []
        else:
            current.append(tok)
    if current:
        yield current


def _is_env_assignment(tok: str) -> bool:
    """True if tok looks like FOO=bar or FOO_BAR=baz (env var prefix)."""
    if "=" not in tok:
        return False
    name = tok.split("=", 1)[0]
    if not name:
        return False
    return all(c.isalnum() or c == "_" for c in name) and not name[0].isdigit()


def strip_prefix(argv):
    """Drop leading env assignments and transparent wrapper commands."""
    i = 0
    while i < len(argv):
        if _is_env_assignment(argv[i]):
            i += 1
            continue
        if argv[i] in WRAPPERS:
            i += 1
            continue
        break
    return argv[i:]


def is_git_push_argv(argv) -> bool:
    """True if argv (after prefix stripping) is `git ... push ...`."""
    argv = strip_prefix(argv)
    if len(argv) < 2 or argv[0] != "git":
        return False
    i = 1
    while i < len(argv):
        tok = argv[i]
        if tok == "push":
            return True
        if tok.startswith("-"):
            if tok in GIT_FLAGS_WITH_VALUE and i + 1 < len(argv):
                i += 2
            else:
                i += 1
        else:
            # First non-flag, non-push token = some other subcommand
            return False
    return False


def is_git_push_anywhere(command: str) -> bool:
    """Top-level detector including bash -c / eval recursion."""
    tokens = tokenize(command)
    if tokens is None:
        return False
    for argv in split_into_commands(tokens):
        if is_git_push_argv(argv):
            return True
        stripped = strip_prefix(argv)
        if not stripped:
            continue
        # bash -c "<inner>" / sh -c "<inner>"
        if stripped[0] in SHELL_WRAPPERS:
            for j, tok in enumerate(stripped):
                if tok == "-c" and j + 1 < len(stripped):
                    if is_git_push_anywhere(stripped[j + 1]):
                        return True
                    break
        # eval "<inner>"
        if stripped[0] in EVAL_LIKE and len(stripped) > 1:
            if is_git_push_anywhere(" ".join(stripped[1:])):
                return True
    return False


def _resolve_path(path: str, base: str) -> str:
    path = os.path.expanduser(path)
    if os.path.isabs(path):
        return path
    return os.path.normpath(os.path.join(base, path))


def resolve_cwd(command: str, default_cwd: str) -> str:
    """Walk commands in order, tracking cd / pushd / git -C, returning the
    cwd active at the moment we first encounter a git push.
    """
    tokens = tokenize(command)
    if tokens is None:
        return default_cwd
    cwd = default_cwd
    for argv in split_into_commands(tokens):
        if is_git_push_argv(argv):
            stripped = strip_prefix(argv)
            # git -C <path> overrides for this command only
            if stripped and stripped[0] == "git":
                for k, tok in enumerate(stripped):
                    if tok == "-C" and k + 1 < len(stripped):
                        return _resolve_path(stripped[k + 1], cwd)
            return cwd
        stripped = strip_prefix(argv)
        if not stripped:
            continue
        if stripped[0] in ("cd", "pushd") and len(stripped) >= 2:
            cwd = _resolve_path(stripped[1], cwd)
    return cwd


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return 0
    command = payload.get("tool_input", {}).get("command", "")
    if not command:
        return 0
    if not is_git_push_anywhere(command):
        return 0

    # Avoid recursion if the wrapper itself is being invoked
    if "git-push-guard" in command:
        return 0

    cwd = resolve_cwd(command, os.getcwd())
    if not os.path.isdir(cwd):
        return 0  # let the push fail naturally

    result = subprocess.run(
        [str(WRAPPER), "--rewrite-only"],
        cwd=cwd,
        capture_output=True,
        text=True,
    )
    if result.returncode == 0:
        return 0

    reason = (result.stderr or result.stdout or "").strip() or "sanitization failed"
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": (
                "git-push-guard sanitization failed; push aborted.\n" + reason
            ),
        }
    }))
    return 0


if __name__ == "__main__":
    sys.exit(main())
