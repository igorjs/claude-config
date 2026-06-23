from __future__ import annotations

import os
import subprocess
from datetime import datetime
from pathlib import Path
from typing import List, Tuple

from .planner import Commit


class NoUpstreamError(Exception):
    pass


class SigningNotConfiguredError(Exception):
    pass


class RewriteError(Exception):
    pass


def _git(repo: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git", "-C", str(repo), *args],
        capture_output=True,
        text=True,
        check=check,
    )


def get_upstream(repo: Path) -> str:
    r = _git(
        repo,
        "rev-parse",
        "--abbrev-ref",
        "--symbolic-full-name",
        "@{u}",
        check=False,
    )
    if r.returncode != 0:
        raise NoUpstreamError(r.stderr.strip() or "no upstream configured")
    return r.stdout.strip()


def get_local_email(repo: Path) -> str:
    return _git(repo, "config", "user.email").stdout.strip()


def _count_lines_changed(repo: Path, sha: str) -> int:
    """Sum of insertions + deletions for a commit, from --shortstat."""
    r = _git(repo, "show", "--shortstat", "--format=", sha, check=False)
    if r.returncode != 0 or not r.stdout.strip():
        return 0
    # Last non-empty line: " N files changed, X insertions(+), Y deletions(-)"
    last = [ln for ln in r.stdout.strip().split("\n") if ln.strip()][-1]
    total = 0
    for word in last.replace(",", "").split():
        if word.isdigit():
            total += int(word)
    # Subtract the "N files changed" count
    for word in last.replace(",", "").split():
        if word.isdigit():
            total -= int(word)
            break
    return max(0, total)


def list_unpushed_commits(repo: Path, *, local_email: str) -> List[Commit]:
    upstream = get_upstream(repo)
    fmt = "%H%x00%cI%x00%ae%x00%P"
    r = _git(repo, "log", "--reverse", f"--pretty={fmt}", f"{upstream}..HEAD")
    if not r.stdout.strip():
        return []
    out: List[Commit] = []
    for line in r.stdout.strip().split("\n"):
        sha, date_str, author_email, parents = line.split("\x00")
        is_merge = len(parents.split()) > 1
        is_foreign = author_email.lower() != local_email.lower()
        lines_changed = _count_lines_changed(repo, sha)
        out.append(
            Commit(
                sha=sha,
                committer_date=datetime.fromisoformat(date_str),
                lines_changed=lines_changed,
                is_merge=is_merge,
                is_foreign=is_foreign,
            )
        )
    return out


def check_signing_configured(repo: Path) -> None:
    r = _git(repo, "config", "--get", "commit.gpgsign", check=False)
    if r.stdout.strip().lower() != "true":
        raise SigningNotConfiguredError(
            "commit.gpgsign is not true — refusing to produce unsigned commits"
        )
    r = _git(repo, "config", "--get", "user.signingkey", check=False)
    if not r.stdout.strip():
        raise SigningNotConfiguredError("user.signingkey is not set")


def rewrite_dates(
    repo: Path,
    rewrites: List[Tuple[str, datetime]],
    *,
    sign: bool,
) -> None:
    """Rewrite committer+author dates for the given SHAs in @{u}..HEAD via filter-branch.

    Only commits listed in `rewrites` are modified; others pass through unchanged.
    If `sign` is True, every commit in the rewritten range is re-signed.
    """
    if not rewrites:
        return

    cases = []
    for sha, dt in rewrites:
        iso = dt.isoformat()
        cases.append(
            f'    {sha}) export GIT_AUTHOR_DATE="{iso}"; '
            f'export GIT_COMMITTER_DATE="{iso}" ;;'
        )
    env_filter = "case $GIT_COMMIT in\n" + "\n".join(cases) + "\n  esac"

    cmd = [
        "git", "-C", str(repo), "filter-branch", "-f",
        "--env-filter", env_filter,
    ]
    if sign:
        cmd.extend(["--commit-filter", 'git commit-tree -S "$@"'])

    upstream = get_upstream(repo)
    cmd.append(f"{upstream}..HEAD")

    env = {**os.environ, "FILTER_BRANCH_SQUELCH_WARNING": "1"}
    r = subprocess.run(cmd, capture_output=True, text=True, env=env)
    if r.returncode != 0:
        # Best-effort restore
        subprocess.run(
            ["git", "-C", str(repo), "reset", "--hard", "ORIG_HEAD"],
            capture_output=True, check=False,
        )
        raise RewriteError(f"filter-branch failed: {r.stderr or r.stdout}")
