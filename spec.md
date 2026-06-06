# SimpleClips Feature Spec

What each feature is meant to do, and why it behaves the way it does. This is the
*intent* document, shared by both platforms. For how it's actually built, see
[mac/implementation_Mac.md](mac/implementation_Mac.md) and
[windows/implementation_win.md](windows/implementation_win.md).

## Product intent

SimpleClips turns a screen recording or an existing video into a short, polished,
right-sized clip, without sending anything off the machine. The whole flow is:
**get footage in, frame and trim it, set the size/quality, export the format you need.**
Every step should give immediate visual feedback, and the file you ask for should be
the file you get.

There are two builds of the same product, the original macOS app and a Windows rebuild.
They are separate codebases but should do the same things, the same way, wherever the
platform allows it. Where a platform forces a difference, it's noted inline and gathered
under [Platform notes](#platform-notes).

Guiding principles:

- **Local only.** No network connections during normal use. Transcription, encoding, and
  capture all run on the user's own computer. (The captions model is fetched once, or
  bundled, so it can run fully offline.)
- **Never surprise the user's files.** The source is never modified. Exports never
  overwrite, names auto-increment instead.
- **What you set is what you get.** The quality slider changes *compression only*, it
  never silently changes resolution. Output size is governed entirely by the crop and the
  output-size fields.
- **Downscale only.** You can shrink a clip but never upscale past real pixels or add
  frames that weren't in the source.

---

## Features

### 1. Screen recording

**Intent:** Capture footage directly so the user doesn't need a separate recorder.

- **Fullscreen mode:** record an entire display. On a multi-monitor setup the user picks
  which one, with big numbers flashed on each physical screen so it's obvious which is
  "Screen 0", "Screen 1", etc.
- **Region mode:** drag a resizable box over just the part of the screen you want. Move it
  by grabbing the label in its middle (the one showing the size), resize it from any of the
  four corners, and click straight through the empty middle so the apps behind it stay
  usable while you line up the shot. The box shows the *true* pixel size it will record,
  even on a scaled HiDPI display (e.g. a 4K screen running at 150%).
- **While recording**, the box fades to a thin outline you can click through, so it never
  gets in the way of what you're capturing, and returns to normal when you stop. The box
  itself never appears in the recording.
- **Capture frame rate** follows the monitor's refresh rate (a 240 Hz monitor records at
  about 240 fps, a 60 Hz monitor at about 60), rather than being locked to a fixed number.
- **Audio/cursor toggles:** include the mouse cursor, your microphone (pick which one),
  and/or system ("computer") audio, each independently.
  - *(Windows)* The cursor is always recorded: the way Windows captures system audio also
    forces the cursor to show, so when system audio is on it can't be hidden.

**Why it behaves this way:** The region box has to be usable over other apps and invisible
to the capture itself, otherwise you'd record the tool you're recording with.

### 2. Bring in almost any video

**Intent:** Accept whatever footage the user already has, in one file or a batch.

- Drop in MP4, MOV, M4V, GIF, WebM, MKV, AVI, WMV, FLV, TS, MPG/MPEG, 3GP, F4V, and more,
  a single file, several files, or a whole folder.
- Anything the player can't show natively still scrubs smoothly, because the app makes a
  fast preview proxy automatically.
- **The original file is never touched.** Editing and export always run on the real source
  at full quality, the proxy is only for the preview.

### 3. Crop and trim visually

**Intent:** Frame the shot and pick the in/out points by eye, not by typing numbers.

- **Crop** is opt-in per clip. Turn it on and drag the corner dots to frame, the area
  outside the crop dims so the framing is obvious. Off means "export the full frame."
- **Trim** with handles on the timeline. A playhead scrubs, and playback loops within the
  trimmed region so you can check the in/out points.
- A live readout always shows the current time, the trim length, the source resolution, and
  the source file size.

### 4. Size it exactly

**Intent:** Let the user hit a precise output size.

