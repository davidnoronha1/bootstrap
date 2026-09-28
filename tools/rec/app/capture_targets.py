"""Screen, Window, and Region detection and selection utilities."""

from dataclasses import dataclass
import os
import re
import shutil
import subprocess
from typing import List, Optional, Tuple


@dataclass
class WindowInfo:
    id: str
    title: str
    x: int
    y: int
    width: int
    height: int

    @property
    def display_label(self) -> str:
        short_title = self.title if len(self.title) <= 50 else self.title[:47] + "..."
        return f"{short_title} ({self.width}x{self.height})"


def get_display_env() -> str:
    """Get the current DISPLAY environment variable, default to :0 or :1."""
    return os.environ.get("DISPLAY", ":0")


def get_native_screen_geometry() -> Tuple[int, int, int, int]:
    """Detect primary or active screen native geometry (width, height, offset_x, offset_y).

    Queries xrandr for connected monitors and their preferred (native) EDID mode
    and offset. Falls back to xdpyinfo, tkinter, or (1920, 1080, 0, 0).
    """
    # 1. Try xrandr for monitor-specific native resolution and offset
    try:
        out = subprocess.check_output(["xrandr", "--current"], stderr=subprocess.DEVNULL, text=True)
        lines = out.splitlines()
        monitors = []
        i = 0
        while i < len(lines):
            line = lines[i]
            if " connected" in line:
                name = line.split()[0]
                is_primary = " primary " in line
                m_geom = re.search(r"(\d+)x(\d+)\+(\d+)\+(\d+)", line)
                geom = tuple(map(int, m_geom.groups())) if m_geom else None

                preferred_res = None
                current_res = None
                j = i + 1
                while j < len(lines) and (lines[j].startswith("   ") or lines[j].startswith("\t")):
                    mode_line = lines[j]
                    m_mode = re.search(r"^\s*(\d+)x(\d+)", mode_line)
                    if m_mode:
                        mw, mh = int(m_mode.group(1)), int(m_mode.group(2))
                        if "+" in mode_line and not preferred_res:
                            preferred_res = (mw, mh)
                        if "*" in mode_line and not current_res:
                            current_res = (mw, mh)
                    j += 1

                w, h = preferred_res or current_res or ((geom[0], geom[1]) if geom else (1920, 1080))
                gx = geom[2] if geom else 0
                gy = geom[3] if geom else 0
                w = max(32, w - (w % 2))
                h = max(32, h - (h % 2))
                monitors.append({"name": name, "primary": is_primary, "x": gx, "y": gy, "width": w, "height": h})
                i = j - 1
            i += 1

        if monitors:
            target = next((m for m in monitors if m["primary"]), monitors[0])
            return target["width"], target["height"], target["x"], target["y"]
    except Exception:
        pass

    # 2. Try xdpyinfo for X11 screen dimensions
    try:
        out = subprocess.check_output(["xdpyinfo"], stderr=subprocess.DEVNULL, text=True)
        m = re.search(r"dimensions:\s+(\d+)x(\d+)\s+pixels", out)
        if m:
            w = int(m.group(1))
            h = int(m.group(2))
            return max(32, w - (w % 2)), max(32, h - (h % 2)), 0, 0
    except Exception:
        pass

    # 3. Fallback to tkinter
    try:
        import tkinter as tk
        root = tk.Tk()
        root.withdraw()
        w = root.winfo_screenwidth()
        h = root.winfo_screenheight()
        root.destroy()
        if w > 0 and h > 0:
            return max(32, w - (w % 2)), max(32, h - (h % 2)), 0, 0
    except Exception:
        pass

    return 1920, 1080, 0, 0


def get_screen_resolution() -> Tuple[int, int]:
    """Detect screen native resolution (width, height)."""
    w, h, _, _ = get_native_screen_geometry()
    return w, h


