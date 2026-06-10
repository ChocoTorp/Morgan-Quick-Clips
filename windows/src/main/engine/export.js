// The export pipeline, ported from export()/exportWeb()/hardEstimate() and cropTrim().
const fs = require('fs');
const os = require('os');
const path = require('path');
const { plan, splitArgs } = require('./plan');
const { runTool, runFFmpegProgress } = require('./ffmpeg');
const { extFor, fileBytes, evenInt } = require('./util');
const { makeCaptions } = require('./captions');

// Build the leading -vf "crop=...[,scale=...]" filter from a crop + output size.
// crop is in SOURCE pixels; omit it (null) to use the full frame. outW/outH default
// to the crop size. Downscale only — a scale filter is added only when out != crop.
function buildCropFilter({ srcW, srcH, crop, outW, outH }) {
  let cw = Math.round(crop ? crop.w : srcW);
  let ch = Math.round(crop ? crop.h : srcH);
  let cx = Math.round(crop ? crop.x : 0);
  let cy = Math.round(crop ? crop.y : 0);
  cw -= cw % 2;
  ch -= ch % 2;
  if (cx + cw > srcW) cx = srcW - cw;
  if (cy + ch > srcH) cy = srcH - ch;
  cx = Math.max(0, cx);
  cy = Math.max(0, cy);

  let f = `crop=${cw}:${ch}:${cx}:${cy}`;
  const ow = outW ? evenInt(outW) : cw;
  const oh = outH ? evenInt(outH) : ch;
  if (ow !== cw || oh !== ch) f += `,scale=${ow}:${oh}:flags=lanczos`;
  return f;
}

// Export a single clip.
// opts: {
//   tools, input, output, format, quality, fps (override int|null),
//   srcW, srcH, crop:{x,y,w,h}|null, outW, outH, trim:{start,end},
//   captions:{ embed, srtPath?, txtPath? }|null,
//   onStart(child), onProgress(0..1)
// }
// Returns { ok, output, cancelled, error }.
async function exportClip(opts) {
  const { tools, input, output, format, quality } = opts;
  const st = opts.trim ? opts.trim.start : 0;
  const dur = Math.max(0.05, (opts.trim ? opts.trim.end : 0) - st);
  const vfCrop = buildCropFilter({
    srcW: opts.srcW, srcH: opts.srcH, crop: opts.crop, outW: opts.outW, outH: opts.outH,
  });

  // Optional captions pass (transcribe trimmed audio) before the video encode.
  let srtForEmbed = null;
  if (opts.captions && (opts.captions.embed || opts.captions.srt || opts.captions.txt)) {
    const caps = await makeCaptions(tools, input, st, dur);
    srtForEmbed = caps.srt;
    if (opts.captions.onCaptions) opts.captions.onCaptions(caps);
  }

  const p = plan(format, quality, vfCrop, opts.fps);
  const args = [
    '-y', '-v', 'error', '-progress', 'pipe:1',
    '-i', input, '-ss', String(st), '-t', String(dur),
    '-vf', p.vf, ...splitArgs(p.codec), output,
  ];
  const res = await runFFmpegProgress(tools.ffmpeg, args, dur, {
    onStart: opts.onStart,
    onProgress: opts.onProgress,
  });

  // Embed a soft (toggleable) subtitle track for MP4 when requested.
  const ext = extFor(format);
  if (opts.captions && opts.captions.embed && ext === 'mp4' && srtForEmbed && fs.existsSync(output)) {
    const tmp = output + '.subs.mp4';
    await runTool(tools.ffmpeg, [
      '-y', '-v', 'error', '-i', output, '-i', srtForEmbed, '-map', '0', '-map', '1',
      '-c', 'copy', '-c:s', 'mov_text', '-metadata:s:s:0', 'language=eng',
      '-metadata:s:s:0', 'title=English', '-disposition:s:0', 'default', tmp,
    ]);
    if (fs.existsSync(tmp)) {
      try { fs.unlinkSync(output); } catch {}
      try { fs.renameSync(tmp, output); } catch {}
    }
  }

  if (res.cancelled) {
    try { fs.unlinkSync(output); } catch {}
    return { ok: false, output, cancelled: true, error: null };
  }
  if (res.code === 0 && fs.existsSync(output)) return { ok: true, output, cancelled: false, error: null };
  // ffmpeg failed mid-encode: remove the half-written file so an unplayable clip is
  // never left where the "Saved" one should be.
  try { fs.unlinkSync(output); } catch {}
  return { ok: false, output, cancelled: false, error: res.output.slice(-160) };
}

