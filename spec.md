# SimpleClips

Turn screen recordings and existing videos into short, polished, right-sized clips. Everything runs on your own computer.

---

## What it does

- **Records your screen.** Full screen (pick which monitor) or a draggable region box, with your microphone and/or computer audio if you want them. Recordings are ready to edit the moment you hit Stop.
- **Makes performant GIFs, WebMs, and MP4s** (and MOV, M4V, MKV, AVI, WMV, FLV, TS, MPG, 3GP, F4V), tuned so the file you share is small and plays everywhere.
- **Converts videos.** Drop in a video, several videos, or a whole folder of them, then export to any supported format. One clip or a whole batch.
- **Compresses and optimizes videos you already have.** Load any video from your PC, dial the size down with one quality slider, and see the projected file size live before you export.
- **Trims and crops visually.** Drag handles on a timeline for in/out points, drag a crop box over the picture to frame the shot. No numbers required (but you can type exact pixels).
- **Shows the file size before you commit.** A live estimate reacts instantly to every slider, and the app quietly measures a real sample in the background so the number stays honest.
- **Generates captions offline.** Embedded toggleable subtitles, sidecar .srt, or a plain .txt transcript, all transcribed locally with no cloud service.
- **A "Web bundle" export** produces a matched .webm plus .gif pair in one click, for places that want both.
- **Never touches your originals.** Sources are read-only; exports auto-number (clip, clip_1, ...) and never overwrite anything.
- **Fully private.** No network use at all while you work. The tools it needs (ffmpeg, whisper) ship inside the app.
- **Clear feedback.** Progress bars for exporting and for finishing a recording, a chime when an export lands, "Saved to ..." with a Show in folder button, and the app version in the title bar.

Two builds of the same product: the original macOS app and the Windows rebuild. Separate codebases, same behavior wherever the platform allows.

---

## Guiding principles

- **Local only.** No network connections during normal use. Capture, encoding, and transcription all run on the user's machine.
- **Never surprise the user's files.** The source is never modified. Exports never overwrite; names auto-increment.
- **What you set is what you get.** The quality slider changes compression only; it never silently changes resolution. Output size is governed entirely by the crop and the output-size fields.
- **Downscale only.** You can shrink a clip but never upscale past real pixels or invent frames the source didn't have.
- **Compatibility by default, capability on request.** Defaults produce files that play in stock players everywhere (e.g. exports default to 60fps or below); the sliders still reach the source's full capability when you deliberately push them.

---

## Features

### 1. Screen recording

**Intent:** Capture footage directly so the user doesn't need a separate recorder.

- **Fullscreen mode:** record an entire display; on multi-monitor setups the user picks which one.
- **Region mode:** drag a resizable box over just the part of the screen you want. Move it by its center label, resize from the corners, and click straight through the empty middle so apps behind it stay usable. The box shows the true pixel size it will record, even on scaled HiDPI displays, and never appears in the recording itself.
- **While recording**, the box fades to a thin click-through outline and returns to normal on stop.
- **Capture frame rate** follows the monitor's refresh rate, capped at 120fps. (Windows: the capture is hardware-encoded H.264, so stopping a recording finishes in about a second; there is no long "encoding" wait.)
- **Audio toggles:** microphone (pick which one) and/or system audio, independently; multiple audio sources are mixed into one track.
- **Quality:** recordings use a bitrate scaled to resolution and frame rate (8 to 24 Mbps), not the platform recorder's low default.

### 2. Bring in almost any video

**Intent:** Accept whatever footage the user already has, in one file or a batch.

- Drop in MP4, MOV, M4V, GIF, WebM, MKV, AVI, WMV, FLV, TS, MPG/MPEG, 3GP, F4V, and more; a single file, several files, or a whole folder (folders expand to their video files, de-duped and naturally sorted).
- Anything the player can't show natively still scrubs smoothly via an automatic fast preview proxy.
- **The original file is never touched.** Editing and export always run on the real source; the proxy is only for preview.

### 3. Crop and trim visually

- **Crop** is opt-in per clip: drag corner dots to frame, the outside dims, off means full frame.
- **Trim** with timeline handles; playback loops inside the trimmed region to check the in/out points.
- Live readouts show current time, trim length, source resolution, and source file size.

### 4. Size it exactly

- A **resolution slider** scales output as a percentage of the crop, or type an exact width/height and the other dimension follows to keep aspect.
- **Scale down only**, never up.

