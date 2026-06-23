from __future__ import annotations

from datetime import datetime
from zoneinfo import ZoneInfo

from sanitize_personal_commits.planner import Commit, plan_rewrites, seed_from_commits

SYD = ZoneInfo("Australia/Sydney")


def C(sha, when=datetime(2026, 6, 22, 10, 0, tzinfo=SYD), lines=10):
    return Commit(sha=sha, committer_date=when, lines_changed=lines)


def test_seed_is_deterministic_for_same_commits():
    commits = [C("aaaa1"), C("bbbb2"), C("cccc3")]
    assert seed_from_commits(commits) == seed_from_commits(commits)


def test_seed_changes_when_shas_change():
    a = [C("aaaa1"), C("bbbb2")]
    b = [C("aaaa1"), C("zzzz9")]
    assert seed_from_commits(a) != seed_from_commits(b)


def test_seed_is_order_sensitive():
    a = [C("aaaa1"), C("bbbb2")]
    b = [C("bbbb2"), C("aaaa1")]
    assert seed_from_commits(a) != seed_from_commits(b)


def test_plan_with_derived_seed_is_reproducible():
    # Two evening-bounded forbidden commits: placement depends only on the seed,
    # not wall-clock, so a content-derived seed makes the plan reproducible.
    commits = [
        C("aaaa1", datetime(2026, 6, 22, 10, 0, tzinfo=SYD)),
        C("bbbb2", datetime(2026, 6, 22, 11, 0, tzinfo=SYD)),
        C("eve33", datetime(2026, 6, 22, 19, 0, tzinfo=SYD)),
    ]
    now = datetime(2026, 6, 25, 12, 0, tzinfo=SYD)
    seed = seed_from_commits(commits)
    r1 = plan_rewrites(commits, now=now, rng_seed=seed)
    r2 = plan_rewrites(commits, now=now, rng_seed=seed)
    assert r1 == r2
