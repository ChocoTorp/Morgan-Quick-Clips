# SimpleClips

Record screen clips (or drop in videos), trim/crop/resize them, add captions, and export —
all locally, powered by ffmpeg + whisper.cpp.

This repo holds **two builds of the same product**:

| Folder | Platform | Tech | Status |
|--------|----------|------|--------|
| [`mac/`](mac/) | macOS | Swift / SwiftUI / AppKit (original) | reference build |
| [`windows/`](windows/) | Windows | Electron | active rebuild |

- **What it should do:** [`spec.md`](../spec.md) — product intent, shared by both platforms.
- **How it's built:** [`implementation_win.md`](implementation_win.md) — architecture,
  build/run/verify, and gotchas for the Windows app.

The two apps are separate codebases implementing the same spec. Windows work happens in
`windows/`; the macOS app in `mac/` is the behavioral reference and isn't modified from the
PC side.

## Quick start (Windows)

```
cd windows
npm install
npm run fetch:whisper   # download bundled whisper-cli + captions model (git-ignored)
npm start               # run in dev
npm run dist:win        # build the installer + portable .exe into windows/dist/
```

## Quick start (macOS)

See [`mac/README.md`](mac/README.md).
