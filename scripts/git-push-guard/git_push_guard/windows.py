from __future__ import annotations

from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

SYDNEY = ZoneInfo("Australia/Sydney")

# Forbidden window: Mon-Fri (weekday 0-4), 08:00 <= local hour < 18:00.
FORBIDDEN_START_HOUR = 8
FORBIDDEN_END_HOUR = 18


def is_forbidden(dt: datetime) -> bool:
    if dt.tzinfo is None:
        raise ValueError("datetime must be timezone-aware")
    local = dt.astimezone(SYDNEY)
    if local.weekday() >= 5:  # Sat, Sun
        return False
    return FORBIDDEN_START_HOUR <= local.hour < FORBIDDEN_END_HOUR


def _previous_allowed_instant(dt: datetime) -> datetime:
    """Latest allowed instant strictly before the forbidden window dt sits in."""
    local = dt.astimezone(SYDNEY)
    forbidden_start = local.replace(
        hour=FORBIDDEN_START_HOUR, minute=0, second=0, microsecond=0
    )
    return forbidden_start - timedelta(seconds=1)


def _next_allowed_instant(dt: datetime) -> datetime:
    """Earliest allowed instant at or after dt (assuming dt is forbidden)."""
    local = dt.astimezone(SYDNEY)
    return local.replace(
        hour=FORBIDDEN_END_HOUR, minute=0, second=0, microsecond=0
    )


def snap_to_nearest_allowed(dt: datetime) -> datetime:
    """If dt is forbidden, snap to nearest allowed boundary. Tie -> forward."""
    if not is_forbidden(dt):
        return dt
    prev = _previous_allowed_instant(dt)
    nxt = _next_allowed_instant(dt)
    if abs((dt - prev).total_seconds()) < abs((nxt - dt).total_seconds()):
        return prev
    return nxt