### 5. Quality as one slider

- One slider from **Optimized** (smaller) to **High fidelity** (more detail). It maps to real codec settings (CRF curves per format) and changes compression only.

### 6. Frame rate

- A slider plus a typeable field lowers the frame rate. Maximum is the source rate; the **default is 60fps or the source rate, whichever is lower**, because H.264 above 60fps at screen resolutions exceeds what stock Windows players can decode (H.264 Level 5.2). High-fps exports are still one slider drag away.

### 7. See the size before exporting

Three layers, each better than the last, all automatic:

1. **Instant model:** a pure-math estimate that reacts to every slider with zero delay.
2. **Content anchor:** shortly after a clip loads (~0.3s), the app reads the size of every video packet in the source and re-bases the estimate on the clip's real bytes. This makes the number content-aware: screen recordings (which compress far better than camera video) estimate correctly, and trimming a static section "costs" less than trimming a busy one.
3. **Measured calibration:** the app encodes three short samples spread across the trim (20/50/80%) at the actual export settings and locks the estimate onto the measurement. Runs automatically on load; the "Harder estimate" button re-runs it on demand.

The estimate always shows projected size, the savings vs. the source (e.g. "−78%"), and which layer it's on (rough / live / calibrated).

### 8. Captions, generated locally

- Transcription runs **entirely offline** (whisper.cpp).
- Three independent outputs: **embed** a toggleable soft subtitle track (MP4 family), sidecar **.srt**, and/or plain **.txt** transcript.
- Subtitles are never burned into the picture.

### 9. Export to whatever you need

- **MP4, GIF, WebM**, a **Web bundle** (matched .webm + .gif in a `*_forweb` folder), or **MOV, M4V, MKV, AVI, WMV, FLV, TS, MPG, 3GP, F4V**.
- Exports go to a chosen folder with **auto-numbered names**; nothing is ever overwritten.
- A **determinate progress bar** runs during export; export is **cancelable** (partial files are cleaned up, and a failed export never leaves a broken file behind or claims success).
- On success: chime, **"Saved to <full path>"**, and a **Show in folder** button.

### 10. Work through a batch

- Drop in several files or a folder and move through them with **Prev / Next / Remove**. "Export & Next" walks the queue; the status message is always about the clip just exported.

---

## How it's put together

### Repository layout

```
Morgan-Quick-Clips/
├── spec.md                  ← this file (intent + architecture)
├── Downloadable builds/
│   ├── Windows/             ← shipped installers, named with the version
│   │                          (SimpleClips Setup 1.0x.exe, SimpleClips-1.0x-portable.exe)
│   └── Mac/
├── windows/                 ← Electron app (the Windows build)
│   ├── implementation_win.md  ← deep implementation notes
│   └── Patch notes.md       ← Windows release notes (V1.01, V1.02, ...)
└── mac/                     ← Swift app (the original macOS build)
    ├── implementation_Mac.md
    └── Patch notes.md       ← Mac release notes (independent versioning)
```

### Windows app (Electron)

Three-process Electron architecture with strict context isolation:

- **Main process** (`windows/src/main/index.js`): window creation, permissions, dialogs, the region-overlay window, and all filesystem/ffmpeg work, exposed to the UI through IPC handlers (`media:*`, `rec:save`, `region:*`, `shell:reveal`, `app:version`).
- **Preload bridges** (`windows/src/preload/`): expose a minimal `window.clips` API to the renderer; the renderer never touches Node directly.
- **Renderer** (`windows/src/renderer/app.js` + `index.html` + `styles.css`): the whole editor UI, a single state object `S` plus render functions. A custom title bar (icon, name, gray version number) replaces the native one; Windows overlays the min/max/close buttons.

**The media engine** (`windows/src/main/engine/`) is pure Node + bundled ffmpeg/ffprobe/whisper, no Electron dependency, so it can run and be tested headless:

| Module | Job |
|---|---|
| `plan.js` | Single source of truth for encode settings per format/quality (CRF curves, codecs) |
| `export.js` | Export pipeline, Web bundle, hard estimate sampling, recording finish pass |
| `estimate.js` | Instant model, packet parsing, and the content-anchored estimator |
| `probe.js` | ffprobe wrappers: dimensions/duration/fps/subtitles, per-packet byte histogram |
| `proxy.js` | Preview proxies for formats Chromium can't play |
| `captions.js` | whisper.cpp transcription, srt/txt outputs |
| `ffmpeg.js` | Process runners (argv arrays only, never a shell; `-progress` parsing) |
| `tools.js` / `util.js` | Tool resolution and shared helpers |

