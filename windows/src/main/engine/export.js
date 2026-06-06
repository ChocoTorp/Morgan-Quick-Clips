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
  if (fs.existsSync(output)) return { ok: true, output, cancelled: false, error: null };
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

  const ok = fs.existsSync(webm) && fs.existsSync(gif);
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
  // Sample ~1/4 in over a window long enough that one keyframe doesn't dominate.
  const sampleDur = Math.min(4.0, Math.max(0.5, durSel));
  const sampleStart = st + Math.max(0, (durSel - sampleDur) * 0.25);
  const factor = durSel / sampleDur;
  const tmp = os.tmpdir();

  const sample = async (f) => {
    const p = plan(f, quality, vfCrop, opts.fps);
    const o = path.join(tmp, 'est.' + extFor(f));
    await runTool(tools.ffmpeg, [
      '-y', '-v', 'error', '-ss', String(sampleStart), '-i', input, '-t', String(sampleDur),
      '-vf', p.vf, ...splitArgs(p.codec), o,
    ]);
    return fileBytes(o);
  };

  let bytes;
  if (format === 'Web') bytes = ((await sample('WEBM')) + (await sample('GIF'))) * factor;
  else if (format === 'GIF') bytes = (await sample('GIF')) * factor;
  else if (format === 'WEBM') bytes = (await sample('WEBM')) * factor;
  else bytes = (await sample(format)) * factor;
  return bytes;
}

// Finish a screen recording: transcode the raw MediaRecorder webm to a clean, seekable
// h264 mp4 at a CONSTANT frame rate equal to the display's refresh (opts.fps). The whole
// stream is transcoded (no -ss/-t), which writes a correct duration — fixing the "one
// frame" bug from MediaRecorder webm having no duration header. For region recordings, crop
// in the same pass. crop is in recorded pixels: { x, y, w, h } | null (full frame).
//
// Why CFR at the display rate (not "passthrough"): the editor — and the person using it —
// need ONE real, constant number. Screen capture is variable-rate (frames only on change),
// so passthrough would make a 240Hz recording read as its average (~28fps), which is
// meaningless to edit from. Locking to the display rate makes the file genuinely that rate;
// static moments duplicate frames, which x264 compresses to near-nothing.
async function finishRecording(opts) {
  const { tools, input, output } = opts;
  const rate = Math.max(1, Math.min(240, Math.round(opts.fps || 60)));
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
  // total=0: duration is unknown/untrusted for the raw webm, so we don't report a fraction.
  await runFFmpegProgress(tools.ffmpeg, args, 0, { onStart: opts.onStart, onProgress: opts.onProgress });
  return fs.existsSync(output) && fileBytes(output) > 1000;
}

module.exports = { buildCropFilter, exportClip, exportWeb, hardEstimate, finishRecording };
