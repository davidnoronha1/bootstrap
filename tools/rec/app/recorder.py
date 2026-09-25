"""FFmpeg process manager for screen, window, and region recording."""

from dataclasses import dataclass
from datetime import datetime
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import threading
import time
from typing import Callable, List, Optional, Tuple

from app.capture_targets import get_display_env, get_screen_resolution, get_window_by_id
from app.config import RecorderConfig
from app.logs import write_failure_log


@dataclass
class RecordingStats:
    is_recording: bool = False
    elapsed_seconds: float = 0.0
    elapsed_str: str = "00:00:00"
    fps: float = 0.0
    size_bytes: int = 0
    size_str: str = "0 B"
    speed: str = "1.0x"
    frames: int = 0
    file_path: str = ""
    error_message: Optional[str] = None


@dataclass
class RecordingResult:
    success: bool
    file_path: str
    duration_str: str
    size_str: str
    error: Optional[str] = None
    log_path: str = ""


def format_size(bytes_val: int) -> str:
    """Format bytes into human-readable MB / KB."""
    if bytes_val < 1024:
        return f"{bytes_val} B"
    elif bytes_val < 1024 * 1024:
        return f"{bytes_val / 1024:.1f} KB"
    elif bytes_val < 1024 * 1024 * 1024:
        return f"{bytes_val / (1024 * 1024):.2f} MB"
    else:
        return f"{bytes_val / (1024 * 1024 * 1024):.2f} GB"


