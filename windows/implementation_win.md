# SimpleClips — Implementation Notes

> How the Windows app is actually built. Read [`spec.md`](../spec.md) first for *what* it
> should do. This doc is the source of truth for picking up work on the Windows build.

## Repository layout

```
/                          shared spec + git
  spec.md                  product intent + architecture (platform-agnostic)
  Downloadable builds/     shipped installers (exes git-ignored; versioned names)
  mac/                     macOS app — Swift/SwiftUI/AppKit (the ORIGINAL)
    implementation_Mac.md  how the macOS app is built
    Patch notes.md         Mac release notes (versions independently of Windows)
  windows/                 Windows app — Electron (the rebuild)
    implementation_win.md  this file
    Patch notes.md         Windows release notes (V1.01, V1.02, ...)
```

**Rule:** Windows work only edits `windows/` (and the shared root `spec.md`). The macOS
app in `mac/` is the original native app and is not touched from the PC. They are separate
codebases that implement the same [`spec.md`](../spec.md).

> ⚠️ Windows is case-insensitive: `mac/Resources` and `windows/resources` would collide if
> they shared a parent — that's why each lives under its own platform folder.

---

## Windows app (`windows/`)

Electron. The renderer is plain HTML/CSS/JS (no framework/build step). The "engine" is
pure Node calling ffmpeg/ffprobe/whisper — no Electron deps, so it's unit-testable.

```
windows/
  package.json            Electron + electron-builder config (build targets, icon, asarUnpack)
  src/
    main/index.js         main process: window (hidden native titlebar + overlay buttons),
                          permissions, IPC handlers (media:*, rec:save, region:*, shell:reveal,
                          app:version), region overlay
    main/engine/          the media engine (pure Node, no Electron):
      tools.js            resolve bundled ffmpeg/ffprobe (ffmpeg-static) + whisper/model
      plan.js             format+quality -> ffmpeg -vf filtergraph + codec args (single source of truth)
      export.js           buildCropFilter, exportClip, exportWeb, hardEstimate, finishRecording
      probe.js            ffprobe: dims/duration/fps/subtitles + packetStats (per-second byte histogram)
      estimate.js         liveBytes model + content-anchored estimator (mirrored in the renderer)
      ffmpeg.js           runTool + runFFmpegProgress (spawn, -progress parsing)
      captions.js         makeCaptions (ffmpeg extract wav -> whisper-cli -> srt/txt)
      proxy.js            preview proxy (non-native formats) + scrub proxy (drag-scrubbing)
      util.js             humanSize/mmss/extFor/uniqueOutputPath/etc.
    preload/index.js      contextBridge IPC for the main window
    preload/region.js     contextBridge IPC for the region overlay
    renderer/index.html   editor UI
    renderer/app.js       editor logic (state, load, crop/timeline, sliders, estimate, export, recording)
    renderer/styles.css   dark theme
    renderer/region.html  region selector overlay (EXTERNAL region.js — inline is CSP-blocked!)
    renderer/region.js    region overlay logic (move/resize/click-through/fade)
  tools/engine-cli.js     headless: probe|export|estimate <file>
  tools/engine-test.js    pure-logic unit checks (npm test)
  scripts/make-icon.mjs   build/icon-source.png -> build/icon.png + build/icon.ico
  scripts/fetch-whisper.mjs  download whisper-cli + ggml-base.en model (git-ignored)
  build/                  icon assets (icon-source.png from the user, icon.ico/png generated)
  resources/win/bin/      bundled whisper-cli.exe + ggml DLLs (fetched, git-ignored)
  models/                 ggml-base.en.bin (fetched, git-ignored)
```

### How recording works (the tricky part)
The guiding principle: **capture is hardware-encoded H.264, so finishing a recording is a
remux, not a re-encode** — Stop is near-instant, matching the Mac app (ScreenCaptureKit).
1. Main reads the display's refresh via `screen.getAllDisplays()[i].displayFrequency` and
   returns it as `refreshRate` on each `screen:sources` entry and in `region:bounds`.
2. Renderer `startRecording` records at the display's refresh **clamped 24–120** (above
   ~60fps at screen resolutions H.264 crosses Level 5.2, where Windows' built-in decoder
   stops; 120 keeps high-refresh motion for deliberate high-fps exports without a 240fps
   master's encode cost).
3. Audio: system audio via Chromium desktop loopback (no driver), mic via a chosen device.
   Multiple sources are **mixed into one track via WebAudio** (MediaRecorder records only one
   audio track — adding a 2nd silently dropped the mic).
4. `MediaRecorder` prefers **H.264 mp4** (`video/mp4;codecs=avc1...`, hardware-encoded via
   Media Foundation; VP9/webm is the fallback), with an explicit bitrate (~0.05 bits/px/frame,
   clamped 8–24 Mbps — the default ~2.5 Mbps looks awful at screen sizes). 1s timeslice for
   reliable flushing.
