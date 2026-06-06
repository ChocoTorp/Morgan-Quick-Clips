// Small pure helpers ported from Sources/ClipEditor.swift.
const fs = require('fs');
const path = require('path');

// "~12s left" / "~1m 05s left" for an ETA in seconds.
function etaString(sec) {
  if (!(sec > 0)) return '';
  const s = Math.round(sec);
  return s >= 60 ? `~${Math.floor(s / 60)}m ${String(s % 60).padStart(2, '0')}s left` : `~${s}s left`;
}

// "M:SS" for a time in seconds.
function mmss(t) {
  const s = Math.round(t);
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
}

// Human-readable byte size, matching the macOS app's thresholds/format.
function humanSize(bytes) {
  if (bytes >= 1048576) return `${(bytes / 1048576).toFixed(1)} MB`;
  return `${(bytes / 1024).toFixed(0)} KB`;
}

// File size in bytes, or 0 if it doesn't exist.
function fileBytes(p) {
  try {
    return fs.statSync(p).size;
  } catch {
    return 0;
  }
}

// Output file extension for a format tag.
function extFor(format) {
  switch (format) {
    case 'GIF':
      return 'gif';
    case 'WEBM':
      return 'webm';
    case 'MOV':
      return 'mov';
    case 'M4V':
      return 'm4v';
    case 'MKV':
      return 'mkv';
    case 'AVI':
      return 'avi';
    case 'WMV':
      return 'wmv';
    case 'FLV':
      return 'flv';
    case 'TS':
      return 'ts';
    case 'MPG':
      return 'mpg';
    case '3GP':
      return '3gp';
    case 'F4V':
      return 'f4v';
    default:
      return 'mp4';
  }
}

// A short human label for a fidelity -> optimization slider value (0..1).
function qLabel(q) {
  if (q < 0.2) return 'high fidelity';
  if (q < 0.45) return 'fidelity-leaning';
  if (q <= 0.55) return 'balanced';
  if (q < 0.8) return 'optimized-leaning';
  return 'high optimization';
}

// Last "out_time=HH:MM:SS.us" value (in seconds) from streamed ffmpeg -progress text.
function lastOutTime(s) {
  const i = s.lastIndexOf('out_time=');
  if (i < 0) return null;
  const rest = s.slice(i + 'out_time='.length);
  const line = rest.split(/[\r\n]/)[0];
  const parts = line.split(':');
  if (parts.length !== 3) return null;
  const hh = Number(parts[0]);
  const mm = Number(parts[1]);
  const ss = Number(parts[2]);
  if ([hh, mm, ss].some((n) => Number.isNaN(n))) return null;
  return hh * 3600 + mm * 60 + ss;
}

// base.ext if free; otherwise base_1.ext, base_2.ext, ... (first free number).
function uniqueOutputPath(folder, base, ext) {
  const first = path.join(folder, `${base}.${ext}`);
  if (!fs.existsSync(first)) return first;
  let n = 1;
  let candidate = path.join(folder, `${base}_${n}.${ext}`);
  while (fs.existsSync(candidate)) {
    n += 1;
    candidate = path.join(folder, `${base}_${n}.${ext}`);
  }
  return candidate;
}

// Even integer >= 2 (yuv420p needs even dimensions).
function evenInt(v) {
  const i = Math.round(v);
  return Math.max(2, i - (i % 2));
}

function clamp(v, lo, hi) {
  return Math.min(Math.max(v, lo), Math.max(lo, hi));
}

module.exports = {
  etaString,
  mmss,
  humanSize,
  fileBytes,
  extFor,
  qLabel,
  lastOutTime,
  uniqueOutputPath,
  evenInt,
  clamp,
};