**Recording pipeline (the part that makes Stop instant):**

1. Renderer captures the screen via `desktopCapturer` + `getUserMedia`, then records with `MediaRecorder` preferring **H.264 in MP4** (`avc1`), which Chromium encodes with the platform's *hardware* encoder (Media Foundation). VP9/WebM remains a fallback. Explicit 8-24 Mbps bitrate.
2. On stop, the blob goes to the main process. Because the capture is already H.264, the finish step is a **remux**: copy the compressed video into a clean, seekable, faststart MP4 with a correct duration header and re-encode only the audio to AAC. Sub-second for any length.
3. Region recordings additionally crop, which needs one real encode pass (CFR H.264 at the capture rate, ≤120fps), with a live progress bar driven by the recording's wall-clock duration.
4. The master lands in the temp folder and loads straight into the editor queue.

This mirrors the macOS app, where ScreenCaptureKit writes hardware H.264 during capture and there is no post-encode at all.

**Export pipeline:** `plan()` turns (format, quality, fps) into ffmpeg args; `buildCropFilter()` adds crop/scale; ffmpeg runs with `-progress` streaming fractions back to the UI. MP4-family exports get `+faststart`; success requires a zero exit code, and failures delete the partial file. Captions, when requested, run a whisper pass first and soft-embed via a remux.

**Size estimation:** the three layers from Feature 7. The renderer mirrors the engine's math so slider reactions are synchronous; the packet histogram comes over IPC once per clip; calibration stores "measured bytes at these settings" and recomputes the correction ratio on every read so the layers compose cleanly.

**Verification:** `npm test` runs pure-logic engine checks (`tools/engine-test.js`); `SMOKE=1` mode boots the real app headlessly, loads a sample, exports it, and prints a JSON result; `tools/engine-cli.js` exercises the engine without Electron.

**Packaging:** electron-builder produces an NSIS installer and a portable exe (`npm run dist:win`), with ffmpeg/ffprobe unpacked from asar and whisper + its model shipped via extraResources. Not yet code-signed.

### macOS app (Swift)

A single-source SwiftUI app (`mac/Sources/ClipEditor.swift`) built by `mac/build.sh`:

- **Recording:** ScreenCaptureKit (`SCStream` + `SCRecordingOutput`) with `videoCodecType = .h264`, so the hardware encoder writes a finished MP4 while recording. Requires macOS 15+ and the Screen Recording permission.
- **Editing/export:** the same conceptual pipeline (plan → ffmpeg), using `h264_videotoolbox` for hardware encoding; bundled ffmpeg and whisper.cpp (`scripts/bundle-deps.sh`, `scripts/fetch-model.sh`); notarization via `scripts/notarize.sh`.
- The Windows engine is a deliberate port of this app's logic; `plan()` and the estimate math are kept behavior-identical so both platforms produce the same files.

### Versioning and releases

- The two builds version **independently**: each platform keeps its own release notes — `mac/Patch notes.md` and `windows/Patch notes.md` — iterating **V1.01, V1.02, ...** with a simple, readable list of all changes since that platform's last release.
- `windows/package.json` carries the Windows semver (`1.0.x`); `mac/build.sh` carries the Mac `VERSION`. The title bar reads the version at runtime on both platforms, so the UI always matches the build.
- Shipped artifacts are copied into `Downloadable builds/Windows/` (named with the patch version, replacing the previous pair) or `Downloadable builds/mac/`.

---

## Choices we made (and why)

- **H.264 hardware capture over VP9 (Windows).** VP9 capture forced a minutes-long software re-encode after every recording. Hardware H.264 makes Stop effectively instant and matches the Mac's architecture. Cost: the master's frame timing is as-captured (variable) rather than forced constant; exports re-encode anyway.
- **Capture caps at 120fps, exports default to ≤60.** Stock Windows players refuse H.264 beyond Level 5.2, which screen-resolution video crosses just above 60fps. Defaults stay universally playable; the capability (up to 120) remains for those who want it.
- **Estimates anchor on the file's own bytes.** No fixed constant can model both a static screen recording and camera footage (they differ by 10-30x). The clip itself is the best predictor of the clip.
- **Computer sound over a hide-cursor option (Windows).** The way Windows captures system audio also forces the cursor to show; we kept computer sound.
- **Captions work offline out of the box.** The speech model ships with the app, at the cost of a larger download.
- **Carries everything it needs.** ffmpeg and whisper.cpp ship inside the app; nothing to install.

