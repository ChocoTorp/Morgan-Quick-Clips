# SimpleClips — Implementation Notes

> How the Windows app is actually built. Read [`spec.md`](../spec.md) first for *what* it
> should do. This doc is the source of truth for picking up work on the Windows build.

## Repository layout

```
/                          shared spec + git
  spec.md                  product intent (platform-agnostic)
  mac/                     macOS app — Swift/SwiftUI/AppKit (the ORIGINAL)
    implementation_Mac.md  how the macOS app is built
  windows/                 Windows app — Electron (the rebuild)
    implementation_win.md  this file
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
    main/index.js         main process: window, permissions, IPC handlers, region overlay, rec:save
    main/engine/          the media engine (pure Node, no Electron):
      tools.js            resolve bundled ffmpeg/ffprobe (ffmpeg-static) + whisper/model
      plan.js             format+quality -> ffmpeg -vf filtergraph + codec args (single source of truth)
      export.js           buildCropFilter, exportClip, exportWeb, hardEstimate, finishRecording
      probe.js            ffprobe: dims, duration, fps (avg_frame_rate), subtitles
      estimate.js         liveBytes size model (also mirrored in the renderer for instant updates)
      ffmpeg.js           runTool + runFFmpegProgress (spawn, -progress parsing)
      captions.js         makeCaptions (ffmpeg extract wav -> whisper-cli -> srt/txt)
      proxy.js            preview proxy for formats the player can't decode
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
The guiding principle: **the recorded file's frame rate is the display's refresh rate, as a
CONSTANT rate.** One real number the editor (and the user) can trust and reduce from.
1. Main reads the display's refresh via `screen.getAllDisplays()[i].displayFrequency` and
   returns it as `refreshRate` on each `screen:sources` entry and in `region:bounds`.
2. Renderer `startRecording` picks the chosen display's `refreshRate` (clamped 24–240) as the
   record rate, captures at it (`maxFrameRate`), and passes it to `saveRecording`.
3. Audio: system audio via Chromium desktop loopback (no driver), mic via a chosen device.
   Multiple sources are **mixed into one track via WebAudio** (MediaRecorder records only one
   audio track — adding a 2nd silently dropped the mic).
4. `MediaRecorder` → webm (1s timeslice for reliable flushing).
5. On stop, the webm + region rect + record rate go to main `rec:save`, which runs
   `engine.finishRecording`: transcodes the **whole** stream to a clean seekable mp4 **at
   constant `-r <rate>`** (`-fps_mode cfr`), cropping the region in the same pass.
   - This fixes the MediaRecorder problems (no duration header → one-frame; variable-rate with
     a bogus 1000 timebase) AND gives a real constant rate. Screen capture is inherently VFR
     (frames only on change), so a 240Hz recording's *average* is meaningless (~28fps) — we
     lock to the display rate instead. Static moments duplicate frames; x264 compresses those
     to near-nothing. The editor then probes the file and reads the true rate (e.g. 240).
   - Region crop maps logical→physical pixels via the display **scaleFactor**, so the recorded
     resolution matches what the region overlay reported (matters on HiDPI/150%).
6. Region overlay is excluded from capture with `setContentProtection(true)` (Win10 2004+).

### Region overlay (`renderer/region.{html,js}`)
- Loaded as an **external** script — the window's CSP blocks inline scripts (this was the
  bug that broke resize/fade/label).
- Default state is **click-through** (`setIgnoreMouseEvents(true, {forward:true})`); the
  renderer re-enables capture only while hovering the center label or a corner grip.
- **Move** via the center label, **resize** via 4 corners — both use an absolute
  drag-anchor model (capture bounds at mousedown, apply total delta) so a move can't drift
  into a resize. Main applies it in `region:dragMove`.
- Shows **physical** pixels (logical × devicePixelRatio) to match the recording.

### Engine / estimate
- `plan()` is the single source of truth for encode settings (shared by export + estimate).
- The live estimate is computed **synchronously in the renderer** (`liveBytes` mirrors
  `engine/estimate.js`) so it updates instantly as sliders move — no IPC/debounce.
- "Harder estimate" encodes a real sample via IPC for an exact figure, then **calibrates the
  live model**: it stores `calib = measuredBytes / liveModelBytes` (per format) and the live
  estimate multiplies by `calib` thereafter. So after one hard estimate the live number stays
  anchored to reality and scales sensibly as sliders move, instead of snapping back to the
  raw (often very wrong) model. Reset on load; recomputed per "Harder estimate".

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
  electron/dist` is missing, download the electron zip and `Expand-Archive` it in, then
  write `node_modules/electron/path.txt` = `electron.exe`.

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