// "Web" bundle: <name>_forweb/ holding a .webm and a .gif. Returns { ok, folder, error }.
async function exportWeb(opts) {
  const { tools, input } = opts;
  const st = opts.trim ? opts.trim.start : 0;
  const dur = Math.max(0.05, (opts.trim ? opts.trim.end : 0) - st);
  const vfCrop = buildCropFilter({
    srcW: opts.srcW, srcH: opts.srcH, crop: opts.crop, outW: opts.outW, outH: opts.outH,
  });

  let folder = path.join(opts.exportFolder, `${opts.base}_forweb`);
  let n = 1;
  while (fs.existsSync(folder)) folder = path.join(opts.exportFolder, `${opts.base}_forweb_${n++}`);
  fs.mkdirSync(folder, { recursive: true });

  const webm = path.join(folder, `${opts.base}.webm`);
  const gif = path.join(folder, `${opts.base}.gif`);
  const pw = plan('WEBM', opts.quality, vfCrop, opts.fps);
  const pg = plan('GIF', opts.quality, vfCrop, opts.fps);

  const e1 = await runFFmpegProgress(
    tools.ffmpeg,
    ['-y', '-v', 'error', '-progress', 'pipe:1', '-i', input, '-ss', String(st), '-t', String(dur), '-vf', pw.vf, ...splitArgs(pw.codec), webm],
    dur,
    { onStart: opts.onStart, onProgress: (f) => opts.onProgress && opts.onProgress(f, 'webm') }
  );
  if (e1.cancelled) { try { fs.rmSync(folder, { recursive: true, force: true }); } catch {} return { ok: false, folder, cancelled: true }; }

  const e2 = await runFFmpegProgress(
    tools.ffmpeg,
    ['-y', '-v', 'error', '-progress', 'pipe:1', '-i', input, '-ss', String(st), '-t', String(dur), '-vf', pg.vf, gif],
    dur,
    { onStart: opts.onStart, onProgress: (f) => opts.onProgress && opts.onProgress(f, 'gif') }
  );
  if (e2.cancelled) { try { fs.rmSync(folder, { recursive: true, force: true }); } catch {} return { ok: false, folder, cancelled: true }; }

  const ok = e1.code === 0 && e2.code === 0 && fs.existsSync(webm) && fs.existsSync(gif);
  if (!ok) { try { fs.rmSync(folder, { recursive: true, force: true }); } catch {} }
  return { ok, folder, error: ok ? null : (e1.output + e2.output).slice(-140) };
}

