# SimpleClips — Feature Spec

What each feature is meant to do, and why it behaves the way it does. This is the
*intent* document; for how it's built, see [implementation.md](implementation.md).

## Product intent

SimpleClips turns a screen recording or an existing video into a short, polished,
right-sized clip — without sending anything off the machine. The whole flow is:
**get footage in → frame and trim it → set the size/quality → export the format you
need.** Every step should give immediate visual feedback, and the file you ask for
should be the file you get.

Guiding principles:

- **Local only.** No network connections, ever. Transcription, encoding, and capture
  all run on the user's Mac.
- **Never surprise the user's files.** The source is never modified. Exports never
  overwrite — names auto-increment instead.
- **What you set is what you get.** The quality slider changes *compression only*; it
  never silently changes resolution. Output size is governed entirely by the crop and
  the output-size fields.
- **Downscale only.** You can shrink a clip but never upscale past real pixels or add
  frames that weren't in the source.

---

## Features

### 1. Screen recording

**Intent:** Capture footage directly so the user doesn't need a separate recorder.

- **Fullscreen mode:** record an entire display. On a multi-monitor setup the user
  picks which one; big numbers flash on each physical screen so it's obvious which is
  "Screen 0", "Screen 1", etc.
- **Region mode:** drag a resizable box over just the part of the screen you want. The
  box floats *above* other apps — including fullscreen Spaces — and stays put as you
  switch desktops. It shows its own pixel size while you size it.
- **While recording**, the region box fades to a thin outline that you can click
  straight through, so it never gets in the way of what you're capturing.
- **Audio/cursor toggles:** include the mouse cursor, your microphone, and/or system
  ("screen") audio, each independently.
- A running **timer** shows elapsed recording time; a sound confirms when the clip is
  captured, and it drops straight into the editing queue.

**Why it behaves this way:** The region box has to be usable over fullscreen apps and
invisible to the capture itself, otherwise you'd record the tool you're recording with.

### 2. Bring in almost any video

**Intent:** Accept whatever footage the user already has, in one file or a batch.

- Drop in MP4, MOV, M4V, GIF, WebM, MKV, AVI, WMV, FLV, TS, MPG/MPEG, 3GP, F4V, and
  more — a single file, several files, or a whole folder.
- Anything macOS can't play back natively still scrubs smoothly, because the app makes
  a fast preview proxy automatically.
- **The original file is never touched.** Editing and export always run on the real
  source at full quality; the proxy is only for the preview.

### 3. Crop and trim visually

**Intent:** Frame the shot and pick the in/out points by eye, not by typing numbers.

- **Crop** is opt-in per clip. Turn it on and drag the corner dots to frame; the area
  outside the crop dims so the framing is obvious. Off means "export the full frame."
- **Trim** with handles on the timeline. A playhead scrubs, and playback loops within
  the trimmed region so you can check the in/out points.
- A live readout always shows the current time, the trim length, the source
  resolution, and the source file size.

### 4. Size it exactly

**Intent:** Let the user hit a precise output size.

- A **resolution slider** scales the output as a percentage of the crop, or
- the user can **type an exact width or height in pixels** — the other dimension
  follows automatically to keep the aspect ratio.
- **You can only scale down** from real pixels, never up.

### 5. Quality as one slider

**Intent:** Trade off file size vs. detail without thinking about codecs.

- One slider runs from **Optimized** (smaller files) to **High fidelity** (more detail).
- It changes **compression only** — it never touches resolution. The size you dial in
  with the crop/output fields is the size you get.

### 6. Frame rate

**Intent:** Shrink the file further by dropping frame rate when smoothness isn't critical.

- A slider lowers the frame rate. Its maximum is the source rate — you can reduce fps
  but never invent frames the source didn't have.

### 7. See the size before exporting

**Intent:** Remove the guesswork — show the projected size *before* committing.

- A **live estimate** continuously shows the projected file size and how much smaller
  it is than the source (e.g. "−78%"). It's instant and approximate.
- **Harder estimate** encodes a short real sample at the actual export settings and
  extrapolates, giving an accurate, *measured* figure. The measured number stays shown
  until a setting that affects size changes, then it reverts to the live estimate.

### 8. Captions, generated locally

**Intent:** Add subtitles/transcripts without any cloud service.

- Transcription runs **entirely offline** (whisper.cpp).
- Three independent outputs: **embed** a toggleable subtitle track (MP4 family), save a
  **sidecar `.srt`**, and/or save a plain **`.txt`** transcript.
- Subtitles are never burned into the picture and never shown in the preview — the
  embedded track is a soft track you can toggle in any player.

### 9. Export to whatever you need

**Intent:** One click produces the exact format the user is targeting.

- **MP4, GIF, WebM**, a **Web bundle** (a `.webm` plus a `.gif` in a `*_forweb`
  folder), or **MOV, M4V, MKV, AVI, WMV, FLV, TS, MPG, 3GP, F4V**.
- Exports go to a chosen folder with **auto-numbered names** (`clip`, `clip_1`, …) so
  nothing is ever overwritten.
- A **determinate progress bar** with an ETA runs during export, and export can be
  **canceled** mid-encode (the partial file is cleaned up).

### 10. Work through a batch

**Intent:** Apply the same treatment to many clips quickly.

- Drop in several files or a folder and move through them with **Prev / Next /
  Remove**. Each clip exports with the current settings, and "Export & Next"
  walks the queue automatically.

---

## Non-goals / known constraints

- **No upscaling, no frame interpolation.** Quality only ever decreases from source.
- **No network features** of any kind — by design.
- Whisper model lives at a fixed path and must be present for captions to work.
- Screen recording requires macOS 15+ and the Screen Recording permission.
