# SPDX-FileCopyrightText: 2026 Igor Santos
# SPDX-License-Identifier: MIT
from __future__ import annotations

import os
import subprocess
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional, Tuple

from .planner import Commit, SquashGroup

# The well-known SHA of git's empty tree, used as the base when a squashed run
# starts at the root commit (no parent).
EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"


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


def is_pushed(repo: Path, sha: str) -> bool:
    """True if `sha` is already an ancestor of the branch's upstream, i.e.
    rewriting it would require a force-push. False when there is no upstream."""
    try:
        upstream = get_upstream(repo)
    except NoUpstreamError:
        return False
    r = _git(repo, "merge-base", "--is-ancestor", sha, upstream, check=False)
    return r.returncode == 0


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


def _build_commits(repo: Path, *, local_email: str, range_expr: str) -> List[Commit]:
    fmt = "%H%x00%cI%x00%ae%x00%P"
    r = _git(repo, "log", "--reverse", f"--pretty={fmt}", range_expr)
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


def list_unpushed_commits(repo: Path, *, local_email: str) -> List[Commit]:
    upstream = get_upstream(repo)
    return _build_commits(repo, local_email=local_email, range_expr=f"{upstream}..HEAD")


def list_all_commits(repo: Path, *, local_email: str) -> List[Commit]:
    """Every commit reachable from HEAD, oldest first. Used by --all mode to
    sanitize already-pushed history when the repo is solely the local author's."""
    return _build_commits(repo, local_email=local_email, range_expr="HEAD")


def create_backup_branch(repo: Path, name: str) -> str:
    """Point a new branch at current HEAD so the pre-rewrite commits stay
    reachable (and recoverable) after filter-branch moves the working ref."""
    r = _git(repo, "branch", name, "HEAD", check=False)
    if r.returncode != 0:
        raise RewriteError(f"could not create backup branch {name}: {r.stderr.strip()}")
    return name


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
    range_expr: str | None = None,
) -> None:
    """Rewrite committer+author dates for the given SHAs via filter-branch.

    `range_expr` bounds the filter-branch rev-list. Defaults to `@{u}..HEAD`
    (unpushed only); `--all` mode passes `HEAD` to rewrite the full history.
    Only commits listed in `rewrites` are modified; others pass through
    unchanged. If `sign` is True, every commit in the rewritten range is
    re-signed.
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
    # Every other (passthrough) commit keeps its committer date but has its author
    # date normalized to match it. Without this, a commit whose author date differs
    # from its committer date (e.g. from an amend) keeps a stale author date that
    # can fall before a rewritten ancestor, inverting the author timeline that
    # `git log` displays.
    env_filter = (
        "case $GIT_COMMIT in\n"
        + "\n".join(cases)
        + '\n    *) export GIT_AUTHOR_DATE="$GIT_COMMITTER_DATE" ;;'
        + "\n  esac"
    )

    cmd = [
        "git", "-C", str(repo), "filter-branch", "-f",
        "--env-filter", env_filter,
    ]
    if sign:
        cmd.extend(["--commit-filter", 'git commit-tree -S "$@"'])

    if range_expr is None:
        range_expr = f"{get_upstream(repo)}..HEAD"
    cmd.append(range_expr)

    env = {**os.environ, "FILTER_BRANCH_SQUELCH_WARNING": "1"}
    r = subprocess.run(cmd, capture_output=True, text=True, env=env)
    if r.returncode != 0:
        # Best-effort restore
        subprocess.run(
            ["git", "-C", str(repo), "reset", "--hard", "ORIG_HEAD"],
            capture_output=True, check=False,
        )
        raise RewriteError(f"filter-branch failed: {r.stderr or r.stdout}")


def git_dir(repo: Path) -> Path:
    """Absolute path to the repo's git directory (handles worktrees/submodules)."""
    return Path(_git(repo, "rev-parse", "--absolute-git-dir").stdout.strip())


def working_tree_dirty(repo: Path) -> bool:
    """True if the working tree or index has changes (tracked or untracked).

    `git filter-branch` refuses to run against a dirty tree, so scatter-mode apply
    must check this first."""
    r = _git(repo, "status", "--porcelain", check=False)
    return bool(r.stdout.strip())


def parent_sha(repo: Path, sha: str) -> Optional[str]:
    """First-parent SHA of ``sha``, or None if it is a root commit."""
    r = _git(repo, "rev-parse", "--verify", "--quiet", f"{sha}^", check=False)
    out = r.stdout.strip()
    return out or None


def commit_subject(repo: Path, sha: str) -> str:
    """The subject line (first line) of a commit's message."""
    return _git(repo, "show", "-s", "--format=%s", sha).stdout.strip()


def commit_message(repo: Path, sha: str) -> str:
    """The full message (subject + body) of a commit, trailing newline stripped."""
    return _commit_meta(repo, sha)["message"]


