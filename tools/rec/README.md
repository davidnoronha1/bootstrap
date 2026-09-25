# rec

A minimal FFmpeg screen recorder TUI (Textual, X11).

```bash
./rec            # or: python3 main.py
```

Requires Python 3.10+, `ffmpeg` (x11grab + libx264), `xwininfo`, `pip install -r requirements.txt`.
Selection uses `slop` (`sudo apt install slop`) and falls back to a Tkinter overlay (`python3-tk`); the tray icon uses PyGObject (`python3-gi`) and,
on GNOME, the AppIndicator extension (enabled by default on Ubuntu).

## Using it

```
┌──────────────────────────────────────┐
│                ● REC                 │
└──────────────────────────────────────┘
 [ Screen ]   [ Window ]   [ Selection ]
      Full screen 1920x1080
   ~/Videos · .mkv · H.264 · 30 fps
      Open folder   Advanced ›
```

- **Big button** starts/stops recording; while recording it shows elapsed time and file size.
- **Screen** records the full display.
- **Window** turns the cursor into a crosshair; click the window to record.
- **Selection** lets you drag a box on the screen (with `slop`, a single click picks a whole window).
- **While recording** a red dot with the elapsed time shows in the system tray / GNOME top bar
  (click it to stop), and the terminal's window title reads `● REC 00:01:23`. A desktop
  notification pops up when the file is saved or recording fails.
- **Advanced ›** opens a settings page: save folder, file prefix, container, codec,
  preset, framerate, CRF, audio (none / system / mic), cursor, extra ffmpeg args.

Defaults: save to `~/Videos`, `.mkv`, H.264 (`libx264`, `veryfast`, CRF 23), 30 fps, no audio.
Settings persist in `~/.config/rec/config.json`.

## Keys

| Key | Action |
|-----|--------|
| `r` / `F9` | Record / stop |
| `1` `2` `3` | Screen / Window / Selection |
| `a` | Advanced settings (`Esc` to go back) |
| `o` | Open output folder |
| `Esc` | Stop recording, or quit when idle |

Failures (ffmpeg, window pick, selection) write a log to `~/.local/state/rec/logs/`; the status bar shows the path.

## Layout

```
rec                   launcher
main.py               entrypoint
app/ui.py             TUI (main screen + Advanced screen)
app/styles.tcss       styles
app/recorder.py       ffmpeg command builder / process control
app/capture_targets.py screen size, window picking
app/region_selector.py Tkinter drag-to-select overlay
app/tray.py           tray icon (StatusNotifierItem over D-Bus, PyGObject only)
app/logs.py           failure logs
app/config.py         defaults and persistence
```
