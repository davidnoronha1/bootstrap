"""ScreenRec - one big record button, three targets, and an Advanced screen."""

import json
import os
from pathlib import Path
import subprocess
import shutil
import sys
import threading
import time
from typing import Optional

from textual import work
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Grid, Horizontal, Vertical, VerticalScroll
from textual.screen import Screen
from textual.widgets import Button, Checkbox, Input, Label, Select, Static

from app.capture_targets import get_screen_resolution, pick_window_interactively
from app.config import (
    CONTAINERS,
    CPU_PRESETS,
    FPS_OPTIONS,
    NVENC_PRESETS,
    VIDEO_CODECS,
    RecorderConfig,
)
from app.logs import write_failure_log
from app.recorder import FFmpegRecorder, RecordingResult, RecordingStats

TARGET_LABELS = {"screen": "Screen", "window": "Window", "region": "Selection"}


def _preset_options(codec: str):
    if "nvenc" in codec:
        return [(p, p.split()[0]) for p in NVENC_PRESETS]
    return [(p, p) for p in CPU_PRESETS]


class AdvancedScreen(Screen):
    """Full-page settings; every change is saved immediately."""

    BINDINGS = [
        Binding("escape", "close", "Back"),
        Binding("a", "close", "Back", show=False),
    ]

    def __init__(self, config: RecorderConfig) -> None:
        super().__init__()
        self.config = config

    def compose(self) -> ComposeResult:
        c = self.config
        presets = _preset_options(c.video_codec)
        preset_values = [v for _, v in presets]
        preset = c.video_preset if c.video_preset in preset_values else preset_values[0]

        yield Static("ADVANCED", id="adv-title")
        with VerticalScroll(id="adv-body"):
            with Grid(id="adv-grid"):
                yield Label("Save to")
                yield Input(c.output_dir, id="in-output-dir")
                yield Label("File prefix")
                yield Input(c.filename_prefix, id="in-prefix")
                yield Label("Container")
                yield Select([(f".{x}", x) for x in CONTAINERS], value=c.container, id="sel-container", allow_blank=False)
                yield Label("Video codec")
                yield Select(VIDEO_CODECS, value=c.video_codec, id="sel-vcodec", allow_blank=False)
                yield Label("Preset")
                yield Select(presets, value=preset, id="sel-preset", allow_blank=False)
                yield Label("Framerate")
                yield Select([(f"{f} fps", f) for f in FPS_OPTIONS], value=c.framerate, id="sel-fps", allow_blank=False)
                yield Label("Quality (CRF)")
                yield Input(str(c.crf), id="in-crf", type="integer", placeholder="0-51, lower = better")
                yield Label("Audio")
                yield Select(
                    [("None", "none"), ("System audio", "desktop"), ("Microphone", "mic")],
                    value=c.audio_mode,
                    id="sel-audio",
                    allow_blank=False,
                )
                yield Label("Cursor")
                yield Checkbox("Record mouse pointer", value=c.draw_mouse, id="chk-mouse")
                yield Label("Extra ffmpeg args")
                yield Input(c.extra_ffmpeg_args, id="in-extra", placeholder="e.g. -tune zerolatency")
            with Horizontal(id="adv-actions"):
                yield Button("Open folder", id="btn-open-folder")
                yield Button("Back", id="btn-back", variant="primary")

    def on_select_changed(self, event: Select.Changed) -> None:
        if event.value == Select.BLANK:
            return
        sid, val = event.select.id, event.value
        if sid == "sel-container":
            self.config.container = str(val)
        elif sid == "sel-vcodec":
            self.config.video_codec = str(val)
            opts = _preset_options(str(val))
            default = "p4" if "nvenc" in str(val) else "veryfast"
            preset = self.query_one("#sel-preset", Select)
            preset.set_options(opts)
            preset.value = default
            self.config.video_preset = default
        elif sid == "sel-preset":
            self.config.video_preset = str(val)
        elif sid == "sel-fps":
            self.config.framerate = int(val)
        elif sid == "sel-audio":
            self.config.audio_mode = str(val)
        self.config.save()

    def on_input_changed(self, event: Input.Changed) -> None:
        iid, val = event.input.id, event.value
        if iid == "in-output-dir":
            self.config.output_dir = val
        elif iid == "in-prefix":
            self.config.filename_prefix = val
        elif iid == "in-extra":
            self.config.extra_ffmpeg_args = val
        elif iid == "in-crf":
            try:
                self.config.crf = max(0, min(51, int(val)))
            except ValueError:
                return
        self.config.save()

    def on_checkbox_changed(self, event: Checkbox.Changed) -> None:
        self.config.draw_mouse = event.value
        self.config.save()

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "btn-back":
            self.action_close()
        elif event.button.id == "btn-open-folder":
            self.app.action_open_folder()

    def action_close(self) -> None:
        self.app.pop_screen()


