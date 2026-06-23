# SPDX-FileCopyrightText: 2026 Igor Santos
# SPDX-License-Identifier: MIT
from __future__ import annotations

from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

SYDNEY = ZoneInfo("Australia/Sydney")

# Two nested weekday windows (local Sydney time):
#
#   Hard cap  [09:00, 17:00)  inviolable. A rewrite may NEVER place a timestamp
#                             here, and any commit landing here MUST be moved.
#   Soft cap  [08:00, 18:00)  preferred-avoid. Rewrites aim to land fully outside
#                             this; the 08:00-09:00 and 17:00-18:00 buffer is a
#                             tolerated fallback (a warning, not a failure) —
#                             slack that absorbs DST shifts.
HARD_START_HOUR = 9
HARD_END_HOUR = 17
SOFT_START_HOUR = 8
SOFT_END_HOUR = 18


def _in_weekday_window(dt: datetime, start_hour: int, end_hour: int) -> bool:
    if dt.tzinfo is None:
        raise ValueError("datetime must be timezone-aware")
    local = dt.astimezone(SYDNEY)
    if local.weekday() >= 5:  # Sat, Sun
        return False
    return start_hour <= local.hour < end_hour


def is_forbidden(dt: datetime) -> bool:
    """Hard cap: Mon-Fri [09:00, 17:00). Never place a timestamp here."""
    return _in_weekday_window(dt, HARD_START_HOUR, HARD_END_HOUR)


def is_soft(dt: datetime) -> bool:
    """Soft cap: Mon-Fri [08:00, 18:00). The preferred-avoid zone."""
    return _in_weekday_window(dt, SOFT_START_HOUR, SOFT_END_HOUR)


def in_soft_buffer(dt: datetime) -> bool:
    """The 08:00-09:00 / 17:00-18:00 edges: tolerated, but worth a warning."""
    return is_soft(dt) and not is_forbidden(dt)


def _prev_instant(dt: datetime, start_hour: int) -> datetime:
    """Latest instant strictly before `start_hour` on dt's local day."""
    local = dt.astimezone(SYDNEY)
    boundary = local.replace(hour=start_hour, minute=0, second=0, microsecond=0)
    return boundary - timedelta(seconds=1)


def _next_instant(dt: datetime, end_hour: int) -> datetime:
    """Instant at `end_hour:00:00` on dt's local day."""
    local = dt.astimezone(SYDNEY)
    return local.replace(hour=end_hour, minute=0, second=0, microsecond=0)


# Preferred-placement helpers operate on the SOFT window: rewrites aim to land
# fully outside 08:00-18:00.
def _previous_allowed_instant(dt: datetime) -> datetime:
    return _prev_instant(dt, SOFT_START_HOUR)


def _next_allowed_instant(dt: datetime) -> datetime:
    return _next_instant(dt, SOFT_END_HOUR)


def snap_to_nearest_allowed(dt: datetime) -> datetime:
    """Snap a soft-window dt to the nearest soft boundary (07:59:59 / 18:00).
    Tie -> forward. No-op outside the soft window."""
    if not is_soft(dt):
        return dt
    prev = _previous_allowed_instant(dt)
    nxt = _next_allowed_instant(dt)
    if abs((dt - prev).total_seconds()) < abs((nxt - dt).total_seconds()):
        return prev
    return nxt


def snap_out_of_hard(dt: datetime) -> datetime:
    """Snap a hard-window dt to the nearest hard boundary (08:59:59 / 17:00).
    These land in the soft buffer. Tie -> forward. No-op outside the hard window.
    Used only as the fallback when no soft-clean placement is possible."""
    if not is_forbidden(dt):
        return dt
    prev = _prev_instant(dt, HARD_START_HOUR)
    nxt = _next_instant(dt, HARD_END_HOUR)
    if abs((dt - prev).total_seconds()) < abs((nxt - dt).total_seconds()):
        return prev
    return nxt
