# macOS build

Drop the macOS build of SimpleClips here (the `SimpleClips.app` bundle, or a packaged
`.dmg`).

## How to build it (on a Mac)

From the `mac/` folder of the repo:

```sh
./build.sh --bundle          # self-contained .app: bundles ffmpeg/whisper + the model
# output lands in mac/build/SimpleClips.app
```

For a signed, notarized build to hand to other people:

```sh
SIGN_ID="Developer ID Application: Name (TEAMID)" ./build.sh --bundle
scripts/notarize.sh           # see mac/scripts/notarize.sh
```

Copy the `.app` (or a packaged `.dmg`) from `mac/build/` into this folder.

> These artifacts are git-ignored and too large for a normal GitHub push (100 MB per-file
> limit). Do not expect them to upload with `git push`. Distribute them via GitHub
> **Releases** (up to 2 GB per file) instead, not the repo.
