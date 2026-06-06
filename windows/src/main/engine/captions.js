// Offline captions via whisper.cpp, ported from makeCaptions() in the macOS app.
// Extracts the trimmed audio as 16 kHz mono PCM, then transcribes to .srt + .txt.
const os = require('os');
const path = require('path');
const { runTool } = require('./ffmpeg');
const { fileBytes } = require('./util');
const { whisperAvailable } = require('./tools');

// Returns { srt, txt } absolute temp paths (or null each if unavailable / no audio).
async function makeCaptions(tools, input, st, dur) {
  if (!whisperAvailable(tools)) return { srt: null, txt: null };
  const tmp = os.tmpdir();
  const wav = path.join(tmp, 'mbcap.wav');
  const base = path.join(tmp, 'mbcap');

  // whisper wants 16 kHz mono PCM
  await runTool(tools.ffmpeg, [
    '-y', '-v', 'error', '-i', input, '-ss', String(st), '-t', String(dur),
    '-vn', '-ar', '16000', '-ac', '1', '-c:a', 'pcm_s16le', wav,
  ]);
  if (fileBytes(wav) <= 1000) return { srt: null, txt: null }; // no audio track

  const env = tools.ggmlBackends ? { GGML_BACKEND_PATH: tools.ggmlBackends } : undefined;
  await runTool(tools.whisper, ['-m', tools.whisperModel, '-f', wav, '-osrt', '-otxt', '-of', base], { env });

  const srt = base + '.srt';
  const txt = base + '.txt';
  return {
    srt: fileBytes(srt) > 0 ? srt : null,
    txt: fileBytes(txt) > 0 ? txt : null,
  };
}

module.exports = { makeCaptions };
