#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "textual>=8.0.0",
#     "rich>=13.0.0",
# ]
# ///
"""ScreenRec Studio - FFmpeg Screen, Window & Region Recorder TUI.

Usage:
    ./main.py                 # uv script mode (deps resolved from the header)
    ./rec                     # Same, via the launcher
"""

import sys
from pathlib import Path

# Add current folder to sys.path
sys.path.insert(0, str(Path(__file__).parent.resolve()))

from app.ui import ScreenRecApp


def main() -> None:
    app = ScreenRecApp()
    app.run()


if __name__ == "__main__":
    main()
