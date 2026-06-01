# MB Clip Editor (Morgan Quick Clips)

A native macOS app for quickly turning screen recordings and video/GIF files into
trimmed, cropped, scaled, captioned clips for sharing.

- **Record the screen** (ScreenCaptureKit, in-process): full display, a specific
  display, or a draggable region box that floats over fullscreen apps. Optional
  mic, system audio, and cursor.
- **Drop in** `.mp4` / `.gif` (or a batch/queue of them).
- **Visually crop** (4-corner handles), **trim** on a timeline, **scale** (0–1),
  and pick a **quality preset** (High fidelity / Balanced / High optimization).
- **Export** to MP4 / GIF / WebM, or **Web** (`webm` + `gif` in a `*_forweb` folder).
  One-click to a chosen export folder; auto-incrementing names (`clip`, `clip_1`, …).
- **Estimate size** before exporting.
- **Captions** (whisper.cpp): embed a toggleable subtitle track, save a sidecar
  `.srt`, and/or save a plain-text `.txt` transcript.

It's a single Swift file (`Sources/ClipEditor.swift`) compiled with `swiftc`.

## Build

```bash
./build.sh            # → build/Clip Editor.app   (ad-hoc signed)
open "build/Clip Editor.app"
```

Requires Xcode command line tools (`swiftc`) and the macOS 15+ SDK.

## Runtime dependencies (IMPORTANT — the app is NOT self-contained)

The app shells out to command-line tools that are **not bundled**. On the build
machine these come from Homebrew:

```bash
brew install ffmpeg whisper-cpp
./scripts/fetch-model.sh        # downloads the Whisper model (~142 MB)
```

- **ffmpeg / ffprobe** — used for all conversion, recording finalize, audio extract.
  Resolved at runtime from `/opt/homebrew/bin`, `/usr/local/bin`, or `/usr/bin`.
- **whisper-cli** (from `whisper-cpp`) + a **Whisper model** — used for captions.

If these aren't present, conversion/captions silently won't work.

> Note on burn-in: rendering captions *onto* the video needs an ffmpeg built with
> `libass`. Homebrew's ffmpeg may lack it; this app therefore uses **soft/embedded**
> subtitles (`mov_text`) rather than burned-in text.

## Known limitations / TODO before public distribution

This runs on the author's Mac but is **not yet distributable**:

1. **Not self-contained** — ffmpeg/ffprobe/whisper-cli and the model are external.
   To ship, bundle **static** builds of these into `Contents/Resources` and load
   them from the bundle instead of Homebrew. (Bundling ffmpeg built with x264/x265
   makes the distribution **GPL** — provide source/offer accordingly.)
2. **Hard-coded model path** — `gWhisperModel` in `Sources/ClipEditor.swift` points
   at `~/.hermes/skills/media/ffmpeg/models/ggml-base.en.bin`. Make this resolve
   from the app bundle for distribution.
3. **Signing/notarization** — currently ad-hoc / self-signed, so downloaded copies
   are blocked by Gatekeeper. For public download you need an **Apple Developer ID**
   certificate and **notarization** (`codesign --options runtime` + `notarytool` +
   `stapler`).
4. **Architecture** — built `arm64` only. Build a **universal** binary (and bundle
   universal tools) for Intel Macs.
5. **macOS 15+** required (ScreenCaptureKit `SCRecordingOutput`).

## Layout

```
Sources/ClipEditor.swift   # the whole app
Resources/AppIcon.icns     # app icon
build.sh                   # compile + assemble + sign the .app
scripts/fetch-model.sh     # download the Whisper model
```

## Licensing

App code: your choice. Bundled/used third-party: **ffmpeg** (LGPL/GPL depending on
build), **whisper.cpp** (MIT), Whisper models (MIT). Review obligations before
redistributing binaries.
