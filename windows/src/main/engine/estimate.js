// Size estimation, ported from the macOS app.
//
// liveBytes(): instant, no-encode size model for the live readout. Rough by design —
// it scales a per-pixel-per-frame bitrate by the CRF curve (~6 CRF ~ half the size).
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

module.exports = { liveBytes, captionBytes, estSig };
