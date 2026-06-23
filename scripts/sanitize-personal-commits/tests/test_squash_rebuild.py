from __future__ import annotations

import os
import subprocess
from datetime import datetime
from pathlib import Path

from sanitize_personal_commits.git_ops import (
    list_all_commits,
    parent_sha,
    squash_rebuild,
)
from sanitize_personal_commits.planner import plan_squash

SYD = "+10:00"


def _git(repo, *args, env=None):
    e = {**os.environ, **(env or {})}
    return subprocess.run(
        ["git", "-C", str(repo), *args],
        capture_output=True,
        text=True,
        env=e,
        check=True,
    )


def _commit(repo, name, when_iso, email="me@example.com"):
    (repo / f"{name}.txt").write_text(name)
    _git(repo, "add", ".")
    env = {
        "GIT_AUTHOR_EMAIL": email,
        "GIT_COMMITTER_EMAIL": email,
        "GIT_AUTHOR_NAME": email.split("@")[0],
        "GIT_COMMITTER_NAME": email.split("@")[0],
        "GIT_AUTHOR_DATE": when_iso,
        "GIT_COMMITTER_DATE": when_iso,
    }
    _git(repo, "commit", "-q", "-m", name, env=env)
    return _git(repo, "rev-parse", "HEAD").stdout.strip()


def _setup(tmp_path):
    repo = tmp_path / "work"
    subprocess.run(["git", "init", "-q", "-b", "main", str(repo)], check=True)
    _git(repo, "config", "user.email", "me@example.com")
    _git(repo, "config", "user.name", "Me")
    _git(repo, "config", "commit.gpgsign", "false")
    _commit(repo, "init", "2026-06-21T12:00:00+10:00")  # Sun
    return repo


def _subjects(repo):
    return _git(repo, "log", "--format=%s").stdout.strip().split("\n")


def _rep_sha(group):
    return group.target_sha or group.run_shas[-1]


def test_fold_run_into_following_evening_commit(tmp_path):
    repo = _setup(tmp_path)
    _commit(repo, "a", "2026-06-22T10:00:00+10:00")  # Mon — forbidden
    _commit(repo, "b", "2026-06-22T12:00:00+10:00")  # forbidden
    d_sha = _commit(repo, "d", "2026-06-22T19:00:00+10:00")  # evening — fold target

    commits = list_all_commits(repo, local_email="me@example.com")
    rng = commits[1:]  # from first forbidden onward (skip init)
    groups = plan_squash(rng, now=datetime.fromisoformat("2026-06-22T22:00:00+10:00"), rng_seed=1)
    assert len(groups) == 1 and groups[0].target_sha == d_sha

    squash_rebuild(
        repo,
        range_commits=rng,
        groups=groups,
        messages={_rep_sha(groups[0]): "feat: combined change"},
        sign=False,
    )

    # a and b collapse into d; only init + the folded commit remain.
    assert _subjects(repo) == ["feat: combined change", "init"]
    after = list_all_commits(repo, local_email="me@example.com")
    assert after[-1].committer_date == datetime.fromisoformat("2026-06-22T19:00:00+10:00")
    # Content preserved: every file is still present in the final tree.
    for f in ("a", "b", "d", "init"):
        assert (repo / f"{f}.txt").exists()


def test_synthesize_single_commit_after_17h(tmp_path):
    repo = _setup(tmp_path)
    _commit(repo, "a", "2026-06-22T10:00:00+10:00")  # forbidden
    _commit(repo, "b", "2026-06-22T12:00:00+10:00")  # forbidden, HEAD, no evening neighbour

    commits = list_all_commits(repo, local_email="me@example.com")
    rng = commits[1:]
    groups = plan_squash(rng, now=datetime.fromisoformat("2026-06-22T22:00:00+10:00"), rng_seed=1)
    assert len(groups) == 1 and groups[0].target_sha is None
    new_date = groups[0].new_date

    squash_rebuild(
        repo,
        range_commits=rng,
        groups=groups,
        messages={_rep_sha(groups[0]): "feat: combined change"},
        sign=False,
    )

    assert _subjects(repo) == ["feat: combined change", "init"]
    after = list_all_commits(repo, local_email="me@example.com")
    assert after[-1].committer_date == new_date
    assert after[-1].committer_date.astimezone().strftime("%z") != ""
    for f in ("a", "b", "init"):
        assert (repo / f"{f}.txt").exists()


def test_passthrough_clean_commit_after_squashed_run(tmp_path):
    repo = _setup(tmp_path)
    _commit(repo, "a", "2026-06-22T10:00:00+10:00")  # forbidden
    _commit(repo, "b", "2026-06-22T12:00:00+10:00")  # forbidden
    d_sha = _commit(repo, "d", "2026-06-22T19:00:00+10:00")  # evening target
    _commit(repo, "e", "2026-06-22T20:00:00+10:00")  # clean, passthrough after fold

    commits = list_all_commits(repo, local_email="me@example.com")
    rng = commits[1:]
    groups = plan_squash(rng, now=datetime.fromisoformat("2026-06-22T22:00:00+10:00"), rng_seed=1)
    assert groups[0].target_sha == d_sha

    squash_rebuild(
        repo,
        range_commits=rng,
        groups=groups,
        messages={_rep_sha(groups[0]): "feat: combined change"},
        sign=False,
    )

    # a,b fold into d; e passes through unchanged on top.
    assert _subjects(repo) == ["e", "feat: combined change", "init"]
    after = list_all_commits(repo, local_email="me@example.com")
    assert after[-1].committer_date == datetime.fromisoformat("2026-06-22T20:00:00+10:00")


def test_squash_normalizes_author_to_committer(tmp_path):
    repo = _setup(tmp_path)
    _commit(repo, "a", "2026-06-22T10:00:00+10:00")  # forbidden
    _commit(repo, "b", "2026-06-22T12:00:00+10:00")  # forbidden
    _commit(repo, "d", "2026-06-22T19:00:00+10:00")  # evening fold target
    # passthrough commit with author != committer (amend-style)
    (repo / "e.txt").write_text("e")
    _git(repo, "add", ".")
    _git(repo, "commit", "-q", "-m", "e", env={
        "GIT_AUTHOR_EMAIL": "me@example.com", "GIT_COMMITTER_EMAIL": "me@example.com",
        "GIT_AUTHOR_NAME": "me", "GIT_COMMITTER_NAME": "me",
        "GIT_AUTHOR_DATE": "2026-06-22T17:30:00+10:00",
        "GIT_COMMITTER_DATE": "2026-06-22T20:00:00+10:00",
    })

    commits = list_all_commits(repo, local_email="me@example.com")
    rng = commits[1:]
    groups = plan_squash(rng, now=datetime.fromisoformat("2026-06-22T22:00:00+10:00"), rng_seed=1)
    squash_rebuild(
        repo, range_commits=rng, groups=groups,
        messages={_rep_sha(groups[0]): "feat: combined change"}, sign=False,
    )

    for sha in _git(repo, "log", "--format=%H", "-3").stdout.split():
        ai = _git(repo, "show", "-s", "--format=%aI", sha).stdout.strip()
        ci = _git(repo, "show", "-s", "--format=%cI", sha).stdout.strip()
        assert ai == ci, f"{sha[:8]} author {ai} != committer {ci}"


def test_parent_sha_helper(tmp_path):
    repo = _setup(tmp_path)
    a = _commit(repo, "a", "2026-06-22T10:00:00+10:00")
    init_sha = list_all_commits(repo, local_email="me@example.com")[0].sha
    assert parent_sha(repo, a) == init_sha
    assert parent_sha(repo, init_sha) is None
