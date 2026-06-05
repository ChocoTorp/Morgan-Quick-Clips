# SimpleClips — Implementation

How the app is actually built. Pairs with [spec.md](spec.md) (what each feature is
*for*). All UI and logic live in a single Swift file: [Sources/ClipEditor.swift](Sources/ClipEditor.swift)
(~1.8k lines). Media work shells out to `ffmpeg`/`ffprobe`/`whisper-cli`.

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

`plan(format, q, crop, fps)` is the **single source of truth for encode settings**,
shared by both export *and* the estimator so the estimate reflects exactly what export
will do. It returns `(vf:` filtergraph `, codec:` trailing args `)`.

- `q` is a continuous **0…1 fidelity→optimization** value (0 = max fidelity, 1 = max
  optimization). The slider drives this.
- **Per-format curves** map `q` to real encoder knobs:
  - **H.264 family** (MP4/MOV/M4V/MKV/AVI/TS/FLV/F4V/3GP): `libx264`, CRF `14→30`,
    preset `slow/medium/slower`, AAC `256→96 kbps`; `+faststart` for MP4/MOV/M4V;
    baseline profile for 3GP.
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

**AVPlayer only decodes mp4/mov/m4v** (`nativePreviewExts`). For anything else (webm,
mkv, avi, gif, wmv, …) the app transcodes a **fast hardware proxy** (`h264_videotoolbox`,
even-dimension scale) to a temp `scpreview_<hash>.mp4` *purely for scrubbing*.
Editing/export always use the original file. Embedded subtitles are deselected in the
preview (`applyCaptions`) so a "default"-flagged track never shows itself.

## Screen recording (`ScreenRecorder`)

In-process **ScreenCaptureKit** (`@available(macOS 15, *)`):

- `SCStream` + `SCRecordingOutput` write an `.mov` (H.264) directly to a temp file —
  the recording permission attaches to the app itself.
- `SCStreamConfiguration` carries pixel size (even dims), optional `sourceRect` (region),
  cursor, `captureMicrophone`, and `capturesAudio` (system audio).
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
   number overlays), Mic / Screen-audio / Cursor checkboxes, Record button.
2. **Preview unit** (one bordered block): the `PlayerView` (an `NSViewRepresentable`
   wrapping an `AVPlayerLayer`), the **`CropOverlay`** (dim-outside + draggable corners,
   all math in fitted-rect space via `fittedRect`), a clip/queue bar, the play button,
   and the **`Timeline`** (custom handles with a wide hit zone, scrub-on-background, and
   trim handles that clamp against each other). Drag-and-drop is an `.onDrop` on the
   preview. The preview is the only flexible row (`layoutPriority(-1)`) so controls are
   never clipped.
3. **Sliders + estimate card** — Resolution (slider + exact W×H px fields), Quality
   (inverted so the knob reads Optimized→Fidelity while `quality` stays 0=fidelity
   underneath), FPS (max = source). The estimate card is height-locked to the slider
   column via a measured `GeometryReader` height.
4. **Output row** — name field, captions popover, format picker, export-folder button,
   Export button.
5. **Status bar** — idle summary, or a determinate progress bar + ETA + Cancel while
   exporting; colored by `statusKind` (info/work/ok/err).

## Size estimation

- **Live estimate** (`liveBytes`): an instant, no-encode analytic model — bytes ≈
  pixels × fps × duration × bits-per-pixel, where bpp follows the CRF curve
  (`~6 CRF ≈ half size`), plus audio bits. Rough by design.
- **Harder estimate** (`hardEstimate`): encodes a **real sample** (~4s window, started
  ~¼ into the trim to skip atypical openings and avoid a single keyframe dominating)
  with the **same `plan()` settings** as export, then multiplies by `duration/sample`.
- `estSig` fingerprints every size-affecting setting; the measured number
  (`hardBytes`) is only shown while `hardSig == estSig`, otherwise the UI falls back to
  the live model. `captionBytes()` adds a small estimate for an embedded sub track.

## Captions (`makeCaptions`)

Extract the trimmed audio as **16 kHz mono PCM** via ffmpeg, then run `whisper-cli`
with `-osrt -otxt` to produce sidecar `.srt`/`.txt`. (`GGML_BACKEND_PATH` is set when
bundled backends are present.) If no audio track, it returns nils. For **Embed subs**
on MP4-family output, a second ffmpeg pass muxes the `.srt` as a soft `mov_text` track
(`-c copy`, English metadata, default disposition).

## Export pipeline

`export()` (background queue):

1. Build crop+scale filter and trim window via `cropTrim()` (even dims, clamped to
   source; appends `scale=…:flags=lanczos` only when output ≠ crop size).
2. If captions requested, run `makeCaptions` first (and copy sidecars).
3. Resolve a **collision-free output path** with `uniqueOutputURL` (`clip`, `clip_1`, …).
4. Run **`runFFmpegProgress`** — ffmpeg with `-progress pipe:1`, parsing the last
   `out_time=` to drive the progress bar; `onStart` hands back the `Process` so
   **Cancel** can `terminate()` it. ETA computed from elapsed vs. fraction.
5. On cancel, delete the partial file. On success in a batch, `advanceAfterExport`
   loads the next clip; a `Glass` sound confirms.

**Web bundle** (`exportWeb`): creates a collision-safe `<name>_forweb/` folder and
encodes a `.webm` then a `.gif` into it, with progress reported for each pass.

## Queue / drag-and-drop

`loadDropped` collects every dropped file/folder (folders expanded to their video
files via `acceptedExts`), **appends** to the queue (never replaces), sorts naturally,
and jumps to the first newly added clip. `navQueue`/`removeCurrent` move through or
prune the queue.

## Build & distribution

- **[build.sh](build.sh)** compiles the single file with `swiftc -O -parse-as-library`
  into a hand-assembled `.app` (Info.plist + icon written inline).
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
