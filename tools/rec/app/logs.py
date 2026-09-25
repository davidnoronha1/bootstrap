"""Failure logs written to ~/.local/state/rec/logs."""

from datetime import datetime
import os
from pathlib import Path

LOG_DIR = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local" / "state")) / "rec" / "logs"


def write_failure_log(kind: str, details: str) -> str:
    """Write a timestamped failure log and return its path ("" if it couldn't be written)."""
    stamp = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
    path = LOG_DIR / f"{kind}_{stamp}.log"
    try:
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        path.write_text(
            f"rec failure: {kind}\ntime: {datetime.now().isoformat()}\n"
            f"DISPLAY={os.environ.get('DISPLAY', '')}\n\n{details}\n",
            encoding="utf-8",
        )
        return str(path)
    except Exception:
        return ""