def parse_xwininfo_output(text: str) -> Optional[WindowInfo]:
    """Parse text output from xwininfo into a WindowInfo object."""
    wid = None
    title = ""
    x = 0
    y = 0
    w = 0
    h = 0

    id_match = re.search(r"xwininfo:\s+Window\s+id:\s+(0x[0-9a-fA-F]+)\s*(?:\"([^\"]*)\")?", text)
    if id_match:
        wid = id_match.group(1)
        title = id_match.group(2) or ""

    for line in text.splitlines():
        line = line.strip()
        if line.startswith("Absolute upper-left X:"):
            try:
                x = int(line.split(":")[1].strip())
            except ValueError:
                pass
        elif line.startswith("Absolute upper-left Y:"):
            try:
                y = int(line.split(":")[1].strip())
            except ValueError:
                pass
        elif line.startswith("Width:"):
            try:
                w = int(line.split(":")[1].strip())
            except ValueError:
                pass
        elif line.startswith("Height:"):
            try:
                h = int(line.split(":")[1].strip())
            except ValueError:
                pass

    if wid and w > 0 and h > 0:
        # Snap width & height to even numbers for ffmpeg video encoding
        even_w = w - (w % 2)
        even_h = h - (h % 2)
        return WindowInfo(id=wid, title=title, x=x, y=y, width=even_w, height=even_h)

    return None


def get_window_by_id(wid: str) -> Optional[WindowInfo]:
    """Fetch current up-to-date geometry for a specific window ID."""
    if not wid:
        return None
    try:
        out = subprocess.check_output(["xwininfo", "-id", wid], stderr=subprocess.DEVNULL, text=True)
        return parse_xwininfo_output(out)
    except Exception:
        return None


def list_open_windows() -> List[WindowInfo]:
    """List open visible application windows using xwininfo."""
    windows: List[WindowInfo] = []
    try:
        out = subprocess.check_output(["xwininfo", "-root", "-children"], stderr=subprocess.DEVNULL, text=True)
    except Exception:
        return windows

    # Pattern matches lines like:
    # 0x800017 "Firefox": ("firefox" "Firefox") 1850x1053+70+27 +70+27
    pattern = re.compile(
        r"^\s*(0x[0-9a-fA-F]+)\s+(\"[^\"]+\")?:\s*(\([^)]+\))?\s+(\d+)x(\d+)\+([-]?\d+)\+([-]?\d+)",
        re.M,
    )

    ignored_prefixes = ("@", "mutter", "gnome-shell", "desktop", "x-session-manager")

    for line in out.splitlines():
        m = pattern.search(line)
        if not m:
            continue
        wid, raw_title, _, w_str, h_str, x_str, y_str = m.groups()
        w = int(w_str)
        h = int(h_str)
        x = int(x_str)
        y = int(y_str)

        # Ignore tiny helper windows or off-screen buffers
        if w < 100 or h < 80:
            continue

        title = raw_title.strip('"') if raw_title else ""
        if not title or title.lower() == "has no name":
            continue
        if any(title.lower().startswith(prefix) for prefix in ignored_prefixes):
            continue

        # Adjust dimensions to even
        even_w = w - (w % 2)
        even_h = h - (h % 2)

        windows.append(WindowInfo(id=wid, title=title, x=x, y=y, width=even_w, height=even_h))

    # Reverse order so topmost windows appear first
    windows.reverse()
    return windows


def pick_window_interactively() -> Tuple[Optional[WindowInfo], str]:
    """Let the user click a window (xwininfo). Returns (window, error_details)."""
    try:
        # xwininfo with no arguments allows clicking on a window
        proc = subprocess.run(["xwininfo"], capture_output=True, text=True, timeout=60)
    except Exception as e:
        return None, f"xwininfo failed to run: {e}"
    if proc.returncode == 0 and proc.stdout:
        win = parse_xwininfo_output(proc.stdout)
        if win:
            return win, ""
    return None, (
        f"xwininfo exit code: {proc.returncode}\n\n--- stdout ---\n{proc.stdout}"
        f"\n--- stderr ---\n{proc.stderr}"
    )


def get_audio_sources() -> List[Tuple[str, str]]:
    """Enumerate audio sources via pactl. Returns list of (label, device_name)."""
    sources = [("No Audio", "none"), ("Default Audio", "default")]
    if not shutil.which("pactl"):
        return sources

    try:
        out = subprocess.check_output(["pactl", "list", "sources"], stderr=subprocess.DEVNULL, text=True)
        current_name = ""
        current_desc = ""

        for line in out.splitlines():
            line = line.strip()
            if line.startswith("Name:"):
                current_name = line.split(":", 1)[1].strip()
            elif line.startswith("Description:"):
                current_desc = line.split(":", 1)[1].strip()
                if current_name:
                    is_monitor = "monitor" in current_name.lower()
                    tag = "🔊 System Sound" if is_monitor else "🎙️ Mic"
                    label = f"{tag}: {current_desc}"
                    sources.append((label, current_name))
                    current_name = ""
                    current_desc = ""
    except Exception:
        pass

    return sources
