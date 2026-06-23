# SPDX-FileCopyrightText: 2026 Igor Santos
# SPDX-License-Identifier: MIT
from __future__ import annotations
import json
from datetime import datetime
from zoneinfo import ZoneInfo

from sanitize_personal_commits.logger import log_rewrite

SYD = ZoneInfo("Australia/Sydney")


def test_log_rewrite_appends_jsonl(tmp_path):
    log_file = tmp_path / "log.jsonl"
    log_rewrite(
        log_file, repo="/r", branch="main", commit="abc",
        original=datetime(2026, 6, 22, 10, 0, tzinfo=SYD),
        new=datetime(2026, 6, 22, 19, 0, tzinfo=SYD),
        reason="forbidden", min_gap_used=35,
    )
    log_rewrite(
        log_file, repo="/r", branch="main", commit="def",
        original=datetime(2026, 6, 22, 10, 5, tzinfo=SYD),
        new=datetime(2026, 6, 22, 19, 5, tzinfo=SYD),
        reason="forbidden", min_gap_used=35,
    )
    lines = log_file.read_text().strip().split("\n")
    assert len(lines) == 2
    rec = json.loads(lines[0])
    assert rec["commit"] == "abc"
    assert rec["repo"] == "/r"
    assert rec["new_time"].startswith("2026-06-22T19:00")


def test_log_creates_parent_dir(tmp_path):
    log_file = tmp_path / "nested" / "deep" / "log.jsonl"
    log_rewrite(
        log_file, repo="/r", branch="main", commit="abc",
        original=datetime(2026, 6, 22, 10, 0, tzinfo=SYD),
        new=datetime(2026, 6, 22, 19, 0, tzinfo=SYD),
        reason="test", min_gap_used=0,
    )
    assert log_file.exists()