class FFmpegRecorder:
    def __init__(self, config: RecorderConfig) -> None:
        self.config = config
        self.process: Optional[subprocess.Popen] = None
        self.stats = RecordingStats()
        self._progress_thread: Optional[threading.Thread] = None
        self._stderr_thread: Optional[threading.Thread] = None
        self._stop_requested = threading.Event()
        self._stderr_lines: List[str] = []
        self._start_time: float = 0.0
        self.cmd: List[str] = []
        self.log_path: str = ""
        self.on_stats_update: Optional[Callable[[RecordingStats], None]] = None

    def build_command(self) -> Tuple[List[str], str]:
        """Construct the FFmpeg command line arguments and return (cmd, output_path)."""
        display = get_display_env()
        # Ensure display has .0 if just :0 or :1
        if ":" in display and "." not in display:
            display_base = f"{display}.0"
        else:
            display_base = display

        target_type = self.config.target_type
        crop_x = 0
        crop_y = 0
        width = 1920
        height = 1080

        if target_type == "screen":
            sw, sh = get_screen_resolution()
            width, height = sw, sh
            crop_x, crop_y = 0, 0
        elif target_type == "window":
            # Refresh window geometry live
            win = get_window_by_id(self.config.window_id)
            if win:
                crop_x = max(0, win.x)
                crop_y = max(0, win.y)
                width = win.width
                height = win.height
            else:
                crop_x = max(0, self.config.region_x)
                crop_y = max(0, self.config.region_y)
                width = self.config.region_width
                height = self.config.region_height
        elif target_type == "region":
            crop_x = max(0, self.config.region_x)
            crop_y = max(0, self.config.region_y)
            width = self.config.region_width
            height = self.config.region_height

        # Snap width & height to even numbers (FFmpeg requirement for yuv420p)
        width = max(32, width - (width % 2))
        height = max(32, height - (height % 2))

        # Output file path
        out_dir = Path(os.path.expanduser(self.config.output_dir))
        out_dir.mkdir(parents=True, exist_ok=True)

        timestamp = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
        prefix = self.config.filename_prefix.strip() or "recording"
        ext = self.config.container.lower().strip(".")
        output_filename = f"{prefix}_{timestamp}.{ext}"
        output_path = str(out_dir / output_filename)

        cmd = [
            "ffmpeg",
            "-y",  # Overwrite without asking
            "-video_size", f"{width}x{height}",
            "-framerate", str(self.config.framerate),
            "-f", "x11grab",
            "-draw_mouse", "1" if self.config.draw_mouse else "0",
            "-i", f"{display_base}+{crop_x},{crop_y}",
        ]

        # Audio capture
        if self.config.audio_mode != "none":
            device = "default"
            if self.config.audio_mode == "desktop":
                # PulseAudio monitor or default source
                device = "default"
            elif self.config.audio_device and self.config.audio_device != "none":
                device = self.config.audio_device

            cmd.extend([
                "-f", "pulse",
                "-i", device,
            ])

        # Video encoding parameters
        vcodec = self.config.video_codec
        preset = self.config.video_preset
        crf = str(self.config.crf)

        if vcodec == "libx264":
            cmd.extend([
                "-c:v", "libx264",
                "-preset", preset,
                "-crf", crf,
                "-pix_fmt", "yuv420p",
            ])
        elif vcodec == "h264_nvenc":
            # NVENC presets are p1..p7 or default
            nv_preset = preset.split()[0] if preset.startswith("p") else "p4"
            cmd.extend([
                "-c:v", "h264_nvenc",
                "-preset", nv_preset,
                "-cq", crf,
                "-pix_fmt", "yuv420p",
            ])
        elif vcodec == "libx265":
            cmd.extend([
                "-c:v", "libx265",
                "-preset", preset,
                "-crf", crf,
                "-pix_fmt", "yuv420p",
            ])
        elif vcodec == "hevc_nvenc":
            nv_preset = preset.split()[0] if preset.startswith("p") else "p4"
            cmd.extend([
                "-c:v", "hevc_nvenc",
                "-preset", nv_preset,
                "-cq", crf,
                "-pix_fmt", "yuv420p",
            ])
        elif vcodec == "libvpx-vp9":
            cmd.extend([
                "-c:v", "libvpx-vp9",
                "-crf", crf,
                "-b:v", "0",
                "-pix_fmt", "yuv420p",
            ])
        elif vcodec == "copy":
            cmd.extend(["-c:v", "copy"])
        else:
            cmd.extend(["-c:v", vcodec])

        # Bitrate override if set
        if self.config.video_bitrate.strip():
            cmd.extend(["-b:v", self.config.video_bitrate.strip()])

        # Audio encoding
        if self.config.audio_mode != "none":
            acodec = self.config.audio_codec
            if ext == "webm" and acodec == "aac":
                acodec = "libopus"
            cmd.extend([
                "-c:a", acodec,
                "-b:a", self.config.audio_bitrate,
            ])
        else:
            cmd.extend(["-an"])

        # Container specific optimizations
        if ext == "mp4":
            cmd.extend(["-movflags", "+faststart"])

        # Extra custom ffmpeg arguments
        if self.config.extra_ffmpeg_args.strip():
            cmd.extend(self.config.extra_ffmpeg_args.strip().split())

        # Progress reporting via pipe:1
        cmd.extend([
            "-progress", "pipe:1",
            output_path,
        ])

        return cmd, output_path

    def start(self) -> bool:
        """Start the recording subprocess and monitoring threads."""
        if self.process is not None:
            return False

        if not shutil.which("ffmpeg"):
            self.stats.error_message = "FFmpeg executable not found in PATH."
            self.log_path = write_failure_log("ffmpeg", self.stats.error_message)
            return False

        out_dir = Path(os.path.expanduser(self.config.output_dir))
        try:
            out_dir.mkdir(parents=True, exist_ok=True)
        except OSError as e:
            self.stats.error_message = f"Can't create output folder {out_dir}: {e.strerror}"
            self.log_path = write_failure_log("ffmpeg", self.stats.error_message)
            return False
        if not os.access(out_dir, os.W_OK):
            try:
                import pwd
                owner = pwd.getpwuid(out_dir.stat().st_uid).pw_name
            except (KeyError, OSError):
                owner = "another user"
            self.stats.error_message = (
                f"Can't write to {out_dir} (owned by {owner}). "
                f"Fix: sudo chown -R $USER: {out_dir}  or pick another folder in Advanced."
            )
            self.log_path = write_failure_log("ffmpeg", self.stats.error_message)
            return False

        cmd, output_path = self.build_command()
        self.cmd = cmd
        self.stats = RecordingStats(
            is_recording=True,
            file_path=output_path,
        )
        self._stop_requested.clear()
        self._stderr_lines.clear()
        self._start_time = time.time()

        try:
            self.process = subprocess.Popen(
                cmd,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                bufsize=1,
            )
        except Exception as e:
            self.stats.is_recording = False
            self.stats.error_message = f"Failed to start FFmpeg: {e}"
            self.log_path = write_failure_log("ffmpeg", self._log_details(self.stats.error_message))
            return False

        # Launch progress reading thread (stdout)
        self._progress_thread = threading.Thread(target=self._monitor_progress, daemon=True)
        self._progress_thread.start()

        # Launch stderr collector thread
        self._stderr_thread = threading.Thread(target=self._collect_stderr, daemon=True)
        self._stderr_thread.start()

        return True

    def _monitor_progress(self) -> None:
        """Read key=value updates from FFmpeg -progress pipe:1."""
        if not self.process or not self.process.stdout:
            return

        last_callback_time = 0.0
        for line in iter(self.process.stdout.readline, ""):
            line = line.strip()
            if not line:
                continue

            if "=" in line:
                key, val = line.split("=", 1)
                key = key.strip()
                val = val.strip()

                if key == "out_time":
                    # Wall clock, not ffmpeg's out_time (which starts slightly negative)
                    secs = max(0, int(time.time() - self._start_time))
                    self.stats.elapsed_seconds = float(secs)
                    self.stats.elapsed_str = f"{secs // 3600:02d}:{secs % 3600 // 60:02d}:{secs % 60:02d}"
                elif key == "fps":
                    try:
                        self.stats.fps = float(val)
                    except ValueError:
                        pass
                elif key == "total_size":
                    try:
                        if val != "N/A":
                            self.stats.size_bytes = int(val)
                            self.stats.size_str = format_size(self.stats.size_bytes)
                    except ValueError:
                        pass
                elif key == "speed":
                    self.stats.speed = val
                elif key == "frame":
                    try:
                        self.stats.frames = int(val)
                    except ValueError:
                        pass
                elif key == "progress":
                    now = time.time()
                    if (now - last_callback_time >= 0.25) or val == "end":
                        last_callback_time = now
                        if self.on_stats_update:
                            self.on_stats_update(self.stats)
                    if val == "end":
                        break

    def _collect_stderr(self) -> None:
        """Capture stderr lines to diagnose failures."""
        if not self.process or not self.process.stderr:
            return

        for line in iter(self.process.stderr.readline, ""):
            self._stderr_lines.append(line)
            # Check for immediate startup errors
            if "Error" in line or "Unknown" in line or "Invalid" in line:
                self.stats.error_message = line.strip()

    def stop(self) -> RecordingResult:
        """Gracefully stop FFmpeg and finalize media container."""
        if not self.process:
            return RecordingResult(
                success=False,
                file_path=self.stats.file_path,
                duration_str="00:00:00",
                size_str="0 B",
                error="No active recording process.",
            )

        self._stop_requested.set()
        proc = self.process
        self.process = None

        # Step 1: Send 'q' to stdin for clean container closure
        try:
            if proc.stdin and not proc.stdin.closed:
                proc.stdin.write("q\n")
                proc.stdin.flush()
        except Exception:
            pass

        # Step 2: Wait up to 3 seconds for normal exit
        try:
            proc.wait(timeout=3.0)
        except subprocess.TimeoutExpired:
            # Step 3: Send SIGINT (Ctrl+C)
            try:
                proc.send_signal(signal.SIGINT)
                proc.wait(timeout=2.0)
            except Exception:
                # Step 4: Kill if hung
                try:
                    proc.kill()
                    proc.wait(timeout=1.0)
                except Exception:
                    pass

        self.stats.is_recording = False
        # Let the stderr reader drain so the log has ffmpeg's final words
        if self._stderr_thread:
            self._stderr_thread.join(timeout=1.0)

        # Check output file
        file_path = self.stats.file_path
        file_exists = os.path.exists(file_path)
        file_size = os.path.getsize(file_path) if file_exists else 0

        # Update final size string
        size_str = format_size(file_size)
        duration_str = self.stats.elapsed_str

        if file_exists and file_size > 1024:
            return RecordingResult(
                success=True,
                file_path=file_path,
                duration_str=duration_str,
                size_str=size_str,
            )
        else:
            err = self.stats.error_message or "Recording failed or output file is empty."
            return RecordingResult(
                success=False,
                file_path=file_path,
                duration_str=duration_str,
                size_str=size_str,
                error=err,
                log_path=write_failure_log("ffmpeg", self._log_details(err, proc.returncode)),
            )

    def is_alive(self) -> bool:
        return self.process is not None and self.process.poll() is None

    def _log_details(self, err: str, returncode: Optional[int] = None) -> str:
        return (
            f"error: {err}\nexit code: {returncode}\n"
            f"target: {self.config.target_type}\n"
            f"command: {' '.join(self.cmd)}\n\n--- ffmpeg stderr ---\n"
            + "".join(self._stderr_lines)
        )
