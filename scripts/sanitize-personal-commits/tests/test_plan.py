from __future__ import annotations

from sanitize_personal_commits.plan import (
    Plan,
    clear_plan,
    plan_path,
    read_plan,
    write_plan,
)


def _scatter_plan():
    return Plan(
        mode="scatter",
        head="abc123",
        branch="main",
        range_expr="abc^..HEAD",
        is_root=False,
        force=True,
        signing_ok=True,
        backup_name="backup/pre-sanitize-20260623-210000",
        push_args=["origin", "main"],
        violations=[["abc123", "2026-06-23T10:00:00+10:00", "fix: thing"]],
        rewrites=[["abc123", "2026-06-23T07:00:00+10:00"]],
    )


def test_read_returns_none_when_absent(tmp_path):
    assert read_plan(tmp_path) is None


def test_round_trip_scatter(tmp_path):
    plan = _scatter_plan()
    write_plan(tmp_path, plan)
    loaded = read_plan(tmp_path)
    assert loaded == plan


def test_round_trip_squash(tmp_path):
    plan = Plan(
        mode="squash",
        head="def456",
        branch="main",
        range_expr="def^..HEAD",
        is_root=False,
        force=False,
        signing_ok=True,
        backup_name="backup/pre-sanitize-20260623-210000",
        squash=[{"run_shas": ["a", "b"], "target_sha": "c", "new_date": None}],
        messages={"c": "feat: combined change"},
    )
    write_plan(tmp_path, plan)
    assert read_plan(tmp_path) == plan


def test_clear_removes_plan(tmp_path):
    write_plan(tmp_path, _scatter_plan())
    assert plan_path(tmp_path).exists()
    clear_plan(tmp_path)
    assert not plan_path(tmp_path).exists()
    clear_plan(tmp_path)  # idempotent