- A **resolution slider** scales the output as a percentage of the crop, or
- the user can **type an exact width or height in pixels**, and the other dimension follows
  automatically to keep the aspect ratio.
- **You can only scale down** from real pixels, never up.

### 5. Quality as one slider

**Intent:** Trade off file size vs. detail without thinking about codecs.

- One slider runs from **Optimized** (smaller files) to **High fidelity** (more detail).
- It changes **compression only**, it never touches resolution. The size you dial in with
  the crop/output fields is the size you get.

### 6. Frame rate

**Intent:** Shrink the file further by dropping frame rate when smoothness isn't critical.

- A slider lowers the frame rate, with a typeable field beside it for entering an exact
  value. Its maximum is the source rate, you can reduce fps but never invent frames the
  source didn't have.

### 7. See the size before exporting

**Intent:** Remove the guesswork, show the projected size *before* committing.

- A **live estimate** continuously shows the projected file size and how much smaller it is
  than the source (e.g. "−78%"). It's instant and approximate.
- **Harder estimate** encodes a short real sample at the actual export settings and
  extrapolates, giving an accurate, *measured* figure. From then on the live estimate stays
  locked onto that measured number and adjusts from there, until a setting that affects size
  changes.

### 8. Captions, generated locally

**Intent:** Add subtitles/transcripts without any cloud service.

- Transcription runs **entirely offline** (whisper.cpp), on the user's machine.
- Three independent outputs: **embed** a toggleable subtitle track (MP4 family), save a
  **sidecar `.srt`**, and/or save a plain **`.txt`** transcript.
- Subtitles are never burned into the picture and never shown in the preview, the embedded
  track is a soft track you can toggle in any player.

### 9. Export to whatever you need

**Intent:** One click produces the exact format the user is targeting.

- **MP4, GIF, WebM**, a **Web bundle** (a `.webm` plus a `.gif` in a `*_forweb` folder), or
  **MOV, M4V, MKV, AVI, WMV, FLV, TS, MPG, 3GP, F4V**.
- Exports go to a chosen folder with **auto-numbered names** (`clip`, `clip_1`, …) so
  nothing is ever overwritten.
- A **determinate progress bar** with an ETA runs during export, and export can be
  **canceled** mid-encode (the partial file is cleaned up).

### 10. Work through a batch

**Intent:** Apply the same treatment to many clips quickly.

- Drop in several files or a folder and move through them with **Prev / Next / Remove**.
  Each clip exports with the current settings, and "Export & Next" walks the queue
  automatically.

---

## Choices we made (and why)

A few decisions were real trade-offs worth remembering:

- **Computer sound over a hide-cursor option (Windows).** On Windows you can't have both,
  the built-in way to record system sound also forces the cursor to show. We kept computer
  sound, so the cursor always appears in recordings there.
- **Captions work offline out of the box.** The speech model can be bundled into the app so
  captions just work with no internet, at the cost of a larger download.
- **Carries everything it needs.** The behind-the-scenes tools (ffmpeg, whisper.cpp) ship
  inside the app, so there's nothing to install separately and nothing to set up.

---

## Non-goals / known constraints

- **No upscaling, no frame interpolation.** Quality only ever decreases from source.
- **No network features** of any kind during normal use, by design.
- Captions require the local whisper model to be present.

---

## Platform notes

Behavior that differs by platform, or constraints specific to one:

**macOS**
- Screen recording requires **macOS 15+** and the **Screen Recording permission**.
- The region overlay floats above other apps, including fullscreen **Spaces**, and stays
  put as you switch desktops.

**Windows**
- The **cursor is always recorded** when system audio is on (see Feature 1), so there's no
  hide-cursor switch.
- Ships as both a **portable `.exe`** (download and double-click, nothing to install) and a
  regular **installer**.
- Not yet code-signed, so Windows shows an **"unknown publisher"** warning on first run
  ("More info → Run anyway"). Removing it needs a paid certificate later.
