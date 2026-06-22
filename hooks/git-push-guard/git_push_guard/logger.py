from __future__ import annotations

import json
from datetime import datetime
from pathlib import Path


def log_rewrite(
    log_file: Path,
    *,
    repo: str,
    branch: str,
    commit: str,
    original: datetime,
    new: datetime,
    reason: str,
    min_gap_used: float,
) -> None:
    log_file.parent.mkdir(parents=True, exist_ok=True)
    record = {
        "ts": datetime.now().astimezone().isoformat(),
        "repo": repo,
        "branch": branch,
        "commit": commit,
        "original_time": original.isoformat(),
        "new_time": new.isoformat(),
        "reason": reason,
        "min_gap_used": min_gap_used,
    }
    with log_file.open("a") as f:
        f.write(json.dumps(record) + "\n")
