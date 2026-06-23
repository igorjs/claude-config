# SPDX-FileCopyrightText: 2026 Igor Santos
# SPDX-License-Identifier: MIT
from __future__ import annotations

import hashlib
from dataclasses import dataclass
from datetime import datetime, timedelta
from random import Random
from typing import Dict, List, Optional, Tuple

from .windows import (
    HARD_END_HOUR,
    HARD_START_HOUR,
    SOFT_START_HOUR,
    SYDNEY,
    _next_instant,
    is_forbidden,
    is_soft,
)

MIN_GAP_BASE = 30        # seconds floor
MIN_GAP_PER_LINE = 0.5
MIN_GAP_CAP = 600        # 10 minutes
GAP_SPREAD = 6.0         # inter-commit gap drawn from [min_gap, min_gap*GAP_SPREAD]
NIGHT_SCATTER_SEC = 13.5 * 3600  # how far back into prior off-hours a jump may land
PLACE_ITERS = 500        # backstop against a runaway backward walk
FUTURE_SAFETY_BUFFER = 60  # seconds — no placement may exceed now - this


@dataclass(frozen=True)
class Commit:
    sha: str
    committer_date: datetime
    lines_changed: int
    is_merge: bool = False
    is_foreign: bool = False


def _min_gap(lines_changed: int) -> float:
    return min(MIN_GAP_BASE + lines_changed * MIN_GAP_PER_LINE, MIN_GAP_CAP)


def seed_from_commits(commits: List[Commit]) -> int:
    """A deterministic RNG seed derived from the commit SHAs (order-sensitive).

    Seeding placement from repo content makes the plan reproducible — a dry-run
    preview matches the real apply — while still scattering timestamps naturally."""
    h = hashlib.sha256()
    for c in commits:
        h.update(c.sha.encode())
        h.update(b"\x00")
    return int.from_bytes(h.digest()[:8], "big")


def _place_backward(
    *,
    upper: datetime,
    floor: Optional[datetime],
    min_gap: float,
    rng: Random,
    sha: str,
) -> datetime:
    """Pick a random instant strictly below ``upper``, above ``floor``, and outside
    the hard window.

    Preference order: a slot fully outside the soft window (08:00-18:00), then the
    tolerated 08:00-09:00 / 17:00-18:00 buffer when the floor leaves no soft-clean
    slot. The walk goes *backward* through prior off-hours (evenings, nights,
    weekends), drawing a fresh random gap each step, so timestamps scatter rather
    than pinning to a single boundary, and the open past makes "running out" almost
    impossible — unlike forward placement crowding toward ``now``.

    Raises RuntimeError only when an anchor floor genuinely leaves no valid slot.
    """
    for region, day_start_hour in (
        (is_soft, SOFT_START_HOUR),
        (is_forbidden, HARD_START_HOUR),
    ):
        gap = rng.uniform(min_gap, min_gap * GAP_SPREAD)
        t = upper - timedelta(seconds=gap)
        for _ in range(PLACE_ITERS):
            if floor is not None and t <= floor:
                break  # this tier is exhausted; fall through to the buffer tier
            if not region(t):
                return t
            # In the avoided region: jump to before this day's window start and
            # land at a random point in the previous off-hours stretch.
            day_start = _next_instant(t, day_start_hour)  # HH:00 on t's local day
            t = day_start - timedelta(seconds=rng.uniform(60, NIGHT_SCATTER_SEC))
    raise RuntimeError(
        "commit %s: cannot place timestamp (upper=%s, floor=%s, min_gap=%ss); "
        "no valid slot before the previous anchor" % (sha, upper, floor, min_gap)
    )


def _anchor_floors(commits: List[Commit]) -> List[Optional[datetime]]:
    """For each commit, the timestamp of the nearest *older* anchor (merge or
    foreign commit) preceding it. Own commits may never be dated before it."""
    floors: List[Optional[datetime]] = []
    last_anchor: Optional[datetime] = None
    for c in commits:
        floors.append(last_anchor)
        if c.is_merge or c.is_foreign:
            last_anchor = c.committer_date
    return floors


def plan_rewrites(
    commits: List[Commit],
    *,
    now: datetime,
    rng_seed: Optional[int] = None,
) -> List[Tuple[str, datetime]]:
    """Plan timestamp rewrites for commits in forbidden windows.

    ``commits`` must be in chronological order (oldest first). Returns
    (sha, new_timestamp) pairs only for commits whose date actually changes.
    Merge and foreign commits are never rewritten but act as ordering anchors.

    Placement runs newest -> oldest, scattering each moved commit into a random
    off-hours slot before the one after it. Commits already outside the hard
    window keep their real timestamps unless an earlier placement forces them down.
    """
    rng = Random(rng_seed)

    # Short-circuit: nothing in the hard window means nothing to do.
    needs_work = any(
        (not c.is_merge and not c.is_foreign and is_forbidden(c.committer_date))
        for c in commits
    )
    if not needs_work:
        return []

    ceiling = now - timedelta(seconds=FUTURE_SAFETY_BUFFER)
    floors = _anchor_floors(commits)

    new_by_idx: Dict[int, datetime] = {}
    later_placed: Optional[datetime] = None  # time of the next-newer placed commit/anchor

    for i in range(len(commits) - 1, -1, -1):
        c = commits[i]
        if c.is_merge or c.is_foreign:
            later_placed = c.committer_date
            continue

        upper = ceiling if later_placed is None else min(ceiling, later_placed)
        floor = floors[i]

        # Keep a real timestamp that is already clean (outside the hard window) and
        # still fits below the next-newer placement — avoids needless churn and
        # preserves genuine evening/buffer commits.
        keep = (
            not is_forbidden(c.committer_date)
            and c.committer_date <= upper
            and (floor is None or c.committer_date > floor)
        )
        if keep:
            t = c.committer_date
        else:
            t = _place_backward(
                upper=upper,
                floor=floor,
                min_gap=_min_gap(c.lines_changed),
                rng=rng,
                sha=c.sha,
            )

        new_by_idx[i] = t
        later_placed = t

    rewrites: List[Tuple[str, datetime]] = []
    for i, c in enumerate(commits):
        new_dt = new_by_idx.get(i)
        if new_dt is None:
            continue
        # Whole seconds: git stores committer dates at second precision, so the
        # plan should reflect exactly what will be written.
        new_dt = new_dt.replace(microsecond=0)
        if new_dt != c.committer_date:
            rewrites.append((c.sha, new_dt))
    return rewrites