5. On stop, the capture + region rect + rate + wall-clock duration go to `rec:save` →
   `engine.finishRecording`:
   - **Fast path** (H.264, no crop): remux — `-c:v copy`, audio re-encoded to AAC, `+faststart`.
     Writes a correct duration header (fixes MediaRecorder's no-duration "one frame" bug) in
     well under a second regardless of length. The master keeps its real variable frame timing.
   - **Slow path** (VP9 fallback, or region recordings that must crop): full transcode to CFR
     h264 at the capture rate. Region crop maps logical→physical pixels via the display
     **scaleFactor**, so the recorded resolution matches what the overlay reported (HiDPI).
   - Progress streams to the status bar via `media:progress` (`id:'rec'`), with the renderer's
     recording clock as the total (the raw capture's duration header is untrusted).
   - On failure the raw capture is **kept** and returned (Chromium can still play it) — never
     delete the only copy of a recording.
6. Region overlay is excluded from capture with `setContentProtection(true)` (Win10 2004+).
7. In the editor, the **fps slider defaults to min(source, 60)** (`load()`), so default
   exports stay playable in stock Windows players; the slider still reaches the source rate.

### Scrubbing (coalesced seeks + scrub proxy)
- All seeks go through a **coalesced seeker** (one seek in flight per `<video>`; only the
  latest target is kept) so fast drags don't queue stale seeks the picture then replays.
- After load, `media:scrubProxy` builds a **scrub proxy** in the background
  (`engine.makeScrubProxy`: ≤640px, 15fps, keyframe every ~0.5s (`-g 8`), no audio, hardware
  encoder when available, cached by path+size in tmp). While dragging the playhead/trim
  handles, a second stacked `<video>` shows the proxy (instant seeks); on release it hides
  and the full-res master settles on the exact frame. Until the proxy is ready, drags scrub
  the master. A newer clip's request kills an in-flight build; failed/killed builds delete
  their partial file so the cache can't be poisoned.

### Region overlay (`renderer/region.{html,js}`)
- Loaded as an **external** script — the window's CSP blocks inline scripts (this was the
  bug that broke resize/fade/label).
- Default state is **click-through** (`setIgnoreMouseEvents(true, {forward:true})`); the
  renderer re-enables capture only while hovering the center label or a corner grip.
- **Move** via the center label, **resize** via 4 corners — both use an absolute
  drag-anchor model (capture bounds at mousedown, apply total delta) so a move can't drift
  into a resize. Main applies it in `region:dragMove`.
- Shows **physical** pixels (logical × devicePixelRatio) to match the recording.

### Engine / estimate (three layers, all mirrored renderer-side for synchronous updates)
- `plan()` is the single source of truth for encode settings (shared by export + estimate).
1. **Instant model** (`liveBytes`): pure-math bits-per-pixel × CRF curve. Only the first
   ~0.3s fallback — a fixed content constant is off by 10-30x for screen recordings.
2. **Content anchor** (`anchoredBytes`): after load, `media:packets` →
   `probe.packetStats` reads every video packet's size (demux only, ~0.3s for 5 min) into a
   per-second cumulative array. The estimate then scales the source's REAL bytes for the
   trim range by 2^(ΔCRF/6) × pixelRatio^0.85 × fpsRatio^0.6 × codecFactor + audio. Trim
   becomes content-aware (a static intro "costs" less than a busy section). GIF stays on
   the model (palette-driven). srcCrf is assumed ~20.
3. **Measured calibration** ("Harder estimate", auto-run ~300ms after load): encodes three
   1.5s windows at 20/50/80% of the trim (one window for short trims) at the ACTUAL export
   settings and extrapolates. Stored as `{calibBytes, calibParams}`; the displayed estimate
   multiplies by `measured / base(calibParams)` recomputed on every read, so the correction
   stays consistent even when the base improves underneath (e.g. the anchor arriving after
   the measurement). Per-format; reset on load.
- The estimate sub-line shows which layer is live: `rough` → `live` → `calibrated`
  (each segment is an unbreakable span so the line wraps only at the `·` separators).
- Export correctness: `exportClip`/`exportWeb` require ffmpeg **exit code 0** and delete
  partial output on failure — a broken file is never left where a "Saved" one should be.
- On success the status shows `Saved to <path>` + a **Show in folder** button
  (`shell:reveal` → `shell.showItemInFolder`).

### Bundling & packaging
- ffmpeg/ffprobe: `ffmpeg-static` + `ffprobe-static`, `asarUnpack`ed, resolved with an
  `app.asar`→`app.asar.unpacked` path remap in `tools.js`. No system ffmpeg/PATH.
- whisper: `whisper-cli.exe` + ggml DLLs in `resources/win/bin`, model in `models/`,
  shipped via electron-builder `extraResources`. Re-fetch with `npm run fetch:whisper`.
- Icon: `build/icon.ico` (from `build/icon-source.png` via `npm run icon`), set as the
  runtime `BrowserWindow` icon (a **real file** in `extraResources`, not an asar path) and
  the build/nsis icon. `app.setAppUserModelId` set so the taskbar binds it.
- Targets: `nsis` (installer) + `portable` (single exe). Output in `windows/dist/`.

### Build / run / verify (from `windows/`)
```
npm install            # first time
npm run fetch:whisper  # populate resources/win/bin + models (git-ignored)
npm run icon           # regenerate build/icon.* from build/icon-source.png
npm start              # run the app in dev
npm test               # pure-logic engine checks
node tools/engine-cli.js probe|export|estimate <file>   # headless engine
npm run dist:win       # build installer + portable into dist/
```

### Environment gotchas (this PC)
- **`ELECTRON_RUN_AS_NODE=1` is set in the Claude Code shell** and leaks into spawned
  shells → makes electron.exe run as plain Node (`app` undefined). Clear it before launching
  electron: `$env:ELECTRON_RUN_AS_NODE=$null`. A normal user terminal won't have this.
- Node + ffmpeg were winget-installed; new shells need a re-login to get them on PATH, or
  use full paths (`C:\Program Files\nodejs\node.exe`).
- electron-builder's `winCodeSign` extraction fails on Windows without admin/Dev-Mode
  (macOS dylib symlinks). Worked around by pre-populating its cache from a partial
  extraction so `signAndEditExecutable: true` (needed for the portable exe icon) succeeds
  without signing. Unsigned build → SmartScreen warning.
- electron's own binary download via `extract-zip` silently fails here; if `node_modules/
  electron/dist` is missing after `npm install`, the zip is usually already cached at
  `%LOCALAPPDATA%\electron\Cache`. `Expand-Archive` it into `node_modules/electron/dist`
  and write `node_modules/electron/path.txt` = `electron.exe`. Concrete commands are in
  [Producing a downloadable build](#producing-a-downloadable-build) below.

### Producing a downloadable build

`node_modules/`, `dist/`, the whisper binaries, and the model are all git-ignored, so a
fresh checkout needs a few steps before `dist:win` works. This is the exact sequence used
to produce the shipped portable build (run from `windows/`):

```powershell
$env:ELECTRON_RUN_AS_NODE = $null      # clear the leaked Claude Code env (see gotchas)
npm install                            # 400+ packages

# Electron's binary downloads to the cache but fails to extract here (see gotchas).
# The zip is normally already at %LOCALAPPDATA%\electron\Cache; expand it in by hand:
$zip  = Get-ChildItem "$env:LOCALAPPDATA\electron\Cache" -Recurse -Filter "electron-v*-win32-x64.zip" | Select-Object -First 1
$dist = "node_modules\electron\dist"
Remove-Item $dist -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory $dist | Out-Null
Expand-Archive $zip.FullName $dist -Force
Set-Content "node_modules\electron\path.txt" "electron.exe" -NoNewline -Encoding ascii

npm run fetch:whisper                  # only if resources/win/bin + models aren't present
npm run dist:win                       # output -> windows/dist/
```

`dist:win` emits two artifacts (~434 MB each) into `windows/dist/`:
- `SimpleClips <ver>.exe` is the **portable / standalone** single exe (nothing to install).
- `SimpleClips Setup <ver>.exe` is the NSIS installer.

Both bundle ffmpeg/ffprobe (asar-unpacked), `whisper-cli` + DLLs, and the captions model,
so they run fully offline.

**Versioning + patch notes (the release ritual).** Versions iterate **V1.01, V1.02, ...**
in `windows/Patch notes.md` (each platform keeps its own notes and versions
independently — Mac's are in `mac/Patch notes.md`). For each release: bump
`windows/package.json` to the matching semver `1.0.x` BEFORE building (the title bar
reads it at runtime via `app:version`, displayed as `V 1.0x`), build, then copy the
artifacts into `Downloadable builds/Windows/` named with the patch version —
`SimpleClips Setup 1.0x.exe` and `SimpleClips-1.0x-portable.exe` — replacing the previous
pair, and add a simple, readable entry to `windows/Patch notes.md` covering all changes. The
binaries are git-ignored (they exceed GitHub's 100 MB limit); **distribute via GitHub
Releases**, not the repo. (Watch for the portable exe being locked by a running instance —
close SimpleClips first.)

**Unsigned.** With no code-signing cert, first run shows a SmartScreen "unknown publisher"
prompt (More info, then Run anyway). See the `winCodeSign` gotcha above.

### Headless app verification (no GUI needed)
Set env `SMOKE=1`, `SMOKE_SAMPLE=<mp4>`, `SMOKE_OUT=<dir>` and launch electron; a
`window.__test` hook drives a real load+export and prints `SMOKE_RESULT {...}`. Screen
capture / mic / region / real-speech captions still need a human at the machine.

---

## macOS app (`mac/`)

The original native app — single Swift file `mac/Sources/ClipEditor.swift` (SwiftUI/AppKit,
ScreenCaptureKit, AVFoundation). Builds with `mac/build.sh` (Xcode CLT, macOS 15 SDK).
`mac/scripts/` bundles ffmpeg/whisper into the `.app`, fetches the model, and notarizes.
See `mac/README.md`. This is the behavioral reference for the Windows rebuild.
