# SPDX-FileCopyrightText: 2026 Igor Santos
# SPDX-License-Identifier: MIT
from __future__ import annotations

from datetime import date, datetime
from zoneinfo import ZoneInfo

import pytest

from sanitize_personal_commits.planner import (
    Commit,
    SquashNoSlotError,
    plan_squash,
)
from sanitize_personal_commits.windows import is_forbidden

SYD = ZoneInfo("Australia/Sydney")


def D(day, hour, minute=0, month=6):
    return datetime(2026, month, day, hour, minute, tzinfo=SYD)


def C(sha, when, lines=10, is_merge=False, is_foreign=False):
    return Commit(
        sha=sha,
        committer_date=when,
        lines_changed=lines,
        is_merge=is_merge,
        is_foreign=is_foreign,
    )


def test_squash_empty_when_nothing_forbidden():
    commits = [C("a", D(21, 12))]  # Sunday
    assert plan_squash(commits, now=D(21, 20), rng_seed=1) == []


def test_squash_folds_run_into_following_same_day_evening_commit():
    commits = [
        C("a", D(22, 10)),
        C("b", D(22, 11)),
        C("c", D(22, 12)),
        C("d", D(22, 19)),  # same-day evening, own, clean -> fold target
    ]
    groups = plan_squash(commits, now=D(22, 22), rng_seed=1)
    assert len(groups) == 1
    g = groups[0]
    assert g.run_shas == ["a", "b", "c"]
    assert g.target_sha == "d"
    assert g.new_date is None


def test_squash_synthesizes_when_no_evening_neighbor():
    commits = [C("a", D(22, 10)), C("b", D(22, 11))]
    groups = plan_squash(commits, now=D(22, 22), rng_seed=1)
    assert len(groups) == 1
    g = groups[0]
    assert g.run_shas == ["a", "b"]
    assert g.target_sha is None
    assert g.new_date is not None
    local = g.new_date.astimezone(SYD)
    assert local.hour >= 17
    assert local.date() == date(2026, 6, 22)
    assert not is_forbidden(g.new_date)


def test_squash_does_not_fold_across_days():
    commits = [C("a", D(22, 10)), C("d", D(23, 19))]  # next-day evening
    groups = plan_squash(commits, now=D(23, 22), rng_seed=1)
    assert groups[0].target_sha is None
    assert groups[0].new_date.astimezone(SYD).date() == date(2026, 6, 22)


def test_squash_does_not_fold_into_foreign_commit():
    commits = [C("a", D(22, 10)), C("f", D(22, 19), is_foreign=True)]
    groups = plan_squash(commits, now=D(22, 22), rng_seed=1)
    assert groups[0].target_sha is None
    new = groups[0].new_date
    assert new.astimezone(SYD).hour >= 17
    assert new < D(22, 19)  # squeezed before the foreign neighbour


def test_squash_refuses_when_no_after17_slot_before_now():
    # Running mid-afternoon: 17:00 today is still in the future, so no slot exists.
    commits = [C("a", D(22, 10)), C("b", D(22, 11))]
    with pytest.raises(SquashNoSlotError):
        plan_squash(commits, now=D(22, 14), rng_seed=1)


def test_squash_multiple_runs_each_resolved_independently():
    commits = [
        C("a", D(22, 10)),
        C("d", D(22, 19)),  # evening -> target for run 1
        C("e", D(23, 10)),  # new forbidden run next day
        C("f", D(23, 11)),
        C("g", D(23, 20)),  # evening -> target for run 2
    ]
    groups = plan_squash(commits, now=D(23, 22), rng_seed=1)
    assert len(groups) == 2
    assert groups[0].run_shas == ["a"] and groups[0].target_sha == "d"
    assert groups[1].run_shas == ["e", "f"] and groups[1].target_sha == "g"


def test_squash_does_not_fold_into_merge_commit():
    commits = [C("a", D(22, 10)), C("m", D(22, 19), is_merge=True)]
    groups = plan_squash(commits, now=D(22, 22), rng_seed=1)
    assert groups[0].target_sha is None  # won't fold into a merge
    new = groups[0].new_date
    assert new.astimezone(SYD).hour >= 17
    assert new < D(22, 19)  # squeezed before the merge