def _commit_meta(repo: Path, sha: str) -> Dict[str, str]:
    """Tree SHA, author/committer identity + dates, and full message for a commit."""
    fmt = "%T%n%an%n%ae%n%aI%n%cn%n%ce%n%cI"
    head = _git(repo, "show", "-s", f"--format={fmt}", sha).stdout.split("\n")
    body = _git(repo, "log", "-1", "--format=%B", sha).stdout
    # Strip the single trailing newline git appends to %B; keep internal newlines.
    if body.endswith("\n"):
        body = body[:-1]
    return {
        "tree": head[0],
        "an": head[1],
        "ae": head[2],
        "aI": head[3],
        "cn": head[4],
        "ce": head[5],
        "cI": head[6],
        "message": body,
    }


def diff_shortstat(repo: Path, base: Optional[str], rep: str) -> str:
    """One-line `--shortstat` summary of base..rep (empty tree when base is None)."""
    base_ref = base if base is not None else EMPTY_TREE
    r = _git(repo, "diff", "--shortstat", base_ref, rep, check=False)
    return r.stdout.strip()


def _commit_tree(
    repo: Path,
    *,
    tree: str,
    parent: Optional[str],
    author: Tuple[str, str, str],
    committer: Tuple[str, str, str],
    message: str,
    sign: bool,
) -> str:
    """Create a commit object via plumbing and return its SHA."""
    args = ["git", "-C", str(repo), "commit-tree", tree]
    if parent is not None:
        args += ["-p", parent]
    if sign:
        args += ["-S"]
    env = {
        **os.environ,
        "GIT_AUTHOR_NAME": author[0],
        "GIT_AUTHOR_EMAIL": author[1],
        "GIT_AUTHOR_DATE": author[2],
        "GIT_COMMITTER_NAME": committer[0],
        "GIT_COMMITTER_EMAIL": committer[1],
        "GIT_COMMITTER_DATE": committer[2],
    }
    r = subprocess.run(args, input=message, capture_output=True, text=True, env=env)
    if r.returncode != 0:
        raise RewriteError(f"commit-tree failed: {r.stderr or r.stdout}")
    return r.stdout.strip()


def squash_rebuild(
    repo: Path,
    *,
    range_commits: List[Commit],
    groups: List[SquashGroup],
    messages: Dict[str, str],
    sign: bool,
) -> str:
    """Rebuild ``range_commits`` with each SquashGroup collapsed, via commit-tree.

    Folding groups drop their run members and re-emit the target commit (its tree,
    identity and date preserved) with the combined ``messages[target_sha]``.
    Synthesizing groups drop all-but-last run members and emit one commit using the
    last member's tree, the group's ``new_date``, and ``messages[run_shas[-1]]``.
    All other commits pass through re-parented (and re-signed when ``sign``).

    Returns the new HEAD SHA and moves the current branch (and working tree) to it.
    """
    orig_tree = _git(repo, "rev-parse", "HEAD^{tree}").stdout.strip()

    drop: set = set()
    fold_by_target: Dict[str, SquashGroup] = {}
    synth_by_last: Dict[str, SquashGroup] = {}
    for g in groups:
        if g.target_sha is not None:
            drop.update(g.run_shas)
            fold_by_target[g.target_sha] = g
        else:
            drop.update(g.run_shas[:-1])
            synth_by_last[g.run_shas[-1]] = g

    new_parent = parent_sha(repo, range_commits[0].sha)

    for c in range_commits:
        sha = c.sha
        if sha in drop:
            continue
        meta = _commit_meta(repo, sha)

        if sha in fold_by_target:
            message = messages[sha]
            committer = (meta["cn"], meta["ce"], meta["cI"])
        elif sha in synth_by_last:
            g = synth_by_last[sha]
            message = messages[sha]
            iso = g.new_date.isoformat()
            committer = (meta["cn"], meta["ce"], iso)
        else:
            message = meta["message"]
            committer = (meta["cn"], meta["ce"], meta["cI"])

        # Author date mirrors the committer date so the author timeline (what
        # `git log` shows) stays monotonic even for amended passthrough commits.
        author = (meta["an"], meta["ae"], committer[2])

        new_parent = _commit_tree(
            repo,
            tree=meta["tree"],
            parent=new_parent,
            author=author,
            committer=committer,
            message=message,
            sign=sign,
        )

    if new_parent is None:
        raise RewriteError("squash rebuild produced no commits")

    # Safety invariant: collapsing commits must never change the final content.
    new_tree = _git(repo, "rev-parse", f"{new_parent}^{{tree}}").stdout.strip()
    if new_tree != orig_tree:
        raise RewriteError(
            "squash would change the working-tree content (tree mismatch); aborted "
            "without moving the branch"
        )

    # --soft moves the branch ref only, leaving the index and working tree intact
    # (the tree is provably identical), so any uncommitted changes are preserved.
    reset = _git(repo, "reset", "--soft", new_parent, check=False)
    if reset.returncode != 0:
        raise RewriteError(f"could not move branch to rebuilt history: {reset.stderr}")
    return new_parent
