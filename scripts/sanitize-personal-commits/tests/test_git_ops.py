from __future__ import annotations
import os
import subprocess
from datetime import datetime
from pathlib import Path

import pytest

from sanitize_personal_commits.git_ops import (
    NoUpstreamError,
    RewriteError,
    SigningNotConfiguredError,
    check_signing_configured,
    create_backup_branch,
    get_local_email,
    is_pushed,
    list_all_commits,
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


def test_rewrite_dates_normalizes_author_to_committer_for_passthrough(tmp_path):
    # A passthrough commit (not in the rewrite list) with author != committer — as
    # produced by an amend — must have its author date normalized to its committer
    # date, so a rewritten ancestor can't leave the author timeline inverted.
    repo = init_repo(tmp_path / "r")
    make_commit(repo, "a", "2026-06-22T10:00:00+10:00")
    (repo / "b.txt").write_text("b")
    subprocess.run(["git", "-C", str(repo), "add", "b.txt"], check=True)
    env = {
        **os.environ,
        "GIT_AUTHOR_EMAIL": "me@example.com", "GIT_COMMITTER_EMAIL": "me@example.com",
        "GIT_AUTHOR_NAME": "Me", "GIT_COMMITTER_NAME": "Me",
        "GIT_AUTHOR_DATE": "2026-06-22T10:30:00+10:00",     # earlier (amend-style)
        "GIT_COMMITTER_DATE": "2026-06-22T19:00:00+10:00",  # later
    }
    subprocess.run(["git", "-C", str(repo), "commit", "-q", "-m", "b"], check=True, env=env)

    commits = list_all_commits(repo, local_email="me@example.com")
    a_sha = commits[1].sha  # init, a, b -> a
    rewrite_dates(
        repo,
        [(a_sha, datetime.fromisoformat("2026-06-22T09:00:00+10:00"))],
        sign=False,
        range_expr="HEAD",
    )

    b_sha = list_all_commits(repo, local_email="me@example.com")[-1].sha
    ai = subprocess.run(
        ["git", "-C", str(repo), "show", "-s", "--format=%aI", b_sha],
        capture_output=True, text=True,
    ).stdout.strip()
    ci = subprocess.run(
        ["git", "-C", str(repo), "show", "-s", "--format=%cI", b_sha],
        capture_output=True, text=True,
    ).stdout.strip()
    assert ai == ci, f"passthrough author {ai} != committer {ci}"


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


def _push(repo: Path):
    subprocess.run(["git", "-C", str(repo), "push", "-q", "origin", "main"], check=True)


def test_list_all_includes_pushed_commits(tmp_path):
    repo = init_repo(tmp_path / "r")  # init commit is pushed by init_repo
    make_commit(repo, "a", "2026-06-22T10:00:00+10:00")
    _push(repo)
    make_commit(repo, "b", "2026-06-22T10:05:00+10:00")  # unpushed

    assert len(list_unpushed_commits(repo, local_email="me@example.com")) == 1
    all_commits = list_all_commits(repo, local_email="me@example.com")
    # init + a + b, in graph order (oldest first)
    assert len(all_commits) == 3
    # The unpushed commit "b" is last in the chain.
    assert all_commits[-1].committer_date == datetime.fromisoformat(
        "2026-06-22T10:05:00+10:00"
    )


def test_is_pushed_distinguishes_pushed_from_local(tmp_path):
    repo = init_repo(tmp_path / "r")
    make_commit(repo, "a", "2026-06-22T10:00:00+10:00")
    _push(repo)
    pushed_sha = list_all_commits(repo, local_email="me@example.com")[-1].sha
    make_commit(repo, "b", "2026-06-22T10:05:00+10:00")
    local_sha = list_all_commits(repo, local_email="me@example.com")[-1].sha

    assert is_pushed(repo, pushed_sha) is True
    assert is_pushed(repo, local_sha) is False


def test_is_pushed_false_without_upstream(tmp_path):
    repo = init_repo(tmp_path / "r", with_remote=False)
    sha = list_all_commits(repo, local_email="me@example.com")[-1].sha
    assert is_pushed(repo, sha) is False


def test_create_backup_branch_points_at_head(tmp_path):
    repo = init_repo(tmp_path / "r")
    make_commit(repo, "a")
    head = subprocess.run(
        ["git", "-C", str(repo), "rev-parse", "HEAD"],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    create_backup_branch(repo, "backup/test")
    backed = subprocess.run(
        ["git", "-C", str(repo), "rev-parse", "backup/test"],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    assert backed == head


def test_create_backup_branch_rejects_duplicate(tmp_path):
    repo = init_repo(tmp_path / "r")
    create_backup_branch(repo, "backup/dup")
    with pytest.raises(RewriteError):
        create_backup_branch(repo, "backup/dup")


def test_rewrite_dates_full_history_range(tmp_path):
    repo = init_repo(tmp_path / "r")
    make_commit(repo, "a", "2026-06-22T10:00:00+10:00")
    make_commit(repo, "b", "2026-06-22T10:05:00+10:00")

    commits = list_all_commits(repo, local_email="me@example.com")
    new = datetime.fromisoformat("2026-06-20T19:00:00+10:00")
    rewrite_dates(repo, [(commits[-1].sha, new)], sign=False, range_expr="HEAD")

    updated = list_all_commits(repo, local_email="me@example.com")
    assert updated[-1].committer_date == new
