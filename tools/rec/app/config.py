"""Configuration management and defaults for the recording app."""

from dataclasses import asdict, dataclass, field
import json
import os
from pathlib import Path
from typing import Any, Dict, List

CONFIG_DIR = Path.home() / ".config" / "rec"
CONFIG_FILE = CONFIG_DIR / "config.json"
# Bump to reset output/format settings in older saved configs to new defaults.
CONFIG_VERSION = 2
DEFAULT_OUTPUT_DIR = "~/Videos"

CONTAINERS = ["mkv", "mp4", "webm", "mov", "avi", "gif"]

VIDEO_CODECS = [
    ("libx264 (H.264 CPU - Standard)", "libx264"),
    ("h264_nvenc (NVIDIA NVENC H.264)", "h264_nvenc"),
    ("libx265 (HEVC CPU - High Compression)", "libx265"),
    ("hevc_nvenc (NVIDIA NVENC HEVC)", "hevc_nvenc"),
    ("libvpx-vp9 (VP9 - WebM)", "libvpx-vp9"),
    ("copy (Stream Copy)", "copy"),
]

CPU_PRESETS = [
    "ultrafast",
    "superfast",
    "veryfast",
    "faster",
    "fast",
    "medium",
    "slow",
    "slower",
]

NVENC_PRESETS = [
    "p1 (Fastest)",
    "p2",
    "p3",
    "p4 (Medium)",
    "p5",
    "p6",
    "p7 (Slowest / Best)",
]

FPRESETS = CPU_PRESETS

AUDIO_CODECS = [
    ("aac (AAC Audio - Best for MP4/MKV)", "aac"),
    ("libopus (Opus Audio - Best for WebM/MKV)", "libopus"),
    ("libmp3lame (MP3 Audio)", "libmp3lame"),
    ("flac (Lossless FLAC)", "flac"),
]

FPS_OPTIONS = [15, 24, 30, 60]


@dataclass
class RecorderConfig:
    # Target capture options
    target_type: str = "screen"  # "screen", "window", "region"
    screen_name: str = ":1.0"
    screen_width: int = 1920
    screen_height: int = 1080

    # Window capture
    window_id: str = ""
    window_title: str = ""
    window_geometry: str = ""

    # Region capture
    region_x: int = 0
    region_y: int = 0
    region_width: int = 1280
    region_height: int = 720

    # Audio
    audio_mode: str = "none"  # "none", "desktop", "mic"
    audio_device: str = "default"

    # Destination
    output_dir: str = DEFAULT_OUTPUT_DIR
    filename_prefix: str = "recording"

    # Encoding & Container (Advanced)
    container: str = "mkv"
    video_codec: str = "libx264"
    video_preset: str = "veryfast"
    framerate: int = 30
    crf: int = 23
    video_bitrate: str = ""  # e.g., "4000k"
    audio_codec: str = "aac"
    audio_bitrate: str = "192k"
    draw_mouse: bool = True
    extra_ffmpeg_args: str = ""

    config_version: int = CONFIG_VERSION

    @classmethod
    def load(cls) -> "RecorderConfig":
        if CONFIG_FILE.exists():
            try:
                with open(CONFIG_FILE, "r", encoding="utf-8") as f:
                    data = json.load(f)
                if data.get("config_version", 1) < CONFIG_VERSION:
                    for k in ("output_dir", "filename_prefix", "container", "video_codec", "video_preset"):
                        data.pop(k, None)
                    data["config_version"] = CONFIG_VERSION
                return cls(**{k: v for k, v in data.items() if k in cls.__dataclass_fields__})
            except Exception:
                pass
        return cls()

    def save(self) -> None:
        try:
            CONFIG_DIR.mkdir(parents=True, exist_ok=True)
            with open(CONFIG_FILE, "w", encoding="utf-8") as f:
                json.dump(asdict(self), f, indent=2)
        except Exception as e:
            print(f"Warning: Failed to save config: {e}")
