from __future__ import annotations
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

import pytest

from git_push_guard.planner import Commit, plan_rewrites

SYD = ZoneInfo("Australia/Sydney")


def C(sha, when, lines=10, is_merge=False, is_foreign=False):
    return Commit(
        sha=sha,
        committer_date=when,
        lines_changed=lines,
        is_merge=is_merge,
        is_foreign=is_foreign,
    )


def test_all_allowed_no_rewrites():
    commits = [
        C("a", datetime(2026, 6, 20, 12, 0, tzinfo=SYD)),  # Sat noon
        C("b", datetime(2026, 6, 20, 14, 0, tzinfo=SYD)),
    ]
    now = datetime(2026, 6, 20, 20, 0, tzinfo=SYD)
    result = plan_rewrites(commits, now=now, rng_seed=1)
    assert result == []


def test_single_forbidden_commit_gets_snapped():
    commits = [C("a", datetime(2026, 6, 22, 10, 0, tzinfo=SYD), lines=20)]
    now = datetime(2026, 6, 22, 22, 0, tzinfo=SYD)
    result = plan_rewrites(commits, now=now, rng_seed=1)
    assert len(result) == 1
    sha, new_dt = result[0]
    assert sha == "a"
    # Mon 10:00 -> snap backward to 07:59:59, ± jitter
    # Either way, must be in allowed window and not far from boundary
    assert not (8 <= new_dt.astimezone(SYD).hour < 18 and new_dt.weekday() < 5)


def test_ordering_preserved_with_min_gap():
    commits = [
        C("a", datetime(2026, 6, 22, 10, 0, 0, tzinfo=SYD), lines=10),
        C("b", datetime(2026, 6, 22, 10, 0, 5, tzinfo=SYD), lines=10),
    ]
    now = datetime(2026, 6, 22, 22, 0, tzinfo=SYD)
    result = plan_rewrites(commits, now=now, rng_seed=1)
    assert len(result) == 2
    # min_gap = 30 + 10*0.5 = 35s; b must be > a by at least min_gap/2 after jitter
    gap = (result[1][1] - result[0][1]).total_seconds()
    assert gap >= 35 / 2, f"gap was {gap}s"


def test_merge_commits_skipped():
    commits = [
        C("a", datetime(2026, 6, 22, 10, 0, tzinfo=SYD)),
        C("m", datetime(2026, 6, 22, 11, 0, tzinfo=SYD), is_merge=True),
        C("b", datetime(2026, 6, 22, 12, 0, tzinfo=SYD)),
    ]
    now = datetime(2026, 6, 22, 22, 0, tzinfo=SYD)
    result = plan_rewrites(commits, now=now, rng_seed=1)
    shas = [r[0] for r in result]
    assert "m" not in shas


def test_foreign_commits_skipped_and_act_as_anchors():
    commits = [
        C("a", datetime(2026, 6, 22, 10, 0, tzinfo=SYD)),
        C("f", datetime(2026, 6, 22, 11, 0, tzinfo=SYD), is_foreign=True),
        C("b", datetime(2026, 6, 22, 12, 0, tzinfo=SYD)),
    ]
    now = datetime(2026, 6, 22, 22, 0, tzinfo=SYD)
    result = plan_rewrites(commits, now=now, rng_seed=1)
    shas_rewritten = {r[0] for r in result}
    assert "f" not in shas_rewritten
    # b's new timestamp must be strictly after f's original 11:00
    b_new = dict(result)["b"]
    assert b_new > datetime(2026, 6, 22, 11, 0, tzinfo=SYD)


def test_jitter_is_deterministic_with_seed():
    commits = [C("a", datetime(2026, 6, 22, 10, 0, tzinfo=SYD))]
    now = datetime(2026, 6, 22, 22, 0, tzinfo=SYD)
    r1 = plan_rewrites(commits, now=now, rng_seed=42)
    r2 = plan_rewrites(commits, now=now, rng_seed=42)
    assert r1 == r2


def test_no_rewrite_when_only_allowed_commits():
    commits = [
        C("a", datetime(2026, 6, 19, 19, 0, tzinfo=SYD)),  # Fri evening
        C("b", datetime(2026, 6, 19, 20, 0, tzinfo=SYD)),
    ]
    now = datetime(2026, 6, 22, 22, 0, tzinfo=SYD)
    result = plan_rewrites(commits, now=now, rng_seed=1)
    assert result == []


def test_run_out_of_past_raises():
    # Commits inside forbidden window with huge min_gap (lines=10000 → capped at 600s).
    # now is Mon 08:30 → ~30min of "after forbidden start" past available before being too close to now.
    # 10 commits at 10min spacing minimum can't fit.
    base = datetime(2026, 6, 22, 10, 0, tzinfo=SYD)
    commits = [C(f"c{i}", base + timedelta(seconds=i), lines=10000) for i in range(10)]
    now = datetime(2026, 6, 22, 8, 30, tzinfo=SYD)
    with pytest.raises(RuntimeError):
        plan_rewrites(commits, now=now, rng_seed=1)


def test_resulting_timestamps_are_in_allowed_windows():
    commits = [
        C(f"c{i}", datetime(2026, 6, 22, 10, i, tzinfo=SYD), lines=5)
        for i in range(5)
    ]
    now = datetime(2026, 6, 22, 22, 0, tzinfo=SYD)
    result = plan_rewrites(commits, now=now, rng_seed=7)
    from git_push_guard.windows import is_forbidden
    for sha, dt in result:
        assert not is_forbidden(dt), f"{sha} ended in forbidden window: {dt}"
