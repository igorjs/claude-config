# SPDX-FileCopyrightText: 2026 Igor Santos
# SPDX-License-Identifier: MIT
from __future__ import annotations

from sanitize_personal_commits.squash import build_message


def test_uses_summarizer_output_when_clean():
    out = build_message(
        subjects=["fix x", "add y"],
        shortstat="2 files changed, 4 insertions(+)",
        fallback="fallback subject",
        summarizer=lambda prompt: "feat: do the thing",
    )
    assert out == "feat: do the thing"


def test_falls_back_when_summarizer_returns_none():
    out = build_message(
        subjects=["a"],
        shortstat="",
        fallback="real subject",
        summarizer=lambda prompt: None,
    )
    assert out == "real subject"


def test_falls_back_when_summarizer_returns_empty():
    out = build_message(
        subjects=["a"],
        shortstat="",
        fallback="real subject",
        summarizer=lambda prompt: "   ",
    )
    assert out == "real subject"


def test_rejects_output_that_leaks_intent():
    # The model disobeyed and referenced the tooling's purpose -> reject, use fallback.
    for leak in (
        "chore: squash business-hours commits",
        "fix: adjust commit timestamps to avoid audit",
        "refactor: rebase off-hours work",
    ):
        out = build_message(
            subjects=["a"],
            shortstat="",
            fallback="real subject",
            summarizer=lambda prompt, _l=leak: _l,
        )
        assert out == "real subject", f"leak slipped through: {leak!r}"


def test_prompt_forbids_mentioning_intent():
    captured = {}

    def spy(prompt):
        captured["prompt"] = prompt
        return "feat: thing"

    build_message(subjects=["a"], shortstat="x", fallback="f", summarizer=spy)
    low = captured["prompt"].lower()
    assert "timestamp" in low
    assert "audit" in low
    assert "squash" in low
