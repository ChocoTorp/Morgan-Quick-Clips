# SimpleClips — Implementation

How the app is actually built. Pairs with [spec.md](../spec.md) (what each feature is
*for*). All UI and logic live in a single Swift file: [Sources/ClipEditor.swift](Sources/ClipEditor.swift)
(~2.2k lines). Media work shells out to `ffmpeg`/`ffprobe`/`whisper-cli`.

## Stack & shape

- **One Swift file**, SwiftUI + AppKit, targeting **macOS 15+**. Frameworks: SwiftUI,
  AppKit, AVKit/AVFoundation (preview + playback), ScreenCaptureKit (recording),
  CoreMedia/CoreGraphics, UniformTypeIdentifiers (drag-and-drop).
- **`@main struct ClipEditorApp`** hosts a single `WindowGroup` with
  `.windowResizability(.contentSize)`. An `AppDelegate` runs `resolveTools()` at
  launch and forces a regular, activated app.
- **`EditorState: ObservableObject`** is the single source of truth — every piece of
  UI state (`@Published`) plus the shared `AVPlayer`, the recorder, and the region
  selector. `ContentView` reads it via `@EnvironmentObject`.

## External tools (no shell, ever)

`gFFmpeg` / `gFFprobe` / `gWhisper` / `gWhisperModel` are resolved once at startup by
`resolveTools()`:

1. Prefer tools bundled inside the `.app` at `Contents/Helpers` (self-contained
   distribution build).
2. Fall back to Homebrew/PATH (`/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`) for
   dev builds. (A Finder-launched app gets a minimal PATH without Homebrew, hence the
   absolute-path resolution.)
3. The Whisper model is found in the bundle, else at a hard-coded
   `~/.hermes/...//ggml-base.en.bin` dev path.

**Every tool call goes through `runTool(exe, [args])`** — a `Process` invoked with an
**argument array, never a shell string**. This makes shell injection impossible:
filenames/paths are literal `argv` entries, never parsed by a shell. `stderr` is merged
into `stdout` (the array-arg equivalent of `2>&1`). `args(_:)` splits a codec string
into tokens; nothing is ever passed to `/bin/sh`.

## Encoding model — the `plan()` function

`plan(format, q, crop, fps, hw)` is the **single source of truth for encode settings**,
shared by both export *and* the estimator so the estimate reflects exactly what export
will do. It returns `(vf:` filtergraph `, codec:` trailing args `)`.

- `q` is a continuous **0…1 fidelity→optimization** value (0 = max fidelity, 1 = max
  optimization). The slider drives this.
