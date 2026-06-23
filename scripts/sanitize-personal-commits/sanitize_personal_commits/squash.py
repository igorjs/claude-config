# SPDX-FileCopyrightText: 2026 Igor Santos
# SPDX-License-Identifier: MIT
"""Build a commit message for a squashed run of commits.

The message must read like an ordinary commit describing the code changes and must
never reveal that commits were combined or that timestamps were altered — otherwise
the whole point (an unremarkable history) is lost. An AI summary is preferred; a
deterministic fallback to a real existing message keeps the engine working offline,
and a banned-word filter guarantees the no-intent rule even if the model misbehaves.
"""
from __future__ import annotations

import shutil
import subprocess
from typing import Callable, List, Optional

# Words/phrases that would betray intent. If a generated message contains any of
# these (case-insensitive), it is rejected in favour of the fallback.
_BANNED = (
    "squash",
    "squashed",
    "rebase",
    "rebased",
    "fixup",
    "combine",
    "combined",
    "merge into",
    "timestamp",
    "back-date",
    "backdate",
    "sanitize",
    "sanitise",
    "audit",
    "business hour",
    "business-hour",
    "working hour",
    "off-hours",
    "off hours",
    "after hours",
    "commit date",
    "commit time",
)

_PROMPT = """\
Write a single git commit message describing the code changes below.

Requirements:
- Output ONLY the commit message: a concise subject line (<= 72 chars, imperative
  mood), optionally followed by a blank line and a short body. No quotes, no
  preamble, no explanation of what you are doing.
- Describe the code changes as an ordinary commit would.
- NEVER mention combining or squashing commits, rebasing, fixups, editing or
  adjusting timestamps / commit dates / times / hours, business hours, auditing,
  or any tooling. None of that belongs in the message.

Original commit subjects:
{subjects}

Diff stat:
{shortstat}
"""

Summarizer = Callable[[str], Optional[str]]


def _claude_summarize(prompt: str) -> Optional[str]:
    """Ask the local `claude` CLI for a subject line. Returns None on any failure
    so the caller falls back to a real existing message."""
    exe = shutil.which("claude")
    if not exe:
        return None
    try:
        r = subprocess.run(
            [exe, "-p", prompt, "--model", "haiku"],
            capture_output=True,
            text=True,
            timeout=90,
        )
    except Exception:
        return None
    if r.returncode != 0:
        return None
    out = r.stdout.strip()
    return out or None


def _is_clean(message: str) -> bool:
    low = message.lower()
    return not any(b in low for b in _BANNED)


def build_message(
    *,
    subjects: List[str],
    shortstat: str,
    fallback: str,
    summarizer: Summarizer = _claude_summarize,
) -> str:
    """Return a commit message for the squashed set.

    Uses the summarizer's output when it is non-empty and leaks no intent;
    otherwise returns ``fallback`` (a real, existing commit message).
    """
    prompt = _PROMPT.format(
        subjects="\n".join(f"- {s}" for s in subjects) or "- (none)",
        shortstat=shortstat or "(unavailable)",
    )
    out = summarizer(prompt)
    if out:
        out = out.strip()
        if out and _is_clean(out):
            return out
    return fallback
