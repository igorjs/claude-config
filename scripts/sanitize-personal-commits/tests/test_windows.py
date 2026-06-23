# SPDX-FileCopyrightText: 2026 Igor Santos
# SPDX-License-Identifier: MIT
from __future__ import annotations
from datetime import datetime
from zoneinfo import ZoneInfo

import pytest

from sanitize_personal_commits.windows import (
    in_soft_buffer,
    is_forbidden,
    is_soft,
    snap_out_of_hard,
    snap_to_nearest_allowed,
)

SYD = ZoneInfo("Australia/Sydney")


def test_weekday_business_hours_forbidden():
    assert is_forbidden(datetime(2026, 6, 22, 10, 0, tzinfo=SYD)) is True


def test_weekday_evening_allowed():
    assert is_forbidden(datetime(2026, 6, 22, 19, 0, tzinfo=SYD)) is False


def test_weekday_midnight_allowed():
    assert is_forbidden(datetime(2026, 6, 23, 0, 30, tzinfo=SYD)) is False


def test_weekend_all_allowed():
    assert is_forbidden(datetime(2026, 6, 20, 12, 0, tzinfo=SYD)) is False
    assert is_forbidden(datetime(2026, 6, 21, 12, 0, tzinfo=SYD)) is False


def test_monday_early_morning_allowed():
    assert is_forbidden(datetime(2026, 6, 22, 7, 0, tzinfo=SYD)) is False


def test_monday_8am_is_soft_buffer_not_hard():
    # 08:00 is the soft buffer now: tolerated, not a hard violation.
    dt = datetime(2026, 6, 22, 8, 0, tzinfo=SYD)
    assert is_forbidden(dt) is False
    assert is_soft(dt) is True
    assert in_soft_buffer(dt) is True


def test_monday_9am_is_hard():
    dt = datetime(2026, 6, 22, 9, 0, tzinfo=SYD)
    assert is_forbidden(dt) is True
    assert in_soft_buffer(dt) is False


def test_monday_1659_is_hard():
    assert is_forbidden(datetime(2026, 6, 22, 16, 59, tzinfo=SYD)) is True


def test_monday_17h_is_soft_buffer_not_hard():
    # Hard window is [09:00, 17:00); 17:00 sharp falls into the 17-18 buffer.
    dt = datetime(2026, 6, 22, 17, 0, tzinfo=SYD)
    assert is_forbidden(dt) is False
    assert in_soft_buffer(dt) is True


def test_monday_18h_allowed():
    # Boundary: 18:00 sharp is fully allowed (soft window is [08:00, 18:00))
    dt = datetime(2026, 6, 22, 18, 0, tzinfo=SYD)
    assert is_forbidden(dt) is False
    assert is_soft(dt) is False
    assert in_soft_buffer(dt) is False


def test_weekend_not_soft():
    assert is_soft(datetime(2026, 6, 20, 12, 0, tzinfo=SYD)) is False


def test_snap_out_of_hard_lands_in_buffer():
    # Mon 10:00 -> nearest hard boundary is 08:59:59 (buffer), closer than 17:00.
    dt = datetime(2026, 6, 22, 10, 0, tzinfo=SYD)
    result = snap_out_of_hard(dt)
    assert result == datetime(2026, 6, 22, 8, 59, 59, tzinfo=SYD)
    assert in_soft_buffer(result) is True


def test_snap_out_of_hard_noop_outside_hard():
    dt = datetime(2026, 6, 22, 8, 30, tzinfo=SYD)  # buffer, not hard
    assert snap_out_of_hard(dt) == dt


def test_friday_evening_allowed():
    assert is_forbidden(datetime(2026, 6, 19, 19, 0, tzinfo=SYD)) is False


def test_naive_datetime_rejected():
    with pytest.raises(ValueError):
        is_forbidden(datetime(2026, 6, 22, 10, 0))


def test_dst_aware_classification():
    # DST in Sydney: starts first Sunday of October, ends first Sunday of April.
    # 2026-10-04 is the first Sunday of October. After 2am AEST jumps to 3am AEDT.
    # Monday 2026-10-05 at 10:00 local should still be forbidden regardless of DST.
    assert is_forbidden(datetime(2026, 10, 5, 10, 0, tzinfo=SYD)) is True


# snap_to_nearest_allowed

def test_snap_allowed_is_noop():
    dt = datetime(2026, 6, 22, 20, 0, tzinfo=SYD)
    assert snap_to_nearest_allowed(dt) == dt


def test_snap_forbidden_morning_goes_backward():
    # Mon 09:00 — closer to 07:59:59 than to 18:00
    dt = datetime(2026, 6, 22, 9, 0, tzinfo=SYD)
    result = snap_to_nearest_allowed(dt)
    assert result == datetime(2026, 6, 22, 7, 59, 59, tzinfo=SYD)


def test_snap_forbidden_evening_goes_forward():
    # Mon 17:00 — closer to 18:00 than to 07:59:59
    dt = datetime(2026, 6, 22, 17, 0, tzinfo=SYD)
    result = snap_to_nearest_allowed(dt)
    assert result == datetime(2026, 6, 22, 18, 0, tzinfo=SYD)


def test_snap_equidistant_picks_forward():
    # Mon 13:00 — equidistant between 07:59:59 and 18:00 (within 1s). Tie -> forward.
    dt = datetime(2026, 6, 22, 13, 0, tzinfo=SYD)
    result = snap_to_nearest_allowed(dt)
    assert result == datetime(2026, 6, 22, 18, 0, tzinfo=SYD)
