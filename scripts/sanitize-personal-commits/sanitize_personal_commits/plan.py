# SPDX-FileCopyrightText: 2026 Igor Santos
# SPDX-License-Identifier: MIT
"""The analysed plan, persisted between the `analyse` and `apply` stages.

`analyse` computes exactly what will change and writes it here; `apply` reads it
back and executes it verbatim. Persisting (rather than recomputing) is what makes
apply match the preview the user approved: the scattered timestamps and the
AI-generated squash messages are fixed at analyse time, not regenerated.
"""
from __future__ import annotations

import json
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Dict, List, Optional

PLAN_VERSION = 1
PLAN_FILENAME = "sanitize-personal-commits-plan.json"


@dataclass
class Plan:
    mode: str                      # "scatter" | "squash" | "noop"
    head: str                      # HEAD sha when analysed; apply refuses if it moved
    branch: str
    range_expr: str
    is_root: bool
    force: bool
    signing_ok: bool
    backup_name: str
    start_sha: str = ""            # first commit of the range; apply re-derives the range from it
    rewrite_only: bool = False     # apply rewrites/squashes but does not push
    push_args: List[str] = field(default_factory=list)
    # [sha, original_iso, subject] for every business-hours commit in range.
    violations: List[List[str]] = field(default_factory=list)
    # scatter mode: [sha, new_iso]
    rewrites: List[List[str]] = field(default_factory=list)
    # squash mode: [{run_shas: [...], target_sha: str|None, new_date: iso|None}]
    squash: List[dict] = field(default_factory=list)
    # squash mode: representative sha -> commit message
    messages: Dict[str, str] = field(default_factory=dict)
    version: int = PLAN_VERSION


def plan_path(git_dir: Path) -> Path:
    return Path(git_dir) / PLAN_FILENAME


def write_plan(git_dir: Path, plan: Plan) -> None:
    plan_path(git_dir).write_text(json.dumps(asdict(plan), indent=2))


def read_plan(git_dir: Path) -> Optional[Plan]:
    p = plan_path(git_dir)
    if not p.exists():
        return None
    data = json.loads(p.read_text())
    return Plan(**data)


def clear_plan(git_dir: Path) -> None:
    plan_path(git_dir).unlink(missing_ok=True)
