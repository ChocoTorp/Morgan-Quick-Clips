# Windows build

Drop the Windows build of SimpleClips here (the portable `SimpleClips.exe` and/or
the NSIS `SimpleClips Setup x.y.z.exe` installer).

## How to build it (on a Windows PC)

From the `windows/` folder of the repo:

```sh
npm install
npm run fetch:whisper        # downloads the Whisper model into windows/models
# place the Windows ffmpeg/ffprobe binaries in windows/resources/win/bin
npm run dist:win             # output lands in windows/dist
```

`dist:win` produces both a portable `.exe` and an NSIS installer (see the `win.target`
list in `windows/package.json`). Copy the artifact(s) from `windows/dist` into this folder.
