# SimpleClips

SimpleClips is a native macOS app for turning screen recordings and existing videos
into short, polished clips. Record or drop in footage, crop and trim it visually, dial
in the exact size and quality, add captions, and export to the format you need.
Everything runs on your Mac, with no network access.

## Features

**Record your screen.** Capture a full display, choose a specific monitor (on-screen
numbers show you which is which), or drag a resizable box over just the region you
want. The region box floats above fullscreen apps and stays in place as you switch
desktops, and you can include the cursor, your microphone, and system audio. While
recording, the region fades to a thin outline you can click straight through.

**Bring in almost any video.** Drop in MP4, MOV, M4V, GIF, WebM, MKV, AVI, WMV, FLV,
TS, MPG, MPEG, 3GP, F4V, and more, a single file or a whole batch. Anything macOS
cannot play back natively gets a fast preview automatically, so scrubbing always
works. Your original file is never changed.

**Crop and trim visually.** Turn on Crop and drag the corner dots to frame your shot.
Drag the handles on the timeline to set the start and end. A live readout shows the
resolution, length, and source size as you work.

**Size it exactly.** A resolution slider scales the output as a percentage of your
crop, or you can type the exact width or height in pixels. The other dimension follows
automatically, and you can only scale down from real pixels, never upscale.

**Choose quality with one slider.** Slide from Optimized to High fidelity. This changes
compression only and never touches resolution, so the size you set is the size you get.
Fidelity favors detail, optimization favors small files.

**Set the frame rate.** Lower the frame rate to shrink the file, or keep the source
rate. The slider never exceeds the original frame rate.

**See the size before you export.** A live estimate shows the projected file size and
how much smaller it is than the source, for example "saves 78%". Run Harder estimate
for an exact figure measured from a real sample of your settings.

**Add captions, generated on your Mac.** Transcription runs entirely offline. Embed a
subtitle track you can toggle on and off, save a sidecar `.srt`, and save a plain
`.txt` transcript.

**Export to whatever you need.** MP4, GIF, WebM, a Web bundle (a `.webm` plus a `.gif`
in a `*_forweb` folder), or MOV, M4V, MKV, AVI, WMV, FLV, TS, MPG, 3GP, F4V. One click
saves the file to your chosen folder with auto-numbered names (`clip`, `clip_1`, and so
on) so nothing is ever overwritten.

**Work through a batch.** Drop in several files or a folder and move through them with
Prev, Next, and Remove, exporting each with the same settings.

## How it works

SimpleClips is a single Swift app built with SwiftUI and AppKit. Everything happens
locally, and the app opens zero network connections.

- Screen capture uses ScreenCaptureKit in process, so the recording permission
  attaches to the app and the recorder writes the movie itself.
- All media work runs through `ffmpeg`, `ffprobe`, and `whisper-cli`. These are called
  with argument arrays rather than a shell command, so filenames and paths can never
  inject commands.
- Captions are transcribed offline against a bundled Whisper model. The ggml compute
  backends (CPU, Metal, BLAS) load from inside the app.
- A single planning step is the source of truth for encode settings, shared by both the
  export and the size estimate, so the estimate reflects exactly what export will
  produce. Quality maps to compression settings only, never to scaling, and resolution
  comes solely from your crop and the size fields.
- Formats macOS cannot preview natively get a fast hardware proxy so the timeline stays
  smooth, while editing and export always run on the original file at full quality.

## Build

```bash
# Dev build: compiles only, uses Homebrew ffmpeg/whisper at runtime.
brew install ffmpeg whisper-cpp dylibbundler
./scripts/fetch-model.sh           # downloads the Whisper model (about 142 MB)
./build.sh                         # writes build/SimpleClips.app
open "build/SimpleClips.app"

# Self-contained build: bundles ffmpeg, whisper, the ggml backends, and the model.
./build.sh --bundle                # about 182 MB, runs with no Homebrew present
```

You need the Xcode command line tools (`swiftc`) and the macOS 15 or later SDK. The
`--bundle` build also needs `dylibbundler` plus the Homebrew tools and the model on the
build machine, which get copied into the app. With `--bundle`, ffmpeg, whisper, and the
ggml compute backends all run from inside the bundle with an empty PATH and no Homebrew.

`build.sh` signs with a local code-signing certificate from your keychain when one is
present, which keeps the Screen Recording permission stable across rebuilds, and falls
back to ad-hoc signing otherwise.

## How self-containment works (`--bundle`)

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

## Layout

```
Sources/ClipEditor.swift     the whole app
Resources/AppIcon.icns       app icon
Resources/entitlements.plist hardened-runtime entitlements (notarization)
build.sh                     compile, optionally bundle, sign
scripts/bundle-deps.sh       bundle ffmpeg/whisper/backends/model into the app
scripts/fetch-model.sh       download the Whisper model
scripts/notarize.sh          notarize and staple
```

## Licensing

The app code is yours to license. Third-party components: ffmpeg (LGPL or GPL depending
on the build), whisper.cpp (MIT), and the Whisper models (MIT). Review those obligations
before redistributing binaries.