- **Per-format curves** map `q` to real encoder knobs:
  - **H.264 family** (MP4/MOV/M4V/MKV/AVI/TS/FLV/F4V/3GP): `libx264`, CRF `14→30`,
    preset `slow/medium/slower`, AAC `256→96 kbps`; `+faststart` for MP4/MOV/M4V;
    baseline profile for 3GP. With **`fast`** (the UI's Fast-export toggle) the preset
    becomes `veryfast` (WebM: `cpu-used 5`) — measured ~2× faster on real 4K screen
    content for under one VMAF point. `fastApplies()` excludes GIF/MPEG-2/WMV, where
    encoder effort changes nothing; the UI grays out only the Fast option there.
    **Flipping the toggle re-runs the auto-measure** — a calibration taken in the other
    mode is only a model-transferred guess for this one.
  - **Why no hardware (VideoToolbox) mode:** tried and removed after measuring on real
    content. On Apple Silicon the media engine is pixel-bound (~100fps at 4K, ~350fps
    at 1080p) so multi-core x264 matches or beats it on wall-clock, and x264 is far
    better per byte (VMAF 97.1 @ 3.6 Mbps vs 90.6 @ 4.7 Mbps on a real 4K recording).
    Its constant-quality `-q:v` scale also relates to CRF differently per clip, which
    made honest "faster but larger" labeling impossible. VideoToolbox's only real win
    is energy, which isn't worth the size/quality trade here.
  - **WebM:** `libvpx-vp9`, CRF `18→40`, Opus `192→96 kbps`.
  - **GIF:** two-pass `palettegen`/`paletteuse`; palette mode and dither degrade with
    `q`; fps `20→12`.
  - **MPG** (mpeg2video) and **WMV** (wmv2) have their own `q:v` curves.
- **Crucially, the quality slider never alters resolution** — output size is baked into
  the `crop` string the caller passes in. This is the "what you set is what you get"
  guarantee, enforced at the one place encoding is defined.

## State & playback

- **Crop** is stored in **source pixels** (`cropX/Y/W/H`); `cropOn` gates it.
  `syncOutToCrop()` keeps the output size following the crop (even dimensions, min 2).
- **Trim** is `trimStart/trimEnd`; an `AVPlayer` periodic time observer
  (`attachObserver`) updates `current` and **loops playback within the trim region**.
- `outW/outH` are aspect-locked to the crop and **clamped to the crop size** — the
  binding setters enforce downscale-only. `fpsOverride()` returns `nil` (no `-r`) when
  the fps slider sits at the source rate, so "keep source" emits no rate change.

## Loading & the preview proxy

`load(url)` runs `ffprobe` on a background queue to read width/height, duration,
`r_frame_rate` (parsed from `"30000/1001"` form), and whether a subtitle stream exists.
The fps slider then defaults to **min(source, 60)** — universally playable; the slider
still reaches the source rate for deliberate high-fps exports.

**AVPlayer only decodes mp4/mov/m4v** (`nativePreviewExts`). For anything else (webm,
mkv, avi, gif, wmv, …) the app transcodes a **fast hardware proxy** (`h264_videotoolbox`,
even-dimension scale) to a temp `scpreview_<hash>.mp4` *purely for scrubbing*.
Editing/export always use the original file. Embedded subtitles are deselected in the
preview (`applyCaptions`) so a "default"-flagged track never shows itself.

### Scrubbing (coalesced seeks + scrub proxy)

- Every drag-seek goes through a **`CoalescedSeeker`** (one zero-tolerance seek in flight
  per `AVPlayer`; while it works only the *latest* target is kept), so a fast drag can't
  queue stale seeks the picture then replays in slow motion.
- After load, `buildScrubProxy` builds a **scrub proxy** in the background
  (≤640px, 15fps, keyframe every ~0.5s (`-g 8`), no audio, `h264_videotoolbox`, cached as
  `scscrub_<hash>.mp4` by path+size). While the playhead/trim handles are dragged, a second
  `AVPlayerLayer` stacked over the preview shows the proxy (instant seeks); on release it
  hides and the master settles on the exact frame (`endScrub`). Until the proxy is ready,
  drags scrub the master through the coalesced seeker. Loading another clip terminates an
  in-flight build; failed/killed builds delete their partial file so the cache can't be
  poisoned. The periodic time observer ignores updates while `scrubbing` (the drag owns
  `current`).

## Screen recording (`ScreenRecorder`)

In-process **ScreenCaptureKit** (`@available(macOS 15, *)`):

- `SCStream` + `SCRecordingOutput` write an `.mov` (H.264) directly to a temp file —
  the recording permission attaches to the app itself.
- `SCStreamConfiguration` carries pixel size (even dims), optional `sourceRect` (region),
  cursor, `captureMicrophone` + `microphoneCaptureDeviceID` (the toolbar's mic picker,
  enumerated via `AVCaptureDevice.DiscoverySession`), and `capturesAudio` (system audio).
- Capture rate follows the display's refresh, **clamped to 120** like the Windows build
  (a 240Hz master gains nothing but encode time; exports default to ≤60 regardless).
- `stop()` uses a `CheckedContinuation` with a **2s timeout** so finishing the file
  never hangs. On success the clip drops into the queue and loads.

### Region selector — the tricky part

`RegionSelector` is a borderless **`NSPanel` with `[.nonactivatingPanel]`**,
`level = .screenSaver`, `sharingType = .none` (invisible to capture), and
`collectionBehavior` including `.canJoinAllSpaces`/`.fullScreenAuxiliary`/`.stationary`
— so it floats over other apps' fullscreen Spaces without stealing focus.

`RegionView` does its own hit-testing: only the four corner grabbers and the centered
W×H label box are interactive; the empty middle returns `nil` from `hitTest` so clicks
pass through to the app behind. While recording it fades to a thin white outline and
`hitTest` returns `nil` everywhere (fully click-through). **Note in code:** it deliberately
does *not* toggle `window.ignoresMouseEvents` — flipping that true→false was what broke
click-through after a recording, so passthrough is handled entirely in `hitTest`.

`captureInfo()` maps the panel's frame to `(displayID, sourceRect, pixelW, pixelH)`:
picks the screen with the largest overlap, clamps the window to it, converts to
**display-local top-left points** (with a Y-flip), and multiplies by the backing scale
for pixels.

Screen identification: `NumberOverlayView` panels flash a big number on each physical
display, matched to the picker order, shown/hidden as the screen popover opens/closes.

## UI layout (`ContentView`)

A single `VStack` of cards (`SectionCard` modifier):

1. **Recording toolbar** — Region/Fullscreen segmented picker, screen picker (with
   number overlays), Mic checkbox + device picker, Screen-audio / Cursor checkboxes,
   Record button.
2. **Preview unit** (one bordered block): the `PlayerView` (an `NSViewRepresentable`
   wrapping an `AVPlayerLayer`), the **`CropOverlay`** (dim-outside + draggable corners,
   all math in fitted-rect space via `fittedRect`), a clip/queue bar, the play button,
   and the **`Timeline`** (custom handles with a wide hit zone, scrub-on-background, and
   trim handles that clamp against each other). Drag-and-drop is an `.onDrop` on the
   preview. The preview is the only flexible row (`layoutPriority(-1)`) so controls are
   never clipped.
3. **Sliders + estimate card** — Resolution (slider + exact W×H px fields), Quality
   (inverted so the knob reads Optimized→Fidelity while `quality` stays 0=fidelity
   underneath), FPS (slider + a typeable field, both clamped to the source rate, matching
   the Windows build). Between the sliders and the estimate sits the vertical
   **export-speed toggle** (custom radio rows): "Fast export — about twice as fast" /
   "Best compression — slower, smallest file" (default). For formats that ignore
   encoder effort (GIF/MPG/WMV) only the Fast row grays out and Best compression shows
   selected (the stored preference survives a format round-trip). The estimate card is
   height-locked to the slider column via a measured `GeometryReader` height.
4. **Output row** — name field, captions popover, format picker, export-folder button,
   Export button.
5. **Status bar** — idle summary, or a determinate progress bar + ETA + Cancel while
   exporting; colored by `statusKind` (info/work/ok/err). After a save it carries the
   **Show in folder** button (see Export pipeline).

## Size estimation (three layers, matching the Windows build)

All model code lives in free functions over an **`EstParams`** snapshot (every
size-affecting setting), so a calibration taken at one set of settings can be
re-evaluated against the model later.

1. **Instant model** (`liveBytes`): a no-encode analytic model — bytes ≈ pixels × fps ×
   duration × bits-per-pixel, where bpp follows the CRF curve (`~6 CRF ≈ half size`),
   plus audio bits. Only the first ~0.3s fallback; rough by design.
2. **Content anchor** (`anchoredBytes`): after load, `fetchAnchor` reads every video
   packet's size via ffprobe (`packet=pts_time,size`, demux only — fast) into a
   per-second cumulative array (`parsePackets` → `Anchor`). The estimate then scales the
   source's REAL bytes for the trim range by `2^(ΔCRF/6) × pixelRatio^0.85 ×
   fpsRatio^0.6 × codecFactor` + audio. Trimming is content-aware (a static intro
   "costs" less than a busy section). GIF stays on the model (palette-driven); srcCrf is
   assumed ~20.
3. **Measured calibration** (`hardEstimate`, auto-run ~300ms after load via
   `scheduleAutoEstimate` and on demand via the button): encodes **three 1.5s windows at
   20/50/80% of the trim** (one window for short trims) with the **same `plan()`
   settings** as export and extrapolates. Stored as `calibBytes`/`calibParams`; the
   displayed estimate multiplies by `measured / estBase(calibParams)` recomputed on
   every read, so the correction stays consistent even when the base improves
   underneath (e.g. the anchor arriving after the measurement). Per-format; reset on
   load; a result for a clip that's no longer loaded is discarded.

The card's sub-line shows which layer is live (`rough` → `live` → `calibrated`, or
`measuring…`), and `captionBytes()` adds a small constant for an embedded sub track.

## Captions (`makeCaptions`)

Extract the trimmed audio as **16 kHz mono PCM** via ffmpeg, then run `whisper-cli`
with `-osrt -otxt` to produce sidecar `.srt`/`.txt`. (`GGML_BACKEND_PATH` is set when
bundled backends are present.) If no audio track, it returns nils. For **Embed subs**
on MP4-family output, a second ffmpeg pass muxes the `.srt` as a soft `mov_text` track
(`-c copy`, English metadata, default disposition).

## Export pipeline

`export()` (background queue):

1. Build crop+scale filter and trim window via `cropTrim()` (even dims, clamped to
   source; appends `scale=…:flags=lanczos` only when output ≠ crop size). The trim is
   applied with **`-ss` before `-i`** (fast keyframe seek + precise decode — still
   frame-accurate when re-encoding) so exporting a section deep into a long file
   doesn't decode everything before it; same for the Web bundle and caption extraction.
2. If captions requested, run `makeCaptions` first (and copy sidecars).
3. Resolve a **collision-free output path** with `uniqueOutputURL` (`clip`, `clip_1`, …).
4. Run **`runFFmpegProgress`** — ffmpeg with `-progress pipe:1`, parsing the last
   `out_time=` to drive the progress bar; `onStart` hands back the `Process` so
   **Cancel** can `terminate()` it. ETA computed from elapsed vs. fraction. It returns
   the **exit code**: success requires `code == 0` (a file merely existing is not
   success — ffmpeg leaves partials behind when it dies mid-encode).
5. On cancel **or failure**, delete the partial file — a broken clip is never left
   where a "Saved" one should be, and a failure never reports "Saved".
6. On success, `advanceAfterExport`: with more clips queued, load the next one
   ("Saved <name> — loading clip x/y"); otherwise show **"Saved to <full path>"** with a
   **Show in folder** button (`NSWorkspace.activateFileViewerSelecting`; `revealURL` is
   cleared by the next status). The message is always about the clip just exported —
   never a generic "Batch complete". A `Glass` sound confirms.

**Web bundle** (`exportWeb`): creates a collision-safe `<name>_forweb/` folder and
encodes a `.webm` then a `.gif` into it, with progress reported for each pass.

## Queue / drag-and-drop

`loadDropped` collects every dropped file/folder (folders expanded to their video
files via `acceptedExts`), **appends** to the queue (never replaces), sorts naturally,
and jumps to the first newly added clip. `navQueue`/`removeCurrent` move through or
prune the queue.

## Build & distribution

- **[build.sh](build.sh)** compiles the single file with `swiftc -O -parse-as-library`
  into a hand-assembled `.app` (Info.plist + icon written inline). `VERSION` at the top
  of the script is stamped into `CFBundleShortVersionString`; the title bar reads it at
  runtime (`gAppVersion`, "SimpleClips — V 1.0x"). The Mac and Windows builds version
  **independently** — bump `VERSION` together with a new entry in
  [Patch notes.md](Patch%20notes.md) (this folder) before building a release.
  - **Signing is deliberate:** a *stable* signature is what preserves the macOS TCC
    grant (Screen Recording) across rebuilds. It uses the first local code-signing
    identity if present, else ad-hoc (which re-randomizes the requirement each build
    and drops the grant). `BUNDLE_ID` is held constant on purpose for the same reason.
  - Hardened runtime + entitlements + secure timestamp are applied **only** for
    notarization (Developer ID), since those need Apple's timestamp service.
- **`./build.sh --bundle`** runs **[scripts/bundle-deps.sh](scripts/bundle-deps.sh)**:
  copies `ffmpeg`/`ffprobe`/`whisper-cli` + the model into the app, then uses
  `dylibbundler` to relocate every dylib to `@executable_path/../Frameworks`, including
  whisper's dlopen'd `libggml-*.so` backend plugins (placed next to `whisper-cli` so
  ggml auto-discovers them). It then verifies no Homebrew paths remain.
- **[scripts/fetch-model.sh](scripts/fetch-model.sh)** downloads `ggml-base.en.bin`
  (~142 MB) from Hugging Face to the expected path.
- **[scripts/notarize.sh](scripts/notarize.sh)** zips, submits to Apple's notary
  service, staples, and validates.
- **[Resources/entitlements.plist](Resources/entitlements.plist)** enables
  `disable-library-validation` and `allow-dyld-environment-variables` so the hardened
  runtime can load the bundled third-party tools and their dylibs.
