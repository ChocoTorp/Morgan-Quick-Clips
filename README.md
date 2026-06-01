# SimpleClips

A native macOS app for quickly turning screen recordings and almost any video
file into trimmed, cropped, resized, captioned clips for sharing.

- **Record the screen** (ScreenCaptureKit, in-process): full display, a specific
  display (with on-screen "identify" numbers), or a draggable/resizable region box
  that floats over fullscreen apps. Optional mic, system audio, and cursor.
- **Drop in almost any video** — mp4, mov, m4v, gif, webm, mkv, avi, wmv, flv, ts,
  mpg/mpeg, 3gp, f4v and more (single files or a batch queue). Formats AVKit can't
  play natively get a fast hardware **proxy preview** automatically; editing/export
  always run on the original.
- **Visually crop** (4-corner handles) and **trim** on a timeline (chunky yellow
  end handles with direction arrows).
- **Resize precisely** — type the exact output pixels (aspect-locked to the crop,
  capped at the crop size).
- **Quality presets** — High fidelity / Balanced / High optimization. These only
  change *compression*, never resolution (resolution is yours via the size fields).
- **Set FPS** — keep the source frame rate or override it.
- **Export** to MP4, GIF, WebM, **Web** (`webm` + `gif` in a `*_forweb` folder), or
  MOV / M4V / MKV / AVI / WMV / FLV / TS / MPG / 3GP / F4V. One click to a chosen
  export folder; auto-incrementing names (`clip`, `clip_1`, …) — never overwrites.
- **Estimate size** before exporting, with the savings vs. the original
  (e.g. "≈ 71.5 MB MP4 (was 106 MB MP4)").
- **Captions** (whisper.cpp, offline): embed a toggleable subtitle track, save a
  sidecar `.srt`, and/or save a plain-text `.txt` transcript.

100% offline — no network access at all. External tools (ffmpeg/whisper) are run
via argument arrays (no shell), so filenames can't inject commands.

It's a single Swift file (`Sources/ClipEditor.swift`) compiled with `swiftc`.

## Build

Two modes:

```bash
# Dev build — compiles only; uses Homebrew ffmpeg/whisper at runtime.
brew install ffmpeg whisper-cpp dylibbundler
./scripts/fetch-model.sh           # downloads the Whisper model (~142 MB)
./build.sh                         # → build/SimpleClips.app (ad-hoc)

# Self-contained build — bundles ffmpeg/whisper/backends + model INTO the app.
./build.sh --bundle                # → build/SimpleClips.app (~182 MB, runs with no Homebrew)
open "build/SimpleClips.app"
```

Requires Xcode command line tools (`swiftc`) + macOS 15+ SDK. `--bundle` also needs
`dylibbundler` and the Homebrew tools/model present on the **build** machine (they
get copied in). Verified: with `--bundle`, the app runs ffmpeg + whisper + the ggml
compute backends entirely from inside the bundle, with no Homebrew and an empty PATH.

## How self-containment works (`--bundle`)

`scripts/bundle-deps.sh` copies the tools into the app and rewrites their dylib
links so nothing points at Homebrew:

```
Contents/Helpers/      ffmpeg, ffprobe, whisper-cli, libggml-*.so (compute backends)
Contents/Frameworks/   all dependent dylibs (libav*, x264/x265, libggml*, libomp, …)
Contents/Resources/    ggml-base.en.bin (Whisper model), AppIcon.icns
```

The code (`resolveTools()`) loads tools/model from the bundle when present and
falls back to Homebrew for dev builds. ggml backend plugins sit next to
`whisper-cli` so ggml auto-discovers them on any machine.

> Captions are **soft/embedded** subtitles (`mov_text`) + sidecar `.srt`/`.txt`.
> True burn-in needs an ffmpeg with `libass`, which the bundled ffmpeg lacks.

## Remaining steps before public download

The app is now **self-contained**, but to host it for others you still need:

1. **Apple Developer Program** → a *Developer ID Application* certificate.
2. **Sign + notarize:**
   ```bash
   SIGN_ID="Developer ID Application: Your Name (TEAMID)" ./build.sh --bundle
   ./scripts/notarize.sh "build/SimpleClips.app"
   ```
   (`build.sh` applies the hardened runtime + `Resources/entitlements.plist`;
   `notarize.sh` submits to Apple and staples the ticket.)
3. **Architecture** — built `arm64` only (bundled tools are arm64).
4. **macOS 15+** required (ScreenCaptureKit `SCRecordingOutput`).
5. **Licensing** — the bundled ffmpeg (x264/x265) makes the distribution **GPL**;
   provide the corresponding source/offer when you publish.

## Layout

```
Sources/ClipEditor.swift     # the whole app
Resources/AppIcon.icns       # app icon
Resources/entitlements.plist # hardened-runtime entitlements (for notarization)
build.sh                     # compile + (optional) bundle + sign
scripts/bundle-deps.sh       # bundle ffmpeg/whisper/backends/model into the .app
scripts/fetch-model.sh       # download the Whisper model
scripts/notarize.sh          # notarize + staple (after you have a Developer ID)
```

## Licensing

App code: your choice. Bundled/used third-party: **ffmpeg** (LGPL/GPL depending on
build), **whisper.cpp** (MIT), Whisper models (MIT). Review obligations before
redistributing binaries.
