"""Fullscreen drag-to-select overlay for choosing a recording region.

The overlay shows a screenshot of the desktop (taken just before it opens) and
dims everything outside the selection, so it works without a compositor.
Prints a JSON result to stdout; errors go to stderr.
"""

import json
import os
import subprocess
import sys
import tempfile
import tkinter as tk
from typing import Any, Dict, Optional

ACCENT = "#e11d48"


def grab_screenshot(width: int, height: int) -> Optional[str]:
    """Capture the whole X screen to a temporary PNG via ffmpeg."""
    display = os.environ.get("DISPLAY", ":0")
    fd, path = tempfile.mkstemp(prefix="rec-select-", suffix=".png")
    os.close(fd)
    proc = subprocess.run(
        [
            "ffmpeg", "-y", "-loglevel", "error",
            "-f", "x11grab", "-video_size", f"{width}x{height}", "-i", f"{display}+0,0",
            "-frames:v", "1", path,
        ],
        capture_output=True,
        text=True,
        timeout=15,
    )
    if proc.returncode != 0:
        print(f"screenshot failed: {proc.stderr.strip()}", file=sys.stderr)
        os.unlink(path)
        return None
    return path


class ScreenRegionSelector:
    def __init__(self) -> None:
        self.root = tk.Tk()
        self.root.withdraw()
        self.sw = self.root.winfo_screenwidth()
        self.sh = self.root.winfo_screenheight()

        shot = grab_screenshot(self.sw, self.sh)
        self.bg_image = None
        if shot:
            self.bg_image = tk.PhotoImage(file=shot)
            os.unlink(shot)

        self.root.title("Select Recording Area")
        self.root.attributes("-fullscreen", True)
        self.root.attributes("-topmost", True)
        self.canvas = tk.Canvas(self.root, highlightthickness=0, cursor="crosshair", bg="#000000")
        self.canvas.pack(fill=tk.BOTH, expand=True)

        if self.bg_image:
            self.canvas.create_image(0, 0, image=self.bg_image, anchor="nw")

        # Four dimming panels around the selection; initially cover everything.
        self.shades = [
            self.canvas.create_rectangle(0, 0, 0, 0, fill="#000000", stipple="gray50", width=0)
            for _ in range(4)
        ]
        self._layout_shades(0, 0, 0, 0)
        self.rect_id = self.canvas.create_rectangle(0, 0, 0, 0, outline=ACCENT, width=2, state="hidden")
        self.size_id = self.canvas.create_text(0, 0, fill="#ffffff", font=("DejaVu Sans", 12, "bold"), state="hidden")
        self.hint_id = self.canvas.create_text(
            self.sw // 2, 30,
            text="Drag to select  ·  Enter/Space confirm  ·  Esc cancel",
            fill="#ffffff",
            font=("DejaVu Sans", 13, "bold"),
        )

        self.start_x = self.start_y = 0
        self.result: Dict[str, Any] = {"cancelled": True}

        self.canvas.bind("<ButtonPress-1>", self.on_down)
        self.canvas.bind("<B1-Motion>", self.on_drag)
        self.canvas.bind("<ButtonRelease-1>", self.on_up)
        self.canvas.bind("<Button-3>", lambda e: self.cancel())
        self.root.bind("<Escape>", lambda e: self.cancel())
        self.root.bind("q", lambda e: self.cancel())
        self.root.bind("<Return>", lambda e: self.confirm())
        self.root.bind("<space>", lambda e: self.confirm())

        self.root.deiconify()
        self.root.after(50, self._grab_focus)

    def _grab_focus(self) -> None:
        self.root.focus_force()
        try:
            self.root.grab_set_global()
        except tk.TclError:
            pass

    def _layout_shades(self, x1: int, y1: int, x2: int, y2: int) -> None:
        top, bottom, left, right = self.shades
        self.canvas.coords(top, 0, 0, self.sw, y1)
        self.canvas.coords(bottom, 0, y2, self.sw, self.sh)
        self.canvas.coords(left, 0, y1, x1, y2)
        self.canvas.coords(right, x2, y1, self.sw, y2)

    def _clamp(self, e: tk.Event):
        return max(0, min(self.sw, e.x)), max(0, min(self.sh, e.y))

    def _update(self, cx: int, cy: int) -> None:
        x1, y1 = min(self.start_x, cx), min(self.start_y, cy)
        x2, y2 = max(self.start_x, cx), max(self.start_y, cy)
        w, h = x2 - x1, y2 - y1
        self._layout_shades(x1, y1, x2, y2)
        self.canvas.coords(self.rect_id, x1, y1, x2, y2)
        self.canvas.itemconfig(self.rect_id, state="normal")
        label_y = y1 - 14 if y1 > 60 else y2 + 14
        self.canvas.coords(self.size_id, x1 + w // 2, label_y)
        self.canvas.itemconfig(self.size_id, text=f"{w} × {h}", state="normal")
        if w >= 20 and h >= 20:
            self.result = {
                "cancelled": False,
                "x": x1,
                "y": y1,
                "width": w - (w % 2),
                "height": h - (h % 2),
            }
        else:
            self.result = {"cancelled": True}

    def on_down(self, e: tk.Event) -> None:
        self.start_x, self.start_y = self._clamp(e)
        self._update(self.start_x, self.start_y)

    def on_drag(self, e: tk.Event) -> None:
        self._update(*self._clamp(e))

    def on_up(self, e: tk.Event) -> None:
        self._update(*self._clamp(e))
        if not self.result["cancelled"]:
            self.canvas.itemconfig(self.hint_id, text="Enter/Space to confirm  ·  drag again to redo  ·  Esc cancel")

    def confirm(self) -> None:
        if not self.result.get("cancelled", True):
            self.root.destroy()

    def cancel(self) -> None:
        self.result = {"cancelled": True}
        self.root.destroy()

    def run(self) -> Dict[str, Any]:
        self.root.mainloop()
        return self.result


if __name__ == "__main__":
    print(json.dumps(ScreenRegionSelector().run()))
