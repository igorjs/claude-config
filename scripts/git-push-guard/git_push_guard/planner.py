from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta
from random import Random
from typing import List, Optional, Tuple

from .windows import is_forbidden, snap_to_nearest_allowed, _next_allowed_instant

MIN_GAP_BASE = 30        # seconds floor
MIN_GAP_PER_LINE = 0.5
MIN_GAP_CAP = 600        # 10 minutes
JITTER_LO = 0.2
JITTER_HI = 0.8
JITTER_RETRIES = 3
FUTURE_SAFETY_BUFFER = 60  # seconds — final new_dt must be <= now - this


@dataclass(frozen=True)
class Commit:
    sha: str
    committer_date: datetime
    lines_changed: int
    is_merge: bool = False
    is_foreign: bool = False


def _min_gap(lines_changed: int) -> float:
    return min(MIN_GAP_BASE + lines_changed * MIN_GAP_PER_LINE, MIN_GAP_CAP)


def _place_commit(
    *,
    desired: datetime,
    last_new: Optional[datetime],
    min_gap: float,
    now: datetime,
    sha: str,
) -> datetime:
    """Find a timestamp satisfying: allowed-window, >= last_new+min_gap, <= now-buffer."""
    deadline = now - timedelta(seconds=FUTURE_SAFETY_BUFFER)
    min_required = (
        last_new + timedelta(seconds=min_gap) if last_new is not None else None
    )

    candidates = []
    c1 = snap_to_nearest_allowed(desired) if is_forbidden(desired) else desired
    candidates.append(c1)
    if min_required is not None:
        c2 = min_required
        if is_forbidden(c2):
            # When enforcing spacing, only go forward — backward violates ordering.
            c2 = _next_allowed_instant(c2)
        candidates.append(c2)

    for cand in candidates:
        if is_forbidden(cand):
            continue
        if min_required is not None and cand < min_required:
            continue
        if cand > deadline:
            continue
        return cand

    raise RuntimeError(
        "commit %s: cannot place timestamp (last_new=%s, min_gap=%ss, now=%s); "
        "run out of valid past" % (sha, last_new, min_gap, now)
    )


def _apply_jitter(
    new_dt: datetime,
    min_gap: float,
    last_new: Optional[datetime],
    now: datetime,
    rng: Random,
) -> datetime:
    """Add ±jitter, keeping allowed-window + spacing + non-future constraints."""
    for attempt in range(JITTER_RETRIES):
        sign = rng.choice([-1, 1])
        # Magnitude shrinks with each retry
        scale = 1.0 - (attempt * 0.3)
        magnitude = rng.uniform(JITTER_LO, JITTER_HI) * min_gap * scale
        candidate = new_dt + timedelta(seconds=sign * magnitude)
        if is_forbidden(candidate):
            continue
        if last_new is not None and (candidate - last_new).total_seconds() < min_gap / 2:
            continue
        if candidate > now - timedelta(seconds=FUTURE_SAFETY_BUFFER):
            continue
        return candidate
    return new_dt


def plan_rewrites(
    commits: List[Commit],
    *,
    now: datetime,
    rng_seed: Optional[int] = None,
) -> List[Tuple[str, datetime]]:
    """Plan timestamp rewrites for commits that fall in forbidden windows.

    `commits` must be in chronological order (oldest first).
    Returns (sha, new_timestamp) pairs only for commits actually rewritten.
    Merge and foreign commits are skipped but act as ordering anchors.
    """
    rng = Random(rng_seed)
    rewrites: List[Tuple[str, datetime]] = []
    last_new: Optional[datetime] = None
    last_orig: Optional[datetime] = None

    # Short-circuit: if nothing is forbidden, return [] without touching anything.
    needs_work = any(
        (not c.is_merge and not c.is_foreign and is_forbidden(c.committer_date))
        for c in commits
    )
    if not needs_work:
        return []

    for c in commits:
        # Anchors: never rewrite, but use their real timestamp for ordering.
        if c.is_merge or c.is_foreign:
            last_new = c.committer_date
            last_orig = c.committer_date
            continue

        min_gap = _min_gap(c.lines_changed)

        # Desired = preserve original spacing relative to previous commit
        if last_orig is None or last_new is None:
            desired = c.committer_date
        else:
            spacing = c.committer_date - last_orig
            desired = last_new + spacing

        new_dt = _place_commit(
            desired=desired,
            last_new=last_new,
            min_gap=min_gap,
            now=now,
            sha=c.sha,
        )
        new_dt = _apply_jitter(new_dt, min_gap, last_new, now, rng)

        rewrites.append((c.sha, new_dt))
        last_new = new_dt
        last_orig = c.committer_date

    return rewrites
