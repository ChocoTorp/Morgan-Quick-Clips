// Fast preview proxy.
//
// The <video> element software-decodes, which stutters on demanding sources (high
// resolution and/or high frame rate — e.g. a 1440p/240fps screen recording). So for the
// PREVIEW we make a small, low-fps, densely-keyframed mp4 that scrubs smoothly. Editing
// and export always run on the ORIGINAL file at full resolution/quality — the proxy only
// affects what's shown in the player. (On macOS AVPlayer hardware-decodes the original, so
// it doesn't need this.)
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const { runTool } = require('./ffmpeg');
const { fileBytes } = require('./util');
const { probe } = require('./probe');

const MAX_SIDE = 1280; // cap the longer dimension
const MAX_FPS = 30;

let cachedEncoder = null;

async function pickVideoEncoder(tools) {
  if (cachedEncoder) return cachedEncoder;
  const out = await runTool(tools.ffmpeg, ['-hide_banner', '-encoders']);
  const candidates =
    process.platform === 'darwin'
      ? ['h264_videotoolbox', 'libx264']
      : ['h264_nvenc', 'h264_qsv', 'h264_amf', 'libx264'];
  cachedEncoder = candidates.find((c) => out.includes(c)) || 'libx264';
  return cachedEncoder;
}

// Produce a lightweight mp4 proxy in the temp dir; returns its path (or the original on
// failure). Cached by input path, so re-loading the same clip is instant.
async function makeProxy(tools, inputPath) {
  const hash = crypto.createHash('md5').update(inputPath).digest('hex').slice(0, 12);
  const output = path.join(os.tmpdir(), `scpreview_${hash}.mp4`);
  if (fileBytes(output) > 1000) return output; // already built

  // Compute even target dims (downscale only) from the real source size.
  const info = await probe(tools.ffprobe, inputPath);
  let w = info.w || 1280;
  let h = info.h || 720;
  const longSide = Math.max(w, h);
  if (longSide > MAX_SIDE) {
    const s = MAX_SIDE / longSide;
    w = Math.round(w * s);
    h = Math.round(h * s);
  }
  w = Math.max(2, w - (w % 2));
  h = Math.max(2, h - (h % 2));

  const enc = await pickVideoEncoder(tools);
  const args = ['-y', '-v', 'error', '-i', inputPath, '-vf', `scale=${w}:${h}`];
  if (info.fps > MAX_FPS) args.push('-r', String(MAX_FPS)); // cap fps for smooth playback
  args.push('-c:v', enc);
  if (enc === 'libx264') args.push('-preset', 'ultrafast', '-crf', '23');
  else args.push('-b:v', '6M');
  // Dense keyframes (~1s) so scrubbing/seeking is snappy.
  args.push('-g', '30', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-movflags', '+faststart', output);

  await runTool(tools.ffmpeg, args);
  return fileBytes(output) > 1000 ? output : inputPath;
}

module.exports = { makeProxy, pickVideoEncoder };
