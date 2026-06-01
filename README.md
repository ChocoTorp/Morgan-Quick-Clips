# SimpleClips

SimpleClips is a native macOS app for turning screen recordings and existing video
files into short, polished clips. Record or drop in footage, crop and trim it
visually, set the exact output size, add captions, and export to the format you
need. It runs entirely on your machine with no network access.

## For video editors

**Record your screen.** Capture a full display, pick a specific monitor (on-screen
numbers tell you which is which), or drag a resizable box over just the region you
want. The box floats above fullscreen apps. You can include the cursor, your
microphone, and system audio.

**Bring in almost any video.** Drop in MP4, MOV, M4V, GIF, WebM, MKV, AVI, WMV, FLV,
TS, MPG/MPEG, 3GP, F4V, and more, one file or a whole batch. Formats macOS can't play
back natively get a fast preview proxy automatically, so scrubbing always works. Your
original file is never modified; all editing and export run on it directly.

**Crop and trim.** Drag the four corner handles to crop. Drag the yellow end handles
on the timeline to trim (each has an arrow showing which way it moves).

**Set the output size exactly.** Type the output width or height in pixels. The other
dimension follows the crop's aspect ratio automatically, and you can't upscale past
the crop, so you only ever resize down from real pixels.

**Pick a quality target.** High fidelity, Balanced, or High optimization. These change
compression only and never touch resolution, so the size you set is the size you get.
High fidelity favors detail over file size; High optimization favors small files.

**Set the frame rate** if you want, or keep the source.

**Add captions, generated locally.** Transcription runs offline with Whisper. Embed a
toggleable subtitle track in the MP4, save a sidecar `.srt`, and/or save a plain
`.txt` transcript.

**Export to whatever you need.** MP4, GIF, WebM, a Web bundle (a `.webm` plus a `.gif`
in a `*_forweb` folder), or MOV, M4V, MKV, AVI, WMV, FLV, TS, MPG, 3GP, F4V. One click
drops the file into your chosen folder with auto-numbered names (`clip`, `clip_1`, and
so on) and never overwrites. Run **Estimate size** first to preview the result and how
much smaller it is than the source, for example `71.5 MB MP4 (was 106 MB MP4)`.

## For developers

Architecture:

- One Swift file (`Sources/ClipEditor.swift`), SwiftUI plus AppKit, built with
  `swiftc`. There is no Xcode project.
- Screen capture uses ScreenCaptureKit in-process (`SCStream` plus
  `SCRecordingOutput`), so the permission attaches to the app and the recorder writes
  the movie itself.
- All media work calls `ffmpeg`, `ffprobe`, and `whisper-cli` through `Process` with
  argument arrays, never a shell string, so filenames and paths cannot inject
  commands.
- Transcription runs offline against a bundled GGML model; the ggml compute backends
  (CPU, Metal, BLAS) load from inside the app.
- No networking anywhere. The app opens zero connections.

`plan()` is the single source of truth for encode settings, shared by export and the
size estimator so the estimate matches the real output. The quality presets map to
codec settings (CRF, preset, bitrate) and never to scaling; resolution comes only from
the crop and the output-size fields.

## Build

```bash
# Dev build: compiles only, uses Homebrew ffmpeg/whisper at runtime.
brew install ffmpeg whisper-cpp dylibbundler
./scripts/fetch-model.sh           # downloads the Whisper model (about 142 MB)
./build.sh                         # writes build/SimpleClips.app (ad-hoc signed)

# Self-contained build: bundles ffmpeg, whisper, the ggml backends, and the model.
./build.sh --bundle                # about 182 MB, runs with no Homebrew present
open "build/SimpleClips.app"
```

You need the Xcode command line tools (`swiftc`) and the macOS 15+ SDK. The `--bundle`
build also needs `dylibbundler` plus the Homebrew tools and the model on the build
machine, which get copied into the app. This has been verified: with `--bundle`,
ffmpeg, whisper, and the ggml compute backends all run from inside the bundle with an
empty PATH and no Homebrew.

### How self-containment works (`--bundle`)

`scripts/bundle-deps.sh` copies the tools into the app and rewrites their dylib load
paths so nothing points back at Homebrew:

```
Contents/Helpers/      ffmpeg, ffprobe, whisper-cli, libggml-*.so (compute backends)
Contents/Frameworks/   dependent dylibs (libav*, x264/x265, libggml*, libomp, etc.)
Contents/Resources/    ggml-base.en.bin (Whisper model), AppIcon.icns
```

`resolveTools()` loads the tools and model from the bundle when present and falls back
to Homebrew for dev builds. The ggml backend plugins sit next to `whisper-cli` so ggml
discovers them on any machine.

Captions use soft, embedded subtitles (`mov_text`) plus the sidecar `.srt` and `.txt`.
Burned-in captions need an ffmpeg built with `libass`, which the bundled ffmpeg does
not include.

## Shipping it for download

The app is self-contained. To distribute it to other people you still need:

1. An Apple Developer Program membership, which provides a Developer ID Application
   certificate.
2. A signed and notarized build:
   ```bash
   SIGN_ID="Developer ID Application: Your Name (TEAMID)" ./build.sh --bundle
   ./scripts/notarize.sh "build/SimpleClips.app"
   ```
   `build.sh` applies the hardened runtime and `Resources/entitlements.plist` when it
   sees a Developer ID (or `NOTARIZE=1`); `notarize.sh` submits to Apple and staples
   the ticket. Local and self-signed builds use plain signing with no timestamp.
3. A universal build if you want Intel support. The current build is arm64 only,
   because the bundled tools are arm64.
4. macOS 15 or later (ScreenCaptureKit `SCRecordingOutput`).
5. Compliance with ffmpeg's license. Bundling ffmpeg built with x264/x265 makes the
   distribution GPL, so provide the corresponding source or a written offer.

## Layout

```
Sources/ClipEditor.swift     the whole app
Resources/AppIcon.icns       app icon
Resources/entitlements.plist hardened-runtime entitlements (notarization)
build.sh                     compile, optionally bundle, sign
scripts/bundle-deps.sh       bundle ffmpeg/whisper/backends/model into the app
scripts/fetch-model.sh       download the Whisper model
scripts/notarize.sh          notarize and staple (after you have a Developer ID)
```

## Licensing

The app code is yours to license. Third-party components: ffmpeg (LGPL or GPL
depending on the build), whisper.cpp (MIT), and the Whisper models (MIT). Review those
obligations before redistributing binaries.
