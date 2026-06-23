from __future__ import annotations
import os
import subprocess
from datetime import datetime
from pathlib import Path

import pytest

from git_push_guard.git_ops import (
    NoUpstreamError,
    SigningNotConfiguredError,
    check_signing_configured,
    get_local_email,
    list_unpushed_commits,
    rewrite_dates,
)


def init_repo(path: Path, with_remote: bool = True) -> Path:
    subprocess.run(["git", "init", "-q", "-b", "main", str(path)], check=True)
    subprocess.run(["git", "-C", str(path), "config", "user.email", "me@example.com"], check=True)
    subprocess.run(["git", "-C", str(path), "config", "user.name", "Me"], check=True)
    subprocess.run(["git", "-C", str(path), "config", "commit.gpgsign", "false"], check=True)
    subprocess.run(
        ["git", "-C", str(path), "commit", "-q", "--allow-empty", "-m", "init"], check=True
    )
    if with_remote:
        bare = path.parent / (path.name + "-bare.git")
        subprocess.run(["git", "init", "-q", "--bare", "-b", "main", str(bare)], check=True)
        subprocess.run(["git", "-C", str(path), "remote", "add", "origin", str(bare)], check=True)
        subprocess.run(
            ["git", "-C", str(path), "push", "-q", "-u", "origin", "main"], check=True
        )
    return path


def make_commit(repo: Path, msg: str, when_iso: str = None, author_email: str = "me@example.com"):
    f = repo / f"f-{msg}.txt"
    f.write_text(msg)
    subprocess.run(["git", "-C", str(repo), "add", str(f)], check=True)
    env = {
        **os.environ,
        "GIT_AUTHOR_EMAIL": author_email,
        "GIT_COMMITTER_EMAIL": author_email,
        "GIT_AUTHOR_NAME": author_email.split("@")[0],
        "GIT_COMMITTER_NAME": author_email.split("@")[0],
    }
    if when_iso:
        env["GIT_AUTHOR_DATE"] = when_iso
        env["GIT_COMMITTER_DATE"] = when_iso
    subprocess.run(
        ["git", "-C", str(repo), "commit", "-q", "-m", msg], check=True, env=env
    )


def test_list_unpushed_empty(tmp_path):
    repo = init_repo(tmp_path / "r")
    assert list_unpushed_commits(repo, local_email="me@example.com") == []


def test_list_unpushed_returns_oldest_first(tmp_path):
    repo = init_repo(tmp_path / "r")
    make_commit(repo, "a", "2026-06-22T10:00:00+10:00")
    make_commit(repo, "b", "2026-06-22T10:05:00+10:00")
    make_commit(repo, "c", "2026-06-22T10:10:00+10:00")
    commits = list_unpushed_commits(repo, local_email="me@example.com")
    assert len(commits) == 3
    assert commits[0].committer_date < commits[1].committer_date < commits[2].committer_date


def test_foreign_commits_flagged(tmp_path):
    repo = init_repo(tmp_path / "r")
    make_commit(repo, "mine")
    make_commit(repo, "theirs", author_email="other@example.com")
    commits = list_unpushed_commits(repo, local_email="me@example.com")
    assert commits[0].is_foreign is False
    assert commits[1].is_foreign is True


def test_no_upstream_raises(tmp_path):
    repo = init_repo(tmp_path / "r", with_remote=False)
    with pytest.raises(NoUpstreamError):
        list_unpushed_commits(repo, local_email="me@example.com")


def test_lines_changed_populated(tmp_path):
    repo = init_repo(tmp_path / "r")
    f = repo / "big.txt"
    f.write_text("\n".join(str(i) for i in range(20)))
    subprocess.run(["git", "-C", str(repo), "add", str(f)], check=True)
    subprocess.run(
        ["git", "-C", str(repo), "commit", "-q", "-m", "big"],
        check=True,
        env={**os.environ, "GIT_AUTHOR_EMAIL": "me@example.com",
             "GIT_COMMITTER_EMAIL": "me@example.com",
             "GIT_AUTHOR_NAME": "Me", "GIT_COMMITTER_NAME": "Me"},
    )
    commits = list_unpushed_commits(repo, local_email="me@example.com")
    assert commits[0].lines_changed >= 20


def test_check_signing_not_configured(tmp_path):
    repo = init_repo(tmp_path / "r")
    # commit.gpgsign is false by default in init_repo
    with pytest.raises(SigningNotConfiguredError):
        check_signing_configured(repo)


def test_rewrite_dates_updates_timestamps(tmp_path):
    repo = init_repo(tmp_path / "r")
    make_commit(repo, "a", "2026-06-22T10:00:00+10:00")
    make_commit(repo, "b", "2026-06-22T10:05:00+10:00")

    commits = list_unpushed_commits(repo, local_email="me@example.com")
    new_a = datetime.fromisoformat("2026-06-22T19:00:00+10:00")
    new_b = datetime.fromisoformat("2026-06-22T19:05:00+10:00")
    rewrite_dates(repo, [(commits[0].sha, new_a), (commits[1].sha, new_b)], sign=False)

    updated = list_unpushed_commits(repo, local_email="me@example.com")
    assert updated[0].committer_date == new_a
    assert updated[1].committer_date == new_b


def test_rewrite_dates_no_op_with_empty_list(tmp_path):
    repo = init_repo(tmp_path / "r")
    make_commit(repo, "a")
    head_before = subprocess.run(
        ["git", "-C", str(repo), "rev-parse", "HEAD"],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    rewrite_dates(repo, [], sign=False)
    head_after = subprocess.run(
        ["git", "-C", str(repo), "rev-parse", "HEAD"],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    assert head_before == head_after


def test_get_local_email(tmp_path):
    repo = init_repo(tmp_path / "r")
    assert get_local_email(repo) == "me@example.com"