---

## Non-goals / known constraints

- **No upscaling, no frame interpolation.** Quality only ever decreases from source.
- **No network features** during normal use, by design.
- Captions require the bundled whisper model to be present.

---

## Platform notes

**macOS**
- Screen recording requires **macOS 15+** and the **Screen Recording permission**.
- The region overlay floats above other apps, including fullscreen Spaces.

**Windows**
- The **cursor is always recorded** when system audio is on (see above); there's no hide-cursor switch.
- Ships as both a **portable .exe** and a regular **installer** (see `Downloadable builds/Windows/`).
- Not yet code-signed, so Windows shows an **"unknown publisher"** warning on first run ("More info → Run anyway"). Removing it needs a paid certificate later.

---
---

# SimpleClips Feature Spec (original format)

What each feature is meant to do, and why it behaves the way it does. This is the *intent* document, shared by both platforms. For how it's actually built, see [mac/implementation_Mac.md](mac/implementation_Mac.md) and [windows/implementation_win.md](windows/implementation_win.md).

## Product intent

SimpleClips turns a screen recording or an existing video into a short, polished, right-sized clip, without sending anything off the machine. The whole flow is: **get footage in, frame and trim it, set the size/quality, export the format you need.** Every step should give immediate visual feedback, and the file you ask for should be the file you get.

There are two builds of the same product, the original macOS app and a Windows rebuild. They are separate codebases but should do the same things, the same way, wherever the platform allows it. Where a platform forces a difference, it's noted inline and gathered under [Platform notes](#platform-notes-original).

Guiding principles:

- **Local only.** No network connections during normal use. Transcription, encoding, and capture all run on the user's own computer. (The captions model is fetched once, or bundled, so it can run fully offline.)
- **Never surprise the user's files.** The source is never modified. Exports never overwrite, names auto-increment instead.
- **What you set is what you get.** The quality slider changes *compression only*, it never silently changes resolution. Output size is governed entirely by the crop and the output-size fields.
- **Downscale only.** You can shrink a clip but never upscale past real pixels or add frames that weren't in the source.

---

## Features

### 1. Screen recording

**Intent:** Capture footage directly so the user doesn't need a separate recorder.

- **Fullscreen mode:** record an entire display. On a multi-monitor setup the user picks which one, with big numbers flashed on each physical screen so it's obvious which is "Screen 0", "Screen 1", etc.
- **Region mode:** drag a resizable box over just the part of the screen you want. Move it by grabbing the label in its middle (the one showing the size), resize it from any of the four corners, and click straight through the empty middle so the apps behind it stay usable while you line up the shot. The box shows the *true* pixel size it will record, even on a scaled HiDPI display (e.g. a 4K screen running at 150%).
- **While recording**, the box fades to a thin outline you can click through, so it never gets in the way of what you're capturing, and returns to normal when you stop. The box itself never appears in the recording.
- **Capture frame rate** follows the monitor's refresh rate, capped at 120 fps; exports default to 60 fps or below for compatibility.
- **Audio/cursor toggles:** include the mouse cursor, your microphone (pick which one), and/or system ("computer") audio, each independently.
  - *(Windows)* The cursor is always recorded: the way Windows captures system audio also forces the cursor to show, so when system audio is on it can't be hidden.

**Why it behaves this way:** The region box has to be usable over other apps and invisible to the capture itself, otherwise you'd record the tool you're recording with.

### 2. Bring in almost any video

**Intent:** Accept whatever footage the user already has, in one file or a batch.

- Drop in MP4, MOV, M4V, GIF, WebM, MKV, AVI, WMV, FLV, TS, MPG/MPEG, 3GP, F4V, and more, a single file, several files, or a whole folder.
- Anything the player can't show natively still scrubs smoothly, because the app makes a fast preview proxy automatically.
- **The original file is never touched.** Editing and export always run on the real source at full quality, the proxy is only for the preview.

### 3. Crop and trim visually

**Intent:** Frame the shot and pick the in/out points by eye, not by typing numbers.

