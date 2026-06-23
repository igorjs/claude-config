from __future__ import annotations
import multiprocessing
import time
from pathlib import Path

from git_push_guard.lock import repo_lock


def _hold_lock(lock_path: str, duration: float, result_queue):
    try:
        with repo_lock(Path(lock_path)):
            result_queue.put("acquired")
            time.sleep(duration)
    except BlockingIOError:
        result_queue.put("blocked")


def test_lock_excludes_concurrent_holders(tmp_path):
    lock = tmp_path / "test.lock"
    ctx = multiprocessing.get_context("spawn")
    q = ctx.Queue()
    p1 = ctx.Process(target=_hold_lock, args=(str(lock), 1.0, q))
    p1.start()
    time.sleep(0.3)
    p2 = ctx.Process(target=_hold_lock, args=(str(lock), 0.1, q))
    p2.start()
    p1.join()
    p2.join()
    results = sorted([q.get(timeout=5), q.get(timeout=5)])
    assert results == ["acquired", "blocked"]
