// Resolve ffmpeg / ffprobe / whisper-cli + the Whisper model.
//
// ffmpeg and ffprobe are BUNDLED with the app via the ffmpeg-static / ffprobe-static
// packages, so the app is self-contained — no system install or PATH needed. When the
// app is packaged into an asar, the real binaries live under app.asar.unpacked, so we
// remap the path accordingly. Whisper (captions) is deferred: used if a bundled binary
// is present, otherwise captions are simply unavailable (whisperAvailable() is false).
const fs = require('fs');
const path = require('path');

const EXE = process.platform === 'win32' ? '.exe' : '';

function isExecutable(p) {
  try { fs.accessSync(p, fs.constants.X_OK); return true; } catch { return false; }
}
function fileExists(p) {
  try { fs.accessSync(p); return true; } catch { return false; }
}

// app.asar paths can't be executed; the static binaries are unpacked next to it.
function unpacked(p) {
  return p ? p.replace(/app\.asar([\\/])/, 'app.asar.unpacked$1') : p;
}

function resolveStatic(mod, pick) {
  try {
    const raw = pick(require(mod));
    return raw ? unpacked(raw) : null;
  } catch {
    return null;
  }
}

// opts.ffmpeg / opts.ffprobe  - explicit overrides (tests)
// opts.resourcesDir           - bundle root for an (optional) bundled whisper + model
// opts.whisperModel           - explicit model path for dev
function resolveTools(opts = {}) {
  const ffmpeg = opts.ffmpeg || resolveStatic('ffmpeg-static', (m) => m) || 'ffmpeg';
  const ffprobe = opts.ffprobe || resolveStatic('ffprobe-static', (m) => m.path) || 'ffprobe';

  // Whisper-cli + ggml backends + model. Look in the packaged resources dir first
  // (process.resourcesPath/bin), then a dev location (./resources/<plat>/bin, ./models),
  // so captions work both in the built app and during local development.
  const plat = process.platform === 'darwin' ? 'mac' : 'win';
  const resourcesDir =
    opts.resourcesDir ||
    (process.resourcesPath && fileExists(path.join(process.resourcesPath, 'bin')) ? process.resourcesPath : null);
  const binCandidates = [];
  if (resourcesDir) binCandidates.push(path.join(resourcesDir, 'bin'));
  binCandidates.push(path.join(process.cwd(), 'resources', plat, 'bin'));

  let whisper = 'whisper-cli';
  let binDir = null;
  for (const d of binCandidates) {
    const cand = path.join(d, 'whisper-cli' + EXE);
    if (isExecutable(cand)) { whisper = cand; binDir = d; break; }
  }

  let whisperModel = '';
  const modelCandidates = [];
  if (resourcesDir) modelCandidates.push(path.join(resourcesDir, 'models', 'ggml-base.en.bin'));
  if (opts.whisperModel) modelCandidates.push(opts.whisperModel);
  modelCandidates.push(path.join(process.cwd(), 'models', 'ggml-base.en.bin'));
  for (const m of modelCandidates) { if (fileExists(m)) { whisperModel = m; break; } }

  // ggml backend plugins sit next to whisper-cli (DLLs on Windows, .so on Linux/mac).
  let ggmlBackends = '';
  if (binDir && (fileExists(path.join(binDir, 'ggml-base.dll')) || fileExists(path.join(binDir, 'libggml-base.so')))) {
    ggmlBackends = binDir;
  }

  return { ffmpeg, ffprobe, whisper, whisperModel, ggmlBackends };
}

function whisperAvailable(tools) {
  const hasBinary = tools.whisper === 'whisper-cli' ? false : isExecutable(tools.whisper);
  return hasBinary && !!tools.whisperModel && fileExists(tools.whisperModel);
}

module.exports = { resolveTools, whisperAvailable, fileExists, isExecutable };