class ScreenRecApp(App):
    CSS_PATH = "styles.tcss"
    TITLE = "ScreenRec"

    BINDINGS = [
        Binding("r", "toggle_record", "Record/Stop"),
        Binding("f9", "toggle_record", "Record/Stop", show=False),
        Binding("1", "target('screen')", "Screen"),
        Binding("2", "target('window')", "Window"),
        Binding("3", "target('region')", "Selection"),
        Binding("a", "advanced", "Advanced"),
        Binding("o", "open_folder", "Open folder"),
        Binding("escape", "handle_escape", "Stop/Quit"),
        Binding("q", "quit_app", "Quit", show=False),
    ]

    def __init__(self) -> None:
        super().__init__()
        self.config = RecorderConfig.load()
        self.recorder = FFmpegRecorder(self.config)
        self.is_recording = False
        self._last_stats_render = 0.0
        self._tray: Optional[subprocess.Popen] = None

    def compose(self) -> ComposeResult:
        with Vertical(id="main"):
            yield Button("● REC", id="btn-record")
            with Horizontal(id="targets"):
                yield Button("Screen", id="t-screen", classes="target")
                yield Button("Window", id="t-window", classes="target")
                yield Button("Selection", id="t-region", classes="target")
            yield Static("", id="target-info")
            with Horizontal(id="links"):
                yield Button("Open folder", id="btn-folder", classes="link")
                yield Button("Advanced ›", id="btn-advanced", classes="link")
        yield Static("", id="statusbar")

    def on_mount(self) -> None:
        self._set_target(self.config.target_type)
        self._set_status("IDLE", "Ready")
        self.query_one("#btn-record", Button).focus()
        self.set_interval(0.5, self._watch_ffmpeg)

    # ---- status bar -------------------------------------------------------

    def _set_status(self, badge: str, text: str, state: str = "idle") -> None:
        bar = self.query_one("#statusbar", Static)
        for cls in ("idle", "recording", "error"):
            bar.set_class(cls == state, cls)
        bar.update(f"[b] {badge} [/b] {text}")
        self._set_terminal_title("rec" if badge == "IDLE" else f"{badge} {text.split(' · ')[0]} - rec")
        if state == "recording":
            self._tray_send(f"label {text.split(' · ')[0]}")

    # ---- outside the terminal: window title, tray icon, desktop notifications

    def _set_terminal_title(self, title: str) -> None:
        driver = getattr(self, "_driver", None)
        if driver is not None:
            driver.write(f"\x1b]2;{title}\x07")

    def _tray_start(self) -> None:
        try:
            self._tray = subprocess.Popen(
                [sys.executable, str(Path(__file__).parent / "tray.py")],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                bufsize=1,
            )
        except Exception:
            self._tray = None
            return
        tray = self._tray

        def read_clicks() -> None:
            for line in tray.stdout:
                if line.strip() == "stop":
                    self.call_from_thread(self._stop_from_tray)

        threading.Thread(target=read_clicks, daemon=True).start()

    def _tray_send(self, line: str) -> None:
        if self._tray and self._tray.poll() is None:
            try:
                self._tray.stdin.write(line + "\n")
                self._tray.stdin.flush()
            except (BrokenPipeError, OSError):
                pass

    def _tray_stop(self) -> None:
        if self._tray:
            self._tray_send("quit")
            try:
                self._tray.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self._tray.kill()
            self._tray = None

    def _stop_from_tray(self) -> None:
        if self.is_recording:
            self.stop_recording()

    def _desktop_notify(self, summary: str, body: str, urgent: bool = False) -> None:
        if not shutil.which("notify-send"):
            return
        cmd = ["notify-send", "-a", "rec", "-u", "critical" if urgent else "normal", summary, body]
        subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def _fail(self, what: str, err: str, log_path: str) -> None:
        where = f" · log: {log_path}" if log_path else ""
        self._desktop_notify(f"rec: {what}", f"{err.splitlines()[0] if err else ''}\n{log_path}".strip(), urgent=True)
        self.notify(f"{what}: {err.splitlines()[0] if err else 'unknown error'}", severity="error", timeout=8)
        self._set_status("FAILED", f"{what}{where}", "error")

    # ---- target selection -------------------------------------------------

    def _set_target(self, target: str) -> None:
        self.config.target_type = target
        for t in TARGET_LABELS:
            self.query_one(f"#t-{t}", Button).set_class(t == target, "active")
        self._refresh_info()
        self.config.save()

    def _refresh_info(self) -> None:
        c = self.config
        if c.target_type == "screen":
            w, h = get_screen_resolution()
            what = f"Full screen {w}x{h}"
        elif c.target_type == "window":
            what = f"Window: {c.window_title or c.window_id or '(none)'}"
        else:
            what = f"Selection {c.region_width}x{c.region_height} at +{c.region_x}+{c.region_y}"
        out = os.path.expanduser(c.output_dir).replace(str(Path.home()), "~", 1)
        codec = "H.264" if c.video_codec == "libx264" else c.video_codec
        self.query_one("#target-info", Static).update(
            f"{what}\n[dim]{out} · .{c.container} · {codec} · {c.framerate} fps[/dim]"
        )

    def action_target(self, target: str) -> None:
        if self.is_recording:
            return
        if target == "screen":
            self._set_target("screen")
        elif target == "window":
            self.pick_window()
        elif target == "region":
            self.pick_region()

    @work(exclusive=True, thread=True)
    def pick_window(self) -> None:
        self.call_from_thread(self.notify, "Click the window to record…", timeout=3)
        win, err = pick_window_interactively()
        if not win:
            if err:
                log = write_failure_log("pick-window", err)
                self.call_from_thread(self._fail, "Window pick failed", err, log)
            else:
                self.call_from_thread(self.notify, "No window picked", severity="warning")
            return
        self.config.window_id = win.id
        self.config.window_title = win.title or win.id
        self.call_from_thread(self._set_target, "window")

    @work(exclusive=True, thread=True)
    def pick_region(self) -> None:
        use_slop = shutil.which("slop") is not None
        hint = "Drag a box (click = whole window), Esc cancels" if use_slop else "Drag a box, then press Enter"
        self.call_from_thread(self.notify, hint, timeout=3)
        try:
            res = self._select_with_slop() if use_slop else self._select_with_overlay()
        except Exception as e:
            log = write_failure_log("select-region", str(e))
            self.call_from_thread(self._fail, "Selection failed", str(e).splitlines()[0], log)
            return
        if res is None:
            self.call_from_thread(self.notify, "Selection cancelled", severity="warning")
            return
        x, y, w, h = res
        self.config.region_x = x
        self.config.region_y = y
        self.config.region_width = w - (w % 2)
        self.config.region_height = h - (h % 2)
        self.call_from_thread(self._set_target, "region")

    @staticmethod
    def _select_with_slop():
        """Native X11 selection via slop. Returns (x, y, w, h), or None if cancelled."""
        proc = subprocess.run(
            ["slop", "-f", "%x %y %w %h", "-b", "3", "-c", "0.88,0.11,0.28,1"],
            capture_output=True,
            text=True,
            timeout=300,
        )
        if proc.returncode != 0:
            if "cancel" in proc.stderr.lower():
                return None
            raise RuntimeError(f"slop exited {proc.returncode}\n\n--- slop stderr ---\n{proc.stderr}")
        x, y, w, h = (int(v) for v in proc.stdout.split())
        return (x, y, w, h) if w >= 16 and h >= 16 else None

    @staticmethod
    def _select_with_overlay():
        """Fallback when slop isn't installed: Tk overlay over a desktop screenshot."""
        picker = Path(__file__).parent / "region_selector.py"
        proc = subprocess.run([sys.executable, str(picker)], capture_output=True, text=True, timeout=300)
        if proc.returncode != 0:
            raise RuntimeError(f"selector exited {proc.returncode}\n\n--- selector stderr ---\n{proc.stderr}")
        res = json.loads(proc.stdout.strip() or "{}")
        if res.get("cancelled", True):
            return None
        return res["x"], res["y"], res["width"], res["height"]

    # ---- buttons / actions ------------------------------------------------

    def on_button_pressed(self, event: Button.Pressed) -> None:
        bid = event.button.id or ""
        if bid == "btn-record":
            self.action_toggle_record()
        elif bid.startswith("t-"):
            self.action_target(bid[2:])
        elif bid == "btn-folder":
            self.action_open_folder()
        elif bid == "btn-advanced":
            self.action_advanced()

    def action_advanced(self) -> None:
        if self.is_recording or isinstance(self.screen, AdvancedScreen):
            return
        self.push_screen(AdvancedScreen(self.config), lambda _: self._refresh_info())

    def action_toggle_record(self) -> None:
        if self.is_recording:
            self.stop_recording()
        else:
            self.start_recording()

    def action_handle_escape(self) -> None:
        if self.is_recording:
            self.stop_recording()
        else:
            self.action_quit_app()

    def action_quit_app(self) -> None:
        if self.is_recording:
            self.stop_recording()
        self._tray_stop()
        self._set_terminal_title("")
        self.config.save()
        self.exit()

    def action_open_folder(self) -> None:
        out_dir = os.path.expanduser(self.config.output_dir)
        os.makedirs(out_dir, exist_ok=True)
        try:
            subprocess.Popen(["xdg-open", out_dir], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception as e:
            self.notify(f"Failed: {e}", severity="error")

    # ---- recording --------------------------------------------------------

    def start_recording(self) -> None:
        if self.config.target_type == "window" and not self.config.window_id:
            self.notify("Pick a window first", severity="warning")
            return
        self.recorder = FFmpegRecorder(self.config)
        self.recorder.on_stats_update = self._on_stats
        if not self.recorder.start():
            err = self.recorder.stats.error_message or "Could not start FFmpeg."
            self._fail("Recording failed to start", err, self.recorder.log_path)
            return
        self.is_recording = True
        self._tray_start()
        btn = self.query_one("#btn-record", Button)
        btn.label = "■ STOP  00:00:00"
        btn.add_class("recording")
        self.query_one("#targets").disabled = True
        self.query_one("#btn-advanced").disabled = True
        self._set_status("● REC", f"00:00:00 · {Path(self.recorder.stats.file_path).name}", "recording")

    def stop_recording(self) -> None:
        res: RecordingResult = self.recorder.stop()
        self.is_recording = False
        self._tray_stop()
        btn = self.query_one("#btn-record", Button)
        btn.label = "● REC"
        btn.remove_class("recording")
        self.query_one("#targets").disabled = False
        self.query_one("#btn-advanced").disabled = False
        if res.success:
            name = Path(res.file_path).name
            self.notify(f"Saved {name} ({res.duration_str}, {res.size_str})", timeout=5)
            self._set_status("SAVED", f"{name} · {res.duration_str} · {res.size_str}")
            self._desktop_notify("rec: recording saved", f"{name}\n{res.duration_str} · {res.size_str}")
        else:
            self._fail("Recording failed", res.error or "", res.log_path)

    def _watch_ffmpeg(self) -> None:
        """ffmpeg exiting on its own (bad geometry, missing device…) ends the recording."""
        if self.is_recording and not self.recorder.is_alive():
            self.stop_recording()

    def _on_stats(self, stats: RecordingStats) -> None:
        now = time.time()
        if now - self._last_stats_render < 0.25:
            return
        self._last_stats_render = now

        def update() -> None:
            if self.is_recording:
                self.query_one("#btn-record", Button).label = (
                    f"■ STOP  {stats.elapsed_str}  ·  {stats.size_str}"
                )
                self._set_status(
                    "● REC",
                    f"{stats.elapsed_str} · {stats.fps:.0f} fps · {stats.size_str} · "
                    f"{Path(stats.file_path).name}",
                    "recording",
                )

        try:
            self.call_from_thread(update)
        except Exception:
            pass
