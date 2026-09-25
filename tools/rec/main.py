#!/usr/bin/env python3
"""ScreenRec Studio - FFmpeg Screen, Window & Region Recorder TUI.

Usage:
    python3 main.py           # Launch interactive TUI
    ./rec                     # Run executable launcher
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