# --- Squash planning -------------------------------------------------------


class SquashNoSlotError(Exception):
    """Raised when a forbidden run cannot be collapsed into any after-17:00 slot
    at or before `now` (e.g. the engine was run while still inside the workday)."""

    def __init__(self, sha: str, when: datetime):
        super().__init__(
            "no after-17:00 slot at or before now for the run ending at %s (%s)"
            % (sha, when.isoformat())
        )
        self.sha = sha
        self.when = when


@dataclass(frozen=True)
class SquashGroup:
    """One contiguous run of forbidden commits to collapse.

    ``run_shas`` are the forbidden commits (oldest-first) being removed as
    standalone commits. When ``target_sha`` is set, the run folds into that
    existing after-17:00 same-day commit, which keeps its own date. Otherwise a
    single new commit is synthesized at ``new_date``.
    """

    run_shas: List[str]
    target_sha: Optional[str]
    new_date: Optional[datetime]


def _same_syd_day(a: datetime, b: datetime) -> bool:
    return a.astimezone(SYDNEY).date() == b.astimezone(SYDNEY).date()


def _synth_after_17h(
    *,
    day_ref: datetime,
    ceiling: datetime,
    upper_bound: Optional[datetime],
    parent_bound: Optional[datetime],
    rng: Random,
) -> Optional[datetime]:
    """A random instant in [17:00, end-of-day] on ``day_ref``'s Sydney day that is
    not in the future (<= ceiling), after ``parent_bound`` and before
    ``upper_bound``. Returns None when no such slot exists."""
    local = day_ref.astimezone(SYDNEY)
    lo = local.replace(hour=HARD_END_HOUR, minute=0, second=0, microsecond=0)
    hi = local.replace(hour=23, minute=59, second=59, microsecond=0)
    hi = min(hi, ceiling)
    if upper_bound is not None:
        hi = min(hi, upper_bound - timedelta(seconds=1))
    if parent_bound is not None:
        lo = max(lo, parent_bound + timedelta(seconds=1))
    if lo >= hi:
        return None
    span = (hi - lo).total_seconds()
    # Whole seconds: git stores committer dates at second precision.
    return lo + timedelta(seconds=int(rng.uniform(0, span)))


def plan_squash(
    commits: List[Commit],
    *,
    now: datetime,
    rng_seed: Optional[int] = None,
) -> List[SquashGroup]:
    """Plan how to collapse each contiguous run of forbidden commits.

    ``commits`` must be chronological (oldest first). Each maximal run of own,
    non-merge commits in the hard window becomes one SquashGroup: folded into the
    immediately following same-day after-17:00 own commit when one exists, else
    synthesized into a single new after-17:00 commit on the run's day.

    Raises SquashNoSlotError if a run needs synthesis but no valid slot fits.
    """
    rng = Random(rng_seed)
    ceiling = now - timedelta(seconds=FUTURE_SAFETY_BUFFER)

    groups: List[SquashGroup] = []
    n = len(commits)
    i = 0
    while i < n:
        c = commits[i]
        if c.is_merge or c.is_foreign or not is_forbidden(c.committer_date):
            i += 1
            continue

        # Extend the run over contiguous own, non-merge, forbidden commits.
        j = i
        while (
            j < n
            and not commits[j].is_merge
            and not commits[j].is_foreign
            and is_forbidden(commits[j].committer_date)
        ):
            j += 1
        run = commits[i:j]

        # Fold target: the immediately following commit, if it is own, non-merge,
        # clean, and on the same Sydney day as the run's last commit.
        target = None
        following = commits[j] if j < n else None
        if (
            following is not None
            and not following.is_merge
            and not following.is_foreign
            and not is_forbidden(following.committer_date)
            and _same_syd_day(following.committer_date, run[-1].committer_date)
        ):
            target = following

        if target is not None:
            groups.append(
                SquashGroup(
                    run_shas=[x.sha for x in run],
                    target_sha=target.sha,
                    new_date=None,
                )
            )
        else:
            new_date = _synth_after_17h(
                day_ref=run[-1].committer_date,
                ceiling=ceiling,
                upper_bound=following.committer_date if following is not None else None,
                parent_bound=commits[i - 1].committer_date if i > 0 else None,
                rng=rng,
            )
            if new_date is None:
                raise SquashNoSlotError(run[-1].sha, run[-1].committer_date)
            groups.append(
                SquashGroup(
                    run_shas=[x.sha for x in run],
                    target_sha=None,
                    new_date=new_date,
                )
            )

        i = j

    return groups
