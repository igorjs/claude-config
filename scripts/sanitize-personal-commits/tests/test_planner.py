# SPDX-FileCopyrightText: 2026 Igor Santos
# SPDX-License-Identifier: MIT
from __future__ import annotations
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

import pytest

from sanitize_personal_commits.planner import Commit, plan_rewrites
from sanitize_personal_commits.windows import is_forbidden

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


def test_genuine_no_room_raises():
    # A foreign anchor at Mon 09:00 pins the floor; the lone own commit just after
    # it must land in (09:00, 09:04) — entirely hard window — and cannot go earlier
    # than the anchor. No valid slot exists, so the planner raises.
    anchor = C("f", datetime(2026, 6, 22, 9, 0, 0, tzinfo=SYD), is_foreign=True)
    b = C("b", datetime(2026, 6, 22, 9, 0, 30, tzinfo=SYD), lines=10)
    now = datetime(2026, 6, 22, 9, 5, tzinfo=SYD)
    with pytest.raises(RuntimeError):
        plan_rewrites([anchor, b], now=now, rng_seed=1)


def test_late_afternoon_cluster_does_not_run_out_of_past():
    # Regression: ten commits clustered in a single weekday afternoon, with `now`
    # only minutes after the last one. Forward placement ran out of runway before
    # `now`; backward fill has the whole prior night/evening available.
    base = datetime(2026, 6, 23, 15, 57, tzinfo=SYD)  # Tue afternoon
    commits = [C(f"c{i}", base + timedelta(minutes=6 * i), lines=20) for i in range(10)]
    now = datetime(2026, 6, 23, 18, 22, tzinfo=SYD)
    result = plan_rewrites(commits, now=now, rng_seed=1)
    assert len(result) == 10
    for sha, dt in result:
        assert not is_forbidden(dt), f"{sha} landed in hard window: {dt}"
    placed = [dt for _, dt in result]
    assert placed == sorted(placed), "chronological order not preserved"
    assert len(set(placed)) == 10, "timestamps collapsed onto each other"


def test_placements_are_scattered_not_pinned_to_one_instant():
    # Anti-suspicion: results must not all share the same clock time (the old
    # behaviour pinned everything to 07:59:59).
    base = datetime(2026, 6, 23, 10, 0, tzinfo=SYD)
    commits = [C(f"c{i}", base + timedelta(minutes=i), lines=5) for i in range(8)]
    now = datetime(2026, 6, 23, 23, 0, tzinfo=SYD)
    result = plan_rewrites(commits, now=now, rng_seed=5)
    clock = {dt.astimezone(SYD).strftime("%H:%M:%S") for _, dt in result}
    assert len(clock) > 1, f"all placements share one clock time: {clock}"


def test_different_seeds_produce_different_placements():
    base = datetime(2026, 6, 23, 10, 0, tzinfo=SYD)
    commits = [C(f"c{i}", base + timedelta(minutes=i), lines=5) for i in range(6)]
    now = datetime(2026, 6, 23, 23, 0, tzinfo=SYD)
    r1 = plan_rewrites(commits, now=now, rng_seed=1)
    r2 = plan_rewrites(commits, now=now, rng_seed=2)
    assert r1 != r2


def test_now_during_business_hours_still_places_into_off_hours():
    # Running mid-afternoon: the prior night/evening is the only runway. Must not
    # raise and must keep everything out of the hard window.
    base = datetime(2026, 6, 23, 9, 30, tzinfo=SYD)
    commits = [C(f"c{i}", base + timedelta(minutes=5 * i), lines=5) for i in range(5)]
    now = datetime(2026, 6, 23, 14, 0, tzinfo=SYD)
    result = plan_rewrites(commits, now=now, rng_seed=3)
    assert len(result) == 5
    for sha, dt in result:
        assert not is_forbidden(dt), f"{sha} landed in hard window: {dt}"


def test_resulting_timestamps_are_in_allowed_windows():
    commits = [
        C(f"c{i}", datetime(2026, 6, 22, 10, i, tzinfo=SYD), lines=5)
        for i in range(5)
    ]
    now = datetime(2026, 6, 22, 22, 0, tzinfo=SYD)
    result = plan_rewrites(commits, now=now, rng_seed=7)
    from sanitize_personal_commits.windows import is_forbidden
    for sha, dt in result:
        assert not is_forbidden(dt), f"{sha} ended in forbidden window: {dt}"


def test_prefers_outside_soft_window():
    # With ample room (evening now), a hard-window commit should land fully
    # outside the soft window, not merely in the 08-09 / 17-18 buffer.
    commits = [C("a", datetime(2026, 6, 22, 12, 0, tzinfo=SYD), lines=5)]
    now = datetime(2026, 6, 22, 22, 0, tzinfo=SYD)
    (sha, new_dt) = plan_rewrites(commits, now=now, rng_seed=3)[0]
    from sanitize_personal_commits.windows import is_soft
    assert not is_soft(new_dt)


def test_buffer_fallback_when_no_soft_slot_fits():
    # A foreign anchor at 16:40 forces the next commit forward; with now=17:30
    # there is no soft-clean slot (18:00 is in the future), so the planner falls
    # back to the tolerated buffer rather than failing — but never the hard core.
    anchor = C("anchor", datetime(2026, 6, 22, 16, 40, tzinfo=SYD), is_foreign=True)
    b = C("b", datetime(2026, 6, 22, 16, 41, tzinfo=SYD), lines=10)
    now = datetime(2026, 6, 22, 17, 30, tzinfo=SYD)
    result = plan_rewrites([anchor, b], now=now, rng_seed=1)
    assert len(result) == 1
    sha, new_dt = result[0]
    from sanitize_personal_commits.windows import in_soft_buffer, is_forbidden
    assert not is_forbidden(new_dt)
    assert in_soft_buffer(new_dt)
