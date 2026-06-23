# SPDX-FileCopyrightText: 2026 Igor Santos
# SPDX-License-Identifier: MIT
from __future__ import annotations

import fcntl
from contextlib import contextmanager
from pathlib import Path


@contextmanager
def repo_lock(lock_path: Path):
    """Per-repo non-blocking exclusive file lock. Raises BlockingIOError if held."""
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open("w") as f:
        fcntl.flock(f.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            yield
        finally:
            fcntl.flock(f.fileno(), fcntl.LOCK_UN)
