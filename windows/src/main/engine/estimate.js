// Size estimation, ported from the macOS app.
//
// liveBytes(): instant, no-encode size model for the live readout. Rough by design —
// it scales a per-pixel-per-frame bitrate by the CRF curve (~6 CRF ~ half the size).
// anchoredBytes(): the better live estimate — anchored to the source file's OWN bytes
// (see parsePackets) instead of a fixed content constant, because real content varies
// by 10-30x (a static screen recording compresses far better than camera video).
// captionBytes()/estSig() mirror the originals so the UI can decide when a measured
// "Harder estimate" result is still fresh.
const { clamp } = require('./util');

// p: { outFormat, quality, outW, outH, srcFps, fpsOverride, trimStart, trimEnd, capBurn }
function liveBytes(fmt, p) {
  const dur = Math.max(0.05, p.trimEnd - p.trimStart);
  const px = Math.max(2, p.outW) * Math.max(2, p.outH);
  const src = p.srcFps > 0 ? p.srcFps : 30;
  const fps = p.fpsOverride != null ? p.fpsOverride : Math.round(src);
  const q = clamp(p.quality, 0, 1);
  switch (fmt) {
    case 'GIF': {
      const gfps = 20 - q * 8;
      const bpp = 0.5 - q * 0.3; // bytes per pixel-frame (palettized)
      return px * gfps * dur * bpp;
    }
    case 'WEBM': {
      const crf = 18 + q * 22;
      const bpp = 0.05 * Math.pow(2.0, (31 - crf) / 6);
      const abits = (192 - q * 96) * 1000 * dur;
      return (bpp * px * fps * dur + abits) / 8;
    }
    case 'Web':
      return liveBytes('WEBM', p) + liveBytes('GIF', p);
    case 'MPG':
    case 'WMV': {
      const crf = 14 + q * 16;
      const bpp = 0.08 * Math.pow(2.0, (22 - crf) / 6) * 2.2; // older codecs ~2x larger
      return (bpp * px * fps * dur + 192 * 1000 * dur) / 8;
    }
    default: {
      // H.264 family
      const crf = 14 + q * 16;
      const bpp = 0.08 * Math.pow(2.0, (22 - crf) / 6);
      const abits = (256 - q * 160) * 1000 * dur;
      return (bpp * px * fps * dur + abits) / 8;
    }
  }
}

// ---- content-anchored estimate ----------------------------------------------

// Parse ffprobe "-show_entries packet=pts_time,size -of csv=p=0" output (video stream
// only) into 1-second byte buckets. Returns { cum, total }: cum[i] = total video bytes
// before second i, so any trim range becomes an O(1) lookup. Packets with no usable
// timestamp fall into the last seen bucket.
function parsePackets(csv) {
  const buckets = [];
  let total = 0;
  let lastSec = 0;
  for (const line of String(csv).split(/\r?\n/)) {
    const c = line.indexOf(',');
    if (c < 0) continue;
    const t = parseFloat(line.slice(0, c));
    const size = parseInt(line.slice(c + 1), 10);
    if (!(size > 0)) continue;
    const sec = Number.isFinite(t) && t >= 0 ? Math.floor(t) : lastSec;
    lastSec = sec;
    buckets[sec] = (buckets[sec] || 0) + size;
    total += size;
  }
  const cum = [0];
  for (let i = 0; i < buckets.length; i++) cum.push(cum[i] + (buckets[i] || 0));
  return { cum, total };
}

// Source video bytes in [a, b] seconds, linearly interpolated inside buckets.
function rangeBytes(cum, a, b) {
  if (!cum || cum.length < 2) return 0;
  const max = cum.length - 1;
  const at = (t) => {
    const x = clamp(t, 0, max);
    const i = Math.floor(x);
    return i >= max ? cum[max] : cum[i] + (cum[i + 1] - cum[i]) * (x - i);
  };
  return Math.max(0, at(b) - at(a));
}

// Content-anchored estimate: scale the source's REAL bytes for the trimmed range by
// quality (the same ~6-CRF-halves-size rule liveBytes uses), pixel ratio (sublinear:
// downscaled content keeps more detail per pixel), fps ratio (sublinear: duplicate and
// near-static frames are nearly free), and a codec factor. Returns null when it can't
// apply (no anchor data, or GIF whose size is palette- not CRF-driven) — the caller
// falls back to liveBytes. anchor: { cum, total, srcW, srcH, srcCrf } (srcCrf = 18 for
// our recording masters, ~20 assumed for imports).
function anchoredBytes(fmt, p, anchor) {
  if (!anchor || !anchor.cum || !(anchor.total > 0)) return null;
  if (fmt === 'GIF') return null;
  if (fmt === 'Web') {
    const w = anchoredBytes('WEBM', p, anchor);
    return w == null ? null : w + liveBytes('GIF', p);
  }
  const srcBytes = rangeBytes(anchor.cum, p.trimStart, p.trimEnd);
  if (!(srcBytes > 0)) return null;
  const dur = Math.max(0.05, p.trimEnd - p.trimStart);
  const q = clamp(p.quality, 0, 1);
  const srcPx = Math.max(2, anchor.srcW) * Math.max(2, anchor.srcH);
  const outPx = Math.max(2, p.outW) * Math.max(2, p.outH);
  const srcFps = p.srcFps > 0 ? p.srcFps : 30;
  const fps = p.fpsOverride != null ? p.fpsOverride : Math.round(srcFps);
  // One H.264-equivalent quality curve for every codec (matches plan()'s h264 family);
  // VP9/MPEG-2/WMV efficiency differences are folded into a flat codec factor instead.
  const outCrf = 14 + q * 16;
  const codecF = fmt === 'WEBM' ? 0.7 : fmt === 'MPG' || fmt === 'WMV' ? 2.2 : 1.0;
  const video =
    srcBytes *
    Math.pow(2, ((anchor.srcCrf || 20) - outCrf) / 6) *
    Math.pow(outPx / srcPx, 0.85) *
    Math.pow(fps / srcFps, 0.6) *
    codecF;
  const akbps = fmt === 'WEBM' ? 192 - q * 96 : fmt === 'MPG' || fmt === 'WMV' ? 192 : 256 - q * 160;
  return video + (akbps * 1000 * dur) / 8;
}

// Rough size of an embedded soft-subtitle track (mov_text), MP4 family only.
function captionBytes(p) {
  if (!p.capBurn || !['MP4', 'MOV', 'M4V'].includes(p.outFormat)) return 0;
  const dur = Math.max(0.05, p.trimEnd - p.trimStart);
  return dur * 30; // ~30 bytes/sec of dialogue
}

// A fingerprint of every setting that affects output size.
function estSig(p) {
  return (
    `${p.outFormat}|${Math.trunc(p.quality * 100)}|${p.fpsOverride != null ? p.fpsOverride : -1}|` +
    `${p.outW}x${p.outH}|${Math.trunc(p.trimStart * 10)}-${Math.trunc(p.trimEnd * 10)}|${!!p.capBurn}`
  );
}

module.exports = { liveBytes, anchoredBytes, parsePackets, rangeBytes, captionBytes, estSig };
