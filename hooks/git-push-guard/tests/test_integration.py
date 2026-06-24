from __future__ import annotations
import os
import subprocess
import sys
from pathlib import Path

HOOK = Path(__file__).resolve().parents[1] / "git-push-guard"


def _git(repo, *args, env=None):
    e = {**os.environ, **(env or {})}
    return subprocess.run(
        ["git", "-C", str(repo), *args], capture_output=True, text=True, env=e, check=True
    )


def _commit(repo, name, when_iso=None):
    (repo / f"{name}.txt").write_text(name)
    _git(repo, "add", ".")
    env = {
        "GIT_AUTHOR_EMAIL": "me@example.com",
        "GIT_COMMITTER_EMAIL": "me@example.com",
        "GIT_AUTHOR_NAME": "Me",
        "GIT_COMMITTER_NAME": "Me",
    }
    if when_iso:
        env["GIT_AUTHOR_DATE"] = when_iso
        env["GIT_COMMITTER_DATE"] = when_iso
    _git(repo, "commit", "-q", "-m", name, env=env)


def _setup_repo(tmp_path):
    bare = tmp_path / "bare.git"
    subprocess.run(["git", "init", "-q", "--bare", "-b", "main", str(bare)], check=True)
    repo = tmp_path / "work"
    subprocess.run(["git", "init", "-q", "-b", "main", str(repo)], check=True)
    _git(repo, "config", "user.email", "me@example.com")
    _git(repo, "config", "user.name", "Me")
    _git(repo, "config", "commit.gpgsign", "false")
    _git(repo, "remote", "add", "origin", str(bare))
    _commit(repo, "init", "2026-06-21T12:00:00+10:00")  # Sun — allowed
    _git(repo, "push", "-q", "-u", "origin", "main")
    return repo


def test_dry_run_with_forbidden_commits(tmp_path):
    repo = _setup_repo(tmp_path)
    _commit(repo, "biz1", "2026-06-15T10:00:00+10:00")  # Mon 10am — forbidden
    _commit(repo, "biz2", "2026-06-22T10:05:00+10:00")  # forbidden

    r = subprocess.run(
        [sys.executable, str(HOOK), "--dry-run"],
        cwd=str(repo), capture_output=True, text=True,
    )
    assert r.returncode == 0, r.stderr
    assert "DRY RUN" in r.stdout
    assert "->" in r.stdout
    # Two rewrite lines + one would-push line
    rewrite_lines = [ln for ln in r.stdout.split("\n") if "->" in ln]
    assert len(rewrite_lines) == 2


def test_dry_run_with_all_allowed_commits(tmp_path):
    repo = _setup_repo(tmp_path)
    _commit(repo, "ok1", "2026-06-21T20:00:00+10:00")  # Sun evening — allowed
    _commit(repo, "ok2", "2026-06-21T21:00:00+10:00")  # allowed

    r = subprocess.run(
        [sys.executable, str(HOOK), "--dry-run"],
        cwd=str(repo), capture_output=True, text=True,
    )
    assert r.returncode == 0, r.stderr
    assert "would run: git push" in r.stdout
    assert "planned rewrites" not in r.stdout


def test_dry_run_warns_about_missing_signing_but_does_not_abort(tmp_path):
    repo = _setup_repo(tmp_path)
    _commit(repo, "biz1", "2026-06-15T10:00:00+10:00")  # forbidden — needs rewrite

    r = subprocess.run(
        [sys.executable, str(HOOK), "--dry-run"],
        cwd=str(repo), capture_output=True, text=True,
    )
    assert r.returncode == 0, f"stdout={r.stdout!r} stderr={r.stderr!r}"
    assert "WARNING" in r.stderr
    assert "signing not configured" in r.stderr