- **Crop** is opt-in per clip. Turn it on and drag the corner dots to frame, the area outside the crop dims so the framing is obvious. Off means "export the full frame."
- **Trim** with handles on the timeline. A playhead scrubs, and playback loops within the trimmed region so you can check the in/out points.
- A live readout always shows the current time, the trim length, the source resolution, and the source file size.

### 4. Size it exactly

**Intent:** Let the user hit a precise output size.

- A **resolution slider** scales the output as a percentage of the crop, or
- the user can **type an exact width or height in pixels**, and the other dimension follows automatically to keep the aspect ratio.
- **You can only scale down** from real pixels, never up.

### 5. Quality as one slider

**Intent:** Trade off file size vs. detail without thinking about codecs.

- One slider runs from **Optimized** (smaller files) to **High fidelity** (more detail).
- It changes **compression only**, it never touches resolution. The size you dial in with the crop/output fields is the size you get.

### 6. Frame rate

**Intent:** Shrink the file further by dropping frame rate when smoothness isn't critical.

- A slider lowers the frame rate, with a typeable field beside it for entering an exact value. Its maximum is the source rate, you can reduce fps but never invent frames the source didn't have. The default is 60 fps or the source rate, whichever is lower.

### 7. See the size before exporting

**Intent:** Remove the guesswork, show the projected size *before* committing.

- A **live estimate** continuously shows the projected file size and how much smaller it is than the source (e.g. "−78%"). It's instant, and shortly after a clip loads it anchors itself to the clip's real content so it's accurate from the start.
- **Harder estimate** encodes short real samples at the actual export settings and extrapolates, giving an accurate, *measured* figure. It runs automatically when a clip loads. From then on the live estimate stays locked onto that measured number and adjusts from there.

### 8. Captions, generated locally

**Intent:** Add subtitles/transcripts without any cloud service.

- Transcription runs **entirely offline** (whisper.cpp), on the user's machine.
- Three independent outputs: **embed** a toggleable subtitle track (MP4 family), save a **sidecar `.srt`**, and/or save a plain **`.txt`** transcript.
- Subtitles are never burned into the picture and never shown in the preview, the embedded track is a soft track you can toggle in any player.

### 9. Export to whatever you need

**Intent:** One click produces the exact format the user is targeting.

- **MP4, GIF, WebM**, a **Web bundle** (a `.webm` plus a `.gif` in a `*_forweb` folder), or **MOV, M4V, MKV, AVI, WMV, FLV, TS, MPG, 3GP, F4V**.
- Exports go to a chosen folder with **auto-numbered names** (`clip`, `clip_1`, …) so nothing is ever overwritten.
- A **determinate progress bar** runs during export, and export can be **canceled** mid-encode (the partial file is cleaned up).
- On success the status shows **"Saved to ..."** with the full path and a **Show in folder** button.

### 10. Work through a batch

**Intent:** Apply the same treatment to many clips quickly.

- Drop in several files or a folder and move through them with **Prev / Next / Remove**. Each clip exports with the current settings, and "Export & Next" walks the queue automatically.

---

## Choices we made (and why)

A few decisions were real trade-offs worth remembering:

- **Computer sound over a hide-cursor option (Windows).** On Windows you can't have both, the built-in way to record system sound also forces the cursor to show. We kept computer sound, so the cursor always appears in recordings there.
- **Captions work offline out of the box.** The speech model can be bundled into the app so captions just work with no internet, at the cost of a larger download.
- **Carries everything it needs.** The behind-the-scenes tools (ffmpeg, whisper.cpp) ship inside the app, so there's nothing to install separately and nothing to set up.

---

## Non-goals / known constraints

- **No upscaling, no frame interpolation.** Quality only ever decreases from source.
- **No network features** of any kind during normal use, by design.
- Captions require the local whisper model to be present.

---

## Platform notes (original)

Behavior that differs by platform, or constraints specific to one:

**macOS**
- Screen recording requires **macOS 15+** and the **Screen Recording permission**.
- The region overlay floats above other apps, including fullscreen **Spaces**, and stays put as you switch desktops.

**Windows**
- The **cursor is always recorded** when system audio is on (see Feature 1), so there's no hide-cursor switch.
- Ships as both a **portable `.exe`** (download and double-click, nothing to install) and a regular **installer**.
- Not yet code-signed, so Windows shows an **"unknown publisher"** warning on first run ("More info → Run anyway"). Removing it needs a paid certificate later.
