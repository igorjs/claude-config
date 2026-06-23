# SPDX-FileCopyrightText: 2026 Igor Santos
# SPDX-License-Identifier: MIT
from __future__ import annotations
import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

HOOK = Path(__file__).resolve().parents[1] / "sanitize-personal-commits"
PLAN_REL = Path(".git") / "sanitize-personal-commits-plan.json"


def _git(repo, *args, env=None):
    e = {**os.environ, **(env or {})}
    return subprocess.run(
        ["git", "-C", str(repo), *args], capture_output=True, text=True, env=e, check=True
    )


def _commit(repo, name, when_iso=None, author_email="me@example.com"):
    (repo / f"{name}.txt").write_text(name)
    _git(repo, "add", ".")
    env = {
        "GIT_AUTHOR_EMAIL": author_email,
        "GIT_COMMITTER_EMAIL": author_email,
        "GIT_AUTHOR_NAME": author_email.split("@")[0],
        "GIT_COMMITTER_NAME": author_email.split("@")[0],
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


def test_dry_run_forces_when_violation_already_pushed(tmp_path):
    repo = _setup_repo(tmp_path)
    _commit(repo, "biz1", "2026-06-15T10:00:00+10:00")  # Mon 10am — forbidden
    _git(repo, "push", "-q", "origin", "main")  # now the violation is pushed

    r = subprocess.run(
        [sys.executable, str(HOOK), "--dry-run"],
        cwd=str(repo), capture_output=True, text=True,
    )
    assert r.returncode == 0, r.stderr
    assert "--force-with-lease" in r.stdout
    # Default mode rewrites from the first violation, not the whole history.
    assert "^..HEAD" in r.stdout


def test_dry_run_default_does_not_force_when_unpushed(tmp_path):
    repo = _setup_repo(tmp_path)
    _commit(repo, "biz1", "2026-06-15T10:00:00+10:00")  # forbidden, unpushed

    r = subprocess.run(
        [sys.executable, str(HOOK), "--dry-run"],
        cwd=str(repo), capture_output=True, text=True,
    )
    assert r.returncode == 0, r.stderr
    assert "--force-with-lease" not in r.stdout


def test_dry_run_all_uses_full_history_range(tmp_path):
    repo = _setup_repo(tmp_path)
    _commit(repo, "biz1", "2026-06-15T10:00:00+10:00")  # forbidden

    r = subprocess.run(
        [sys.executable, str(HOOK), "--all", "--dry-run"],
        cwd=str(repo), capture_output=True, text=True,
    )
    assert r.returncode == 0, r.stderr
    assert "rewrite HEAD," in r.stdout
    assert "^..HEAD" not in r.stdout


def test_buffer_only_commit_warns_but_does_not_rewrite(tmp_path):
    repo = _setup_repo(tmp_path)
    _commit(repo, "buf", "2026-06-22T17:30:00+10:00")  # Mon 17:30 — soft buffer

    r = subprocess.run(
        [sys.executable, str(HOOK), "--dry-run"],
        cwd=str(repo), capture_output=True, text=True,
    )
    assert r.returncode == 0, r.stderr
    assert "planned rewrites" not in r.stdout  # no hard violation -> no rewrite
    assert "soft buffer" in r.stderr           # but flagged
    assert "would run: git push" in r.stdout


def test_dry_run_shows_violations_summary(tmp_path):
    repo = _setup_repo(tmp_path)
    _commit(repo, "biz1", "2026-06-15T10:00:00+10:00")  # Mon — forbidden
    _commit(repo, "biz2", "2026-06-22T11:00:00+10:00")  # forbidden

    r = subprocess.run(
        [sys.executable, str(HOOK), "--dry-run"],
        cwd=str(repo), capture_output=True, text=True,
    )
    assert r.returncode == 0, r.stderr
    assert "business-hours commit(s)" in r.stdout
    # Each violation is listed with its original Sydney local time and subject.
    assert "biz1" in r.stdout and "biz2" in r.stdout
    assert "2026-06-15 10:00" in r.stdout


def test_analyse_preview_combines_violation_with_new_time(tmp_path):
    repo = _setup_repo(tmp_path)
    _commit(repo, "biz1", "2026-06-15T10:00:00+10:00")  # forbidden
    _commit(repo, "eve", "2026-06-15T19:00:00+10:00")    # evening bound -> deterministic

    r = subprocess.run(
        [sys.executable, str(HOOK), "analyse"],
        cwd=str(repo), capture_output=True, text=True,
    )
    assert r.returncode == 0, r.stderr
    # A single row carries the original time, an arrow to the new time, and the subject.
    rows = [ln for ln in r.stdout.splitlines() if "biz1" in ln and "->" in ln]
    assert len(rows) == 1, f"expected one combined row, got: {rows}"
    assert "2026-06-15 10:00" in rows[0], rows[0]


def test_dry_run_is_deterministic(tmp_path):
    repo = _setup_repo(tmp_path)
    _commit(repo, "biz1", "2026-06-15T10:00:00+10:00")  # forbidden
    _commit(repo, "biz2", "2026-06-15T11:00:00+10:00")  # forbidden
    _commit(repo, "eve", "2026-06-15T19:00:00+10:00")   # evening bound -> now never binds

    def rewrite_lines():
        out = subprocess.run(
            [sys.executable, str(HOOK), "--dry-run"],
            cwd=str(repo), capture_output=True, text=True,
        ).stdout
        return [ln for ln in out.splitlines() if "->" in ln]

    first = rewrite_lines()
    assert len(first) == 2
    for _ in range(3):
        assert rewrite_lines() == first, "dry-run preview is not deterministic"


def test_squash_dry_run_folds_into_evening_commit(tmp_path):
    repo = _setup_repo(tmp_path)
    _commit(repo, "biz1", "2026-06-15T10:00:00+10:00")  # Mon — forbidden
    _commit(repo, "biz2", "2026-06-15T12:00:00+10:00")  # forbidden
    _commit(repo, "eve", "2026-06-15T19:00:00+10:00")   # same-day evening — fold target

    r = subprocess.run(
        [sys.executable, str(HOOK), "--squash", "--dry-run"],
        cwd=str(repo), capture_output=True, text=True,
    )
    assert r.returncode == 0, f"stdout={r.stdout!r} stderr={r.stderr!r}"
    assert "planned squash" in r.stdout
    assert "fold 2 commit(s)" in r.stdout
    assert "keeps its date" in r.stdout
    assert "rebuild" in r.stdout


def test_squash_dry_run_synthesizes_when_no_evening_neighbor(tmp_path):
    repo = _setup_repo(tmp_path)
    _commit(repo, "biz1", "2026-06-15T10:00:00+10:00")  # forbidden, HEAD
    _commit(repo, "biz2", "2026-06-15T12:00:00+10:00")  # forbidden, HEAD

    r = subprocess.run(
        [sys.executable, str(HOOK), "--squash", "--dry-run"],
        cwd=str(repo), capture_output=True, text=True,
    )
    assert r.returncode == 0, f"stdout={r.stdout!r} stderr={r.stderr!r}"
    assert "planned squash" in r.stdout
    assert "into a new commit at" in r.stdout


def test_squash_refuses_merge_in_range(tmp_path):
    repo = _setup_repo(tmp_path)
    _commit(repo, "biz1", "2026-06-15T10:00:00+10:00")  # forbidden
    # Build a side branch and merge it to create a true merge commit in range.
    _git(repo, "checkout", "-q", "-b", "side")
    _commit(repo, "side1", "2026-06-15T11:00:00+10:00")
    _git(repo, "checkout", "-q", "main")
    _commit(repo, "main1", "2026-06-15T11:30:00+10:00")
    _git(repo, "merge", "-q", "--no-ff", "-m", "merge side", "side",
         env={"GIT_AUTHOR_DATE": "2026-06-15T12:00:00+10:00",
              "GIT_COMMITTER_DATE": "2026-06-15T12:00:00+10:00",
              "GIT_AUTHOR_EMAIL": "me@example.com", "GIT_COMMITTER_EMAIL": "me@example.com",
              "GIT_AUTHOR_NAME": "me", "GIT_COMMITTER_NAME": "me"})

    r = subprocess.run(
        [sys.executable, str(HOOK), "--squash", "--dry-run"],
        cwd=str(repo), capture_output=True, text=True,
    )
    assert r.returncode == 7, f"stdout={r.stdout!r} stderr={r.stderr!r}"
    assert "merge commit" in r.stderr


def _run(repo, *args, env=None):
    e = {**os.environ, **(env or {})}
    return subprocess.run(
        [sys.executable, str(HOOK), *args], cwd=str(repo),
        capture_output=True, text=True, env=e,
    )


def _enable_ssh_signing(repo, tmp_path):
    key = tmp_path / "sign_key"
    subprocess.run(
        ["ssh-keygen", "-t", "ed25519", "-N", "", "-f", str(key), "-q"], check=True
    )
    _git(repo, "config", "gpg.format", "ssh")
    _git(repo, "config", "user.signingkey", str(key))
    _git(repo, "config", "commit.gpgsign", "true")


def test_analyse_persists_plan(tmp_path):
    repo = _setup_repo(tmp_path)
    _commit(repo, "biz1", "2026-06-15T10:00:00+10:00")  # forbidden

    r = _run(repo, "analyse")
    assert r.returncode == 0, r.stderr
    assert "ANALYSIS" in r.stdout
    assert "business-hours commit(s)" in r.stdout
    assert (repo / PLAN_REL).exists(), "analyse did not persist a plan"


def test_apply_without_plan_is_stale(tmp_path):
    repo = _setup_repo(tmp_path)
    r = _run(repo, "apply")
    assert r.returncode == 9, f"stdout={r.stdout!r} stderr={r.stderr!r}"
    assert "no analysed plan" in r.stderr


def test_apply_refuses_stale_plan_when_head_moves(tmp_path):
    repo = _setup_repo(tmp_path)
    _commit(repo, "biz1", "2026-06-15T10:00:00+10:00")
    assert _run(repo, "analyse").returncode == 0
    _commit(repo, "biz2", "2026-06-15T11:00:00+10:00")  # HEAD moves

    r = _run(repo, "apply")
    assert r.returncode == 9
    assert "stale" in r.stderr


def test_apply_scatter_refuses_without_signing(tmp_path):
    repo = _setup_repo(tmp_path)  # commit.gpgsign is false
    _commit(repo, "biz1", "2026-06-15T10:00:00+10:00")
    assert _run(repo, "analyse").returncode == 0

    r = _run(repo, "apply")
    assert r.returncode == 4, f"stdout={r.stdout!r} stderr={r.stderr!r}"
    assert "signing not configured" in r.stderr


def test_apply_noop_pushes(tmp_path):
    repo = _setup_repo(tmp_path)
    _commit(repo, "ok", "2026-06-21T20:00:00+10:00")  # Sun evening — allowed, unpushed
    assert _run(repo, "analyse").returncode == 0

    r = _run(repo, "apply")
    assert r.returncode == 0, f"stdout={r.stdout!r} stderr={r.stderr!r}"
    local_head = _git(repo, "rev-parse", "HEAD").stdout.strip()
    remote_head = _git(repo, "rev-parse", "origin/main").stdout.strip()
    assert local_head == remote_head, "noop apply did not push"


@pytest.mark.skipif(shutil.which("ssh-keygen") is None, reason="ssh-keygen unavailable")
def test_scatter_analyse_then_apply_rewrites_and_signs(tmp_path):
    repo = _setup_repo(tmp_path)
    _enable_ssh_signing(repo, tmp_path)
    _commit(repo, "biz1", "2026-06-15T10:00:00+10:00")  # forbidden, unpushed
    _commit(repo, "biz2", "2026-06-15T11:00:00+10:00")  # forbidden, unpushed
    log = tmp_path / "rewrite.log"

    assert _run(repo, "analyse", env={"SANITIZE_PERSONAL_COMMITS_LOG": str(log)}).returncode == 0
    head_before_tree = _git(repo, "rev-parse", "HEAD^{tree}").stdout.strip()

    r = _run(repo, "apply", env={"SANITIZE_PERSONAL_COMMITS_LOG": str(log)})
    assert r.returncode == 0, f"stdout={r.stdout!r} stderr={r.stderr!r}"
    assert "BACKUP_BRANCH=" in r.stdout

    # No commit remains in the hard window.
    times = _git(repo, "log", "--format=%cI").stdout.strip().split("\n")
    from datetime import datetime
    from zoneinfo import ZoneInfo
    syd = ZoneInfo("Australia/Sydney")
    for iso in times:
        local = datetime.fromisoformat(iso).astimezone(syd)
        assert not (local.weekday() < 5 and 9 <= local.hour < 17), f"{iso} still in hard window"
    # Content unchanged; the two rewritten commits are signed (U = signed, validity
    # unknown without an allowed-signers file). init is out of range, so unsigned.
    assert _git(repo, "rev-parse", "HEAD^{tree}").stdout.strip() == head_before_tree
    gpg = _git(repo, "log", "--format=%G?").stdout.strip().split("\n")
    assert all(flag in ("G", "U") for flag in gpg[:2]), f"rewritten commits unsigned: {gpg}"
    # Plan consumed, backup retained.
    assert not (repo / PLAN_REL).exists()
    assert _git(repo, "branch", "--list", "backup/*").stdout.strip()


def test_refuses_when_foreign_commit_in_range(tmp_path):
    repo = _setup_repo(tmp_path)
    _commit(repo, "biz1", "2026-06-15T10:00:00+10:00")  # forbidden, mine
    _commit(repo, "theirs", "2026-06-15T11:00:00+10:00", author_email="other@example.com")

    r = subprocess.run(
        [sys.executable, str(HOOK), "--dry-run"],
        cwd=str(repo), capture_output=True, text=True,
    )
    assert r.returncode == 7, f"stdout={r.stdout!r} stderr={r.stderr!r}"
    assert "other authors" in r.stderr
