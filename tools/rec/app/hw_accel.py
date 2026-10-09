"""Hardware acceleration detection and probing for FFmpeg encoders."""

import os
from pathlib import Path
import shutil
import subprocess
from typing import Dict, Optional, Tuple

_PROBE_CACHE: Dict[Tuple[str, int, int], bool] = {}

# Candidate H.264 hardware encoders in order of preference for desktop recording
CANDIDATE_H264_HW_ENCODERS = [
    "h264_nvenc",
    "h264_qsv",
    "h264_vaapi",
]

HW_ENCODER_NAMES = {
    "h264_nvenc": "NVENC H.264",
    "hevc_nvenc": "NVENC HEVC",
    "h264_qsv": "QSV H.264",
    "hevc_qsv": "QSV HEVC",
    "h264_vaapi": "VAAPI H.264",
    "hevc_vaapi": "VAAPI HEVC",
    "h264_amf": "AMF H.264",
    "hevc_amf": "AMF HEVC",
    "h264_v4l2m2m": "V4L2 H.264",
}


def is_hw_encoder(codec: str) -> bool:
    """Check if the given codec string represents a hardware-accelerated encoder."""
    if not codec:
        return False
    codec_lower = codec.lower()
    return any(tag in codec_lower for tag in ("nvenc", "qsv", "vaapi", "amf", "v4l2m2m", "videotoolbox"))


def probe_encoder_support(codec: str, width: int, height: int) -> bool:
    """Test if FFmpeg can encode a single frame at (width x height) using `codec`."""
    if not shutil.which("ffmpeg"):
        return False

    # Snap to even numbers
    width = max(32, width - (width % 2))
    height = max(32, height - (height % 2))

    cache_key = (codec, width, height)
    if cache_key in _PROBE_CACHE:
        return _PROBE_CACHE[cache_key]

    cmd = [
        "ffmpeg",
        "-v", "error",
        "-f", "lavfi",
        "-i", f"testsrc=size={width}x{height}:rate=30",
        "-frames:v", "1",
        "-c:v", codec,
        "-pix_fmt", "yuv420p",
        "-f", "null",
        "-",
    ]

    try:
        res = subprocess.run(
            cmd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=2.0,
        )
        supported = (res.returncode == 0)
    except Exception:
        supported = False

    _PROBE_CACHE[cache_key] = supported
    return supported


def detect_best_hw_encoder(width: int, height: int) -> Optional[str]:
    """Find the best hardware-accelerated H.264 encoder supporting (width x height)."""
    for encoder in CANDIDATE_H264_HW_ENCODERS:
        if probe_encoder_support(encoder, width, height):
            return encoder
    return None


def resolve_video_codec(requested_codec: str, width: int, height: int) -> Tuple[str, bool]:
    """Resolve requested codec ('auto', 'h264_nvenc', 'libx264', etc.) to actual codec and hw flag.

    If requested is 'auto':
      Probes HW accelerated encoders for (width x height). If supported, returns (hw_codec, True).
      Otherwise falls back to ('libx264', False).
    If requested is a specific codec:
      Returns (requested_codec, is_hw_encoder(requested_codec)).
    """
    if requested_codec == "auto":
        hw = detect_best_hw_encoder(width, height)
        if hw:
            return hw, True
        return "libx264", False

    return requested_codec, is_hw_encoder(requested_codec)


def get_encoder_display_label(codec: str, is_hw: bool) -> str:
    """Return user-facing display string showing encoder name and HW acceleration status."""
    if is_hw:
        name = HW_ENCODER_NAMES.get(codec, codec)
        return f"{name} (HW)"

    if codec == "libx264":
        return "H.264 (CPU)"
    elif codec == "libx265":
        return "HEVC (CPU)"
    elif codec == "libvpx-vp9":
        return "VP9 (CPU)"
    elif codec == "copy":
        return "Stream Copy"
    else:
        return f"{codec} (CPU)"