// "Harder estimate": encode a short real sample at the actual export settings and
// extrapolate to the full trim. Returns the estimated total bytes.
async function hardEstimate(opts) {
  const { tools, input, format, quality } = opts;
  const st = opts.trim ? opts.trim.start : 0;
  const durSel = Math.max(0.05, (opts.trim ? opts.trim.end : 0) - st);
  const vfCrop = buildCropFilter({
    srcW: opts.srcW, srcH: opts.srcH, crop: opts.crop, outW: opts.outW, outH: opts.outH,
  });
  // Three short windows spread across the trim (20/50/80%) so one unusually quiet or
  // busy moment can't skew the whole estimate; short trims collapse to a single window.
  const wd = 1.5;
  const windows = durSel <= 6
    ? [{ start: st, dur: Math.min(4.0, Math.max(0.5, durSel)) }]
    : [0.2, 0.5, 0.8].map((f) => ({ start: st + (durSel - wd) * f, dur: wd }));
  const tmp = os.tmpdir();

  const sample = async (f) => {
    const p = plan(f, quality, vfCrop, opts.fps);
    let bytes = 0;
    let sampled = 0;
    for (let i = 0; i < windows.length; i++) {
      const o = path.join(tmp, `est_${i}.` + extFor(f));
      await runTool(tools.ffmpeg, [
        '-y', '-v', 'error', '-ss', String(windows[i].start), '-i', input, '-t', String(windows[i].dur),
        '-vf', p.vf, ...splitArgs(p.codec), o,
      ]);
      bytes += fileBytes(o);
      sampled += windows[i].dur;
    }
    return (bytes * durSel) / sampled; // extrapolate sampled seconds to the full trim
  };

  if (format === 'Web') return (await sample('WEBM')) + (await sample('GIF'));
  if (format === 'GIF') return sample('GIF');
  if (format === 'WEBM') return sample('WEBM');
  return sample(format);
}

// Finish a screen recording: turn the raw MediaRecorder capture into a clean, seekable
// mp4 with a correct duration header (MediaRecorder writes none — the "one frame" bug).
//
// Fast path (opts.h264, no crop): the capture is ALREADY hardware-encoded H.264, so just
// REMUX — copy the compressed video into the mp4 and re-encode only the audio to AAC
// (seconds of work regardless of length; this is how the Mac app feels instant). The
// master keeps the capture's real, variable frame timing.
//
// Slow path (VP9 fallback, or region recordings that must crop): full transcode to CFR
// h264 at the capture rate (opts.fps, ≤120). CFR because a variable-rate transcode of a
// variable-rate source compounds timing problems, and the editor needs a real number.
// EXPORTS default to ≤60 regardless: H.264 above 60fps at screen resolutions exceeds
// Level 5.2, which is where Windows' built-in decoder stops.
// crop is in recorded pixels: { x, y, w, h } | null (full frame).
async function finishRecording(opts) {
  const { tools, input, output } = opts;
  // opts.duration (the renderer's recording clock) is the progress total; the raw
  // capture's own duration header is missing/untrusted.
  const run = (args) => runFFmpegProgress(tools.ffmpeg, args, opts.duration || 0, {
    onStart: opts.onStart, onProgress: opts.onProgress,
  });
  const finished = () => fs.existsSync(output) && fileBytes(output) > 1000;

  if (opts.h264 && !opts.crop) {
    const res = await run([
      '-y', '-v', 'error', '-progress', 'pipe:1', '-i', input,
      '-c:v', 'copy', '-c:a', 'aac', '-b:a', '192k', '-movflags', '+faststart', output,
    ]);
    if (res.code === 0 && finished()) return true;
    // fall through: an odd capture that won't remux still gets the full transcode
  }

  const rate = Math.max(1, Math.min(120, Math.round(opts.fps || 60)));
  const args = ['-y', '-v', 'error', '-progress', 'pipe:1', '-i', input];
  if (opts.crop) {
    const vf = buildCropFilter({
      srcW: opts.srcW, srcH: opts.srcH, crop: opts.crop, outW: opts.crop.w, outH: opts.crop.h,
    });
    args.push('-vf', vf);
  }
  args.push(
    '-r', String(rate), '-fps_mode', 'cfr',
    '-c:v', 'libx264', '-crf', '18', '-preset', 'veryfast', '-pix_fmt', 'yuv420p',
    '-c:a', 'aac', '-movflags', '+faststart', output
  );
  const res = await run(args);
  return res.code === 0 && finished();
}

module.exports = { buildCropFilter, exportClip, exportWeb, hardEstimate, finishRecording };
