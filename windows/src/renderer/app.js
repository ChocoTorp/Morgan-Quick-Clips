'use strict';
// SimpleClips renderer — the editor UI. Talks to the media engine only through the
// `window.clips` IPC bridge (see src/preload/index.js). Ports the behavior of
// ContentView in the macOS app (Sources/ClipEditor.swift).

const $ = (id) => document.getElementById(id);

// Chromium <video> can decode these directly; everything else gets an ffmpeg proxy.
const NATIVE = new Set(['mp4', 'm4v', 'webm', 'ogg', 'ogv']);

// ---- state -----------------------------------------------------------------
const S = {
  input: null,
  ext: '',
  srcW: 0, srcH: 0, duration: 0, srcFps: 0,
  current: 0, trimStart: 0, trimEnd: 0,
  cropOn: false, cropX: 0, cropY: 0, cropW: 0, cropH: 0,
  outW: 0, outH: 0,
  quality: 0.5, fps: 30,
  outFormat: 'MP4', outName: 'clip',
  capEmbed: false, capSrt: false, capTxt: false,
  hasCaptions: false,
  queue: [], queueIndex: 0,
  exportFolder: '', folderName: 'Desktop',
  playing: false, exporting: false, exportCancelled: false,
  origBytes: 0,
  // Calibration from a "Harder estimate": multiplier that corrects the live model's
  // systematic error for this clip/format, so the live number stays anchored to reality
  // and scales sensibly as sliders move (instead of jumping back to a wildly-off value).
  calib: null, calibFormat: '',
  whisper: false,
  // recording
  mode: 'full', sources: [], selectedIndex: 0,
  mic: false, sys: false, micDeviceId: '',
  recording: false, recElapsed: 0,
};

// ---- pure display helpers (formatting only; sizing model lives in the engine) ----
function mmss(t) { const s = Math.round(t || 0); return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`; }
function humanSize(b) { return b >= 1048576 ? `${(b / 1048576).toFixed(1)} MB` : `${(b / 1024).toFixed(0)} KB`; }
function qLabel(q) {
  if (q < 0.2) return 'high fidelity';
  if (q < 0.45) return 'fidelity-leaning';
  if (q <= 0.55) return 'balanced';
  if (q < 0.8) return 'optimized-leaning';
  return 'high optimization';
}
function evenInt(v) { const i = Math.round(v); return Math.max(2, i - (i % 2)); }
function clamp(v, lo, hi) { return Math.min(Math.max(v, lo), Math.max(lo, hi)); }
function fileURL(p) {
  let s = p.replace(/\\/g, '/');
  if (!s.startsWith('/')) s = '/' + s;
  return 'file://' + encodeURI(s).replace(/#/g, '%23').replace(/\?/g, '%3F');
}
function fittedRect(cw, ch, sw, sh) {
  if (!(sw > 0 && sh > 0 && cw > 0 && ch > 0)) return { x: 0, y: 0, w: 0, h: 0 };
  const scale = Math.min(cw / sw, ch / sh);
  const w = sw * scale, h = sh * scale;
  return { x: (cw - w) / 2, y: (ch - h) / 2, w, h };
}

const video = $('video');

function setStatus(msg, kind = 'info') {
  $('statusText').textContent = msg;
  const el = $('status');
  el.classList.remove('ok', 'err');
  if (kind === 'ok') el.classList.add('ok');
  if (kind === 'err') el.classList.add('err');
  $('statusIcon').textContent = kind === 'ok' ? '✓' : kind === 'err' ? '⚠' : kind === 'work' ? '◐' : 'ℹ';
}

// ---- fps override ----------------------------------------------------------
function fpsOverride() {
  const v = Math.round(S.fps);
  if (!(v > 0)) return null;
  if (S.srcFps > 0 && Math.abs(v - S.srcFps) < 0.5) return null; // at source -> no -r
  return Math.min(v, 240);
}

// ---- estimate params + signature (mirror estimate.js / estSig) -------------
function estParams() {
  return {
    outFormat: S.outFormat, quality: S.quality,
    outW: S.outW, outH: S.outH, srcFps: S.srcFps, fpsOverride: fpsOverride(),
    trimStart: S.trimStart, trimEnd: S.trimEnd, capBurn: S.capEmbed,
  };
}
function estSig(p) {
  return `${p.outFormat}|${Math.trunc(p.quality * 100)}|${p.fpsOverride != null ? p.fpsOverride : -1}|` +
    `${p.outW}x${p.outH}|${Math.trunc(p.trimStart * 10)}-${Math.trunc(p.trimEnd * 10)}|${!!p.capBurn}`;
}
function captionBytes(p) {
  if (!p.capBurn || !['MP4', 'MOV', 'M4V'].includes(p.outFormat)) return 0;
  return Math.max(0.05, p.trimEnd - p.trimStart) * 30;
}

// Instant size model — mirrors src/main/engine/estimate.js liveBytes so the estimate can
// update SYNCHRONOUSLY as the sliders move (no IPC round-trip, no debounce). Rough by
// design: a per-pixel-per-frame bitrate scaled by the CRF curve (~6 CRF ≈ half the size).
function liveBytes(fmt, p) {
  const dur = Math.max(0.05, p.trimEnd - p.trimStart);
  const px = Math.max(2, p.outW) * Math.max(2, p.outH);
  const src = p.srcFps > 0 ? p.srcFps : 30;
  const fps = p.fpsOverride != null ? p.fpsOverride : Math.round(src);
  const q = Math.min(Math.max(p.quality, 0), 1);
  switch (fmt) {
    case 'GIF': { const gfps = 20 - q * 8; const bpp = 0.5 - q * 0.3; return px * gfps * dur * bpp; }
    case 'WEBM': {
      const crf = 18 + q * 22; const bpp = 0.05 * Math.pow(2, (31 - crf) / 6);
      return (bpp * px * fps * dur + (192 - q * 96) * 1000 * dur) / 8;
    }
    case 'Web': return liveBytes('WEBM', p) + liveBytes('GIF', p);
    case 'MPG': case 'WMV': {
      const crf = 14 + q * 16; const bpp = 0.08 * Math.pow(2, (22 - crf) / 6) * 2.2;
      return (bpp * px * fps * dur + 192 * 1000 * dur) / 8;
    }
    default: {
      const crf = 14 + q * 16; const bpp = 0.08 * Math.pow(2, (22 - crf) / 6);
      return (bpp * px * fps * dur + (256 - q * 160) * 1000 * dur) / 8;
    }
  }
}

let estimating = false; // a real measurement (sample encode) is running
function updateEstimate() {
  if (!S.input) return;
  const p = estParams();
  let base = liveBytes(S.outFormat, p);
  const calibrated = S.calib && S.calibFormat === S.outFormat;
  if (calibrated) base *= S.calib; // anchor to the measured sample, scale from there
  const shown = base + captionBytes(p);
  $('estBytes').textContent = '≈ ' + humanSize(shown);
  $('estFmt').textContent = S.outFormat;
  const saveEl = $('estSave');
  if (S.origBytes > 0) {
    const pct = (1 - shown / S.origBytes) * 100;
    saveEl.textContent = pct >= 0 ? `−${Math.round(pct)}%` : `+${Math.round(-pct)}%`;
    saveEl.className = 'save ' + (pct >= 0 ? 'pos' : 'neg');
  } else saveEl.textContent = '';
  $('estSub').textContent =
    (S.origBytes > 0 ? `was ${humanSize(S.origBytes)} · ` : '') + qLabel(S.quality) +
    ' · ' + (estimating ? 'measuring…' : calibrated ? 'calibrated' : 'live');
}
// Now instant (the model is a cheap synchronous calc); kept as an alias for call sites.
function scheduleEstimate() { updateEstimate(); }

// ---- load / queue ----------------------------------------------------------
async function load(path) {
  S.input = path;
  S.ext = (path.split('.').pop() || '').toLowerCase();
  $('loading').classList.remove('hidden');
  $('hint').classList.add('hidden');
  setStatus('Inspecting ' + path.split(/[\\/]/).pop() + '…', 'work');
  // Switching clips always starts paused — reset both the state and the button glyph so the
  // new clip shows ▶ (previously it kept the old clip's pause icon).
  video.pause(); S.playing = false; $('playBtn').textContent = '▶';

  const [info, size] = await Promise.all([window.clips.probe(path), window.clips.fileSize(path)]);
  S.srcW = info.w; S.srcH = info.h; S.duration = info.duration; S.srcFps = info.fps;
  S.origBytes = size;

  let previewPath = path;
  if (!NATIVE.has(S.ext)) {
    setStatus('Building preview for .' + S.ext + '…', 'work');
    previewPath = await window.clips.proxy(path); // mp4 proxy; editing still uses the original
  }
  video.src = fileURL(previewPath);
  video.load();

  S.trimStart = 0; S.trimEnd = S.duration; S.current = 0;
  S.cropOn = false;
  resetCropFull();
  // The clip's real frame rate. Recordings are constant-rate at the display refresh, so this
  // reads e.g. 240; imports read their own rate. The fps control only ever reduces from here.
  const srcFps = info.fps > 0 ? Math.round(info.fps) : 30;
  S.srcFps = srcFps;
  S.fps = srcFps;
  S.calib = null; S.calibFormat = '';
  S.hasCaptions = info.hasSubs && NATIVE.has(S.ext);
  S.outName = 'clip';
  S.outFormat = S.ext === 'gif' ? 'GIF' : S.ext === 'webm' ? 'WEBM' : 'MP4';

  $('loading').classList.add('hidden');
  $('outName').value = S.outName;
  $('formatSel').value = S.outFormat;
  const fpsMax = Math.max(2, Math.round(S.srcFps || 30));
  $('fpsSlider').max = String(fpsMax);
  $('fpsSlider').value = String(Math.round(S.fps));
  $('fpsNum').max = String(fpsMax);
  $('fpsNum').value = String(Math.round(S.fps));
  $('qSlider').value = String(1 - S.quality);
  setStatus('Loaded ' + path.split(/[\\/]/).pop(), 'info');
  renderAll();
  updateEstimate();
  // Measure a real sample at the default settings so the size estimate is honest from the
  // moment the clip opens (the raw model is a poor guess, especially for recordings).
  // Debounced so flipping through a batch only measures the clip you land on.
  scheduleAutoEstimate();
}

let autoEstTimer = null;
function scheduleAutoEstimate() {
  clearTimeout(autoEstTimer);
  autoEstTimer = setTimeout(function run() {
    if (estimating) { autoEstTimer = setTimeout(run, 300); return; } // wait for the prior one
    hardEstimate();
  }, 300);
}

function resetCropFull() { S.cropX = 0; S.cropY = 0; S.cropW = S.srcW; S.cropH = S.srcH; syncOutToCrop(); }
function syncOutToCrop() { S.outW = evenInt(S.cropW); S.outH = evenInt(S.cropH); }

async function addPaths(paths) {
  const files = await window.clips.expandPaths(paths);
  if (!files.length) return;
  const firstNew = S.queue.length;
  S.queue = S.queue.concat(files);
  S.queueIndex = firstNew;
  await load(S.queue[firstNew]);
}
function navQueue(d) {
  const i = S.queueIndex + d;
  if (i < 0 || i >= S.queue.length) return;
  S.queueIndex = i; load(S.queue[i]);
}
function removeCurrent() {
  if (!S.queue.length) return;
  S.queue.splice(Math.min(S.queueIndex, S.queue.length - 1), 1);
  if (!S.queue.length) {
    S.input = null; S.srcW = 0; video.removeAttribute('src'); video.load();
    $('hint').classList.remove('hidden');
    setStatus('Queue empty — drop or record a clip.', 'info');
    renderAll();
  } else {
    if (S.queueIndex >= S.queue.length) S.queueIndex = S.queue.length - 1;
    load(S.queue[S.queueIndex]);
  }
}

// ---- playback --------------------------------------------------------------
function togglePlay() {
  if (!S.input) return;
  if (S.playing) { video.pause(); S.playing = false; }
  else {
    if (S.current >= S.trimEnd - 0.02 || S.current < S.trimStart) seek(S.trimStart);
    video.play(); S.playing = true;
  }
  $('playBtn').textContent = S.playing ? '❚❚' : '▶';
}
function seek(t) { video.currentTime = Math.max(0, t); S.current = t; renderTimeline(); }

function tick() {
  if (S.input) {
    S.current = video.currentTime;
    if (S.playing && S.trimEnd > S.trimStart && S.current >= S.trimEnd - 0.02) seek(S.trimStart);
    renderTimeline();
  }
  requestAnimationFrame(tick);
}

// ---- crop overlay ----------------------------------------------------------
function renderCrop() {
  const layer = $('cropLayer');
  if (!S.input || !S.cropOn || S.srcW <= 0) { layer.classList.add('hidden'); layer.innerHTML = ''; return; }
  layer.classList.remove('hidden');
  const pv = $('preview').getBoundingClientRect();
  const fit = fittedRect(pv.width, pv.height, S.srcW, S.srcH);
  const scale = S.srcW > 0 ? fit.w / S.srcW : 1;
  const rx = fit.x + S.cropX * scale, ry = fit.y + S.cropY * scale;
  const rw = S.cropW * scale, rh = S.cropH * scale;

  layer.innerHTML =
    `<div class="crop-box" id="cropBox" style="left:${rx}px;top:${ry}px;width:${rw}px;height:${rh}px;box-shadow:0 0 0 9999px rgba(0,0,0,0.45)">
       <div class="crop-handle" data-c="tl" style="left:-7px;top:-7px"></div>
       <div class="crop-handle" data-c="tr" style="right:-7px;top:-7px"></div>
       <div class="crop-handle" data-c="bl" style="left:-7px;bottom:-7px"></div>
       <div class="crop-handle" data-c="br" style="right:-7px;bottom:-7px"></div>
     </div>`;

  const box = $('cropBox');
  box.addEventListener('pointerdown', (e) => {
    if (e.target.classList.contains('crop-handle')) return; // handle drags resize
    startCropDrag(e, 'move', scale);
  });
  layer.querySelectorAll('.crop-handle').forEach((h) =>
    h.addEventListener('pointerdown', (e) => { e.stopPropagation(); startCropDrag(e, h.dataset.c, scale); })
  );
}

function startCropDrag(e, mode, scale) {
  e.preventDefault();
  const start = { x: e.clientX, y: e.clientY, cx: S.cropX, cy: S.cropY, cw: S.cropW, ch: S.cropH };
  const move = (ev) => {
    const dx = (ev.clientX - start.x) / scale, dy = (ev.clientY - start.y) / scale;
    if (mode === 'move') {
      S.cropX = clamp(start.cx + dx, 0, S.srcW - start.cw);
      S.cropY = clamp(start.cy + dy, 0, S.srcH - start.ch);
    } else {
      let x = start.cx, y = start.cy, w = start.cw, h = start.ch;
      if (mode === 'tl') { x = start.cx + dx; y = start.cy + dy; w = start.cw - dx; h = start.ch - dy; }
      if (mode === 'tr') { y = start.cy + dy; w = start.cw + dx; h = start.ch - dy; }
      if (mode === 'bl') { x = start.cx + dx; w = start.cw - dx; h = start.ch + dy; }
      if (mode === 'br') { w = start.cw + dx; h = start.ch + dy; }
      if (w < 16) { w = 16; x = Math.min(x, start.cx + start.cw - 16); }
      if (h < 16) { h = 16; y = Math.min(y, start.cy + start.ch - 16); }
      x = clamp(x, 0, S.srcW - 16); y = clamp(y, 0, S.srcH - 16);
      w = clamp(w, 16, S.srcW - x); h = clamp(h, 16, S.srcH - y);
      S.cropX = x; S.cropY = y; S.cropW = w; S.cropH = h;
    }
    syncOutToCrop();
    renderCrop(); renderClipBar(); renderSliders(); scheduleEstimate();
  };
  const up = () => { document.removeEventListener('pointermove', move); document.removeEventListener('pointerup', up); };
  document.addEventListener('pointermove', move);
  document.addEventListener('pointerup', up);
}

// ---- timeline --------------------------------------------------------------
const INSET = 14;
function renderTimeline() {
  const tl = $('timeline').getBoundingClientRect();
  const W = Math.max(1, tl.width - INSET * 2);
  const dur = Math.max(S.duration, 0.001);
  const has = S.duration > 0;
  const xStart = INSET + (has ? S.trimStart / dur : 0) * W;
  const xEnd = INSET + (has ? S.trimEnd / dur : 1) * W;
  const xCur = INSET + (has ? S.current / dur : 0) * W;
  $('sel').style.left = (xStart - INSET) + 'px';
  $('sel').style.width = Math.max(0, xEnd - xStart) + 'px';
  $('playhead').style.left = (xCur - INSET) + 'px';
  $('hStart').style.left = (xStart - 6.5) + 'px';
  $('hEnd').style.left = (xEnd - 6.5) + 'px';
  $('timeLabel').textContent = `Time ${mmss(S.current)} / ${mmss(S.duration)}`;
  $('trimLabel').textContent = `Trim ${mmss(S.trimStart)} → ${mmss(S.trimEnd)} (${mmss(S.trimEnd - S.trimStart)})`;
}

function timelineDrag(which) {
  return (e) => {
    e.preventDefault();
    const move = (ev) => {
      const tl = $('timeline').getBoundingClientRect();
      const W = Math.max(1, tl.width - INSET * 2);
      const dur = Math.max(S.duration, 0.001);
      const t = clamp(((ev.clientX - tl.left - INSET) / W) * dur, 0, S.duration);
      if (which === 'start') { S.trimStart = clamp(t, 0, S.trimEnd - 0.1); seek(S.trimStart); }
      else if (which === 'end') { S.trimEnd = clamp(t, S.trimStart + 0.1, S.duration); seek(S.trimEnd); }
      else seek(t);
      renderTimeline(); scheduleEstimate();
    };
    move(e);
    const up = () => { document.removeEventListener('pointermove', move); document.removeEventListener('pointerup', up); };
    document.addEventListener('pointermove', move);
    document.addEventListener('pointerup', up);
  };
}

// ---- sliders + fields ------------------------------------------------------
function renderSliders() {
  const cw = evenInt(S.cropW), ch = evenInt(S.cropH);
  const pct = cw > 0 ? Math.min(100, Math.round((S.outW / cw) * 100)) : 100;
  $('resSlider').value = String(pct);
  $('resPct').textContent = pct + '%';
  $('outW').value = String(S.outW);
  $('outH').value = String(S.outH);
  $('fpsSlider').value = String(Math.round(S.fps));
  $('fpsNum').value = String(Math.round(S.fps));
}

// ---- render orchestration --------------------------------------------------
function renderClipBar() {
  const bar = $('clipBar');
  if (!S.queue.length) { bar.classList.add('hidden'); return; }
  bar.classList.remove('hidden');
  const name = (S.input || '').split(/[\\/]/).pop();
  $('clipLabel').textContent = `Clip ${S.queueIndex + 1} of ${S.queue.length}: ${name}`;
  $('capNote').classList.toggle('hidden', !S.hasCaptions);
  $('cropToggle').classList.toggle('active', S.cropOn);
  const showCropExtras = S.cropOn && S.srcW > 0;
  $('cropSize').classList.toggle('hidden', !showCropExtras);
  $('cropReset').classList.toggle('hidden', !showCropExtras);
  if (showCropExtras) $('cropSize').textContent = `${evenInt(S.cropW)}×${evenInt(S.cropH)}`;
  const multi = S.queue.length > 1;
  $('prevBtn').classList.toggle('hidden', !multi);
  $('nextBtn').classList.toggle('hidden', !multi);
  $('prevBtn').disabled = S.queueIndex === 0 || S.exporting;
  $('nextBtn').disabled = S.queueIndex >= S.queue.length - 1 || S.exporting;
}

function renderAll() {
  const hasClip = !!S.input;
  $('sliders').classList.toggle('hidden', !hasClip);
  $('exportBtn').disabled = !hasClip || S.exporting;
  $('exportBtn').textContent = S.exporting ? 'Exporting…' : (S.queue.length > 1 ? 'Export & Next' : 'Export');
  renderClipBar();
  renderCrop();
  renderTimeline();
  renderSliders();
}

// ---- captions menu ---------------------------------------------------------
function renderCapNote() {
  const any = S.capEmbed || S.capSrt || S.capTxt;
  const n = [S.capEmbed, S.capSrt, S.capTxt].filter(Boolean).length;
  $('capBtn').textContent = `⊞ Generate captions${n ? ` (${n})` : ''} ▾`;
  const note = $('capNoteMenu');
  if (!any) note.textContent = '';
  else if (!S.whisper) { note.textContent = '⚠ whisper not found'; note.style.color = 'var(--orange)'; }
  else { note.textContent = 'Adds a transcription pass'; note.style.color = 'var(--muted)'; }
}

// A short, pleasant "done" chime (two rising sine notes) — generated in-app, no asset.
function chime() {
  try {
    const ac = new (window.AudioContext || window.webkitAudioContext)();
    const now = ac.currentTime;
    [[880, 0], [1320, 0.11]].forEach(([freq, t]) => {
      const osc = ac.createOscillator();
      const gain = ac.createGain();
      osc.type = 'sine';
      osc.frequency.value = freq;
      osc.connect(gain).connect(ac.destination);
      gain.gain.setValueAtTime(0.0001, now + t);
      gain.gain.exponentialRampToValueAtTime(0.22, now + t + 0.02);
      gain.gain.exponentialRampToValueAtTime(0.0001, now + t + 0.32);
      osc.start(now + t);
      osc.stop(now + t + 0.36);
    });
    setTimeout(() => { try { ac.close(); } catch {} }, 900);
  } catch {}
}

// ---- export ----------------------------------------------------------------
let exportId = 0;
async function doExport() {
  if (!S.input || S.exporting) return;
  S.exporting = true; S.exportCancelled = false;
  exportId++;
  $('exportBtn').disabled = true;
  $('cancelBtn').classList.remove('hidden');
  $('progBar').classList.remove('hidden');
  $('progPct').classList.remove('hidden');
  const wantCaps = S.capEmbed || S.capSrt || S.capTxt;
  const posLbl = S.queue.length > 1 ? ` · clip ${S.queueIndex + 1}/${S.queue.length}` : '';
  setStatus(wantCaps ? 'Transcribing…' : `Exporting ${S.outFormat} · ${qLabel(S.quality)}${posLbl}…`, 'work');

  const opts = {
    id: exportId,
    input: S.input,
    format: S.outFormat,
    quality: S.quality,
    fps: fpsOverride(),
    srcW: S.srcW, srcH: S.srcH,
    crop: S.cropOn ? { x: S.cropX, y: S.cropY, w: S.cropW, h: S.cropH } : null,
    outW: S.outW, outH: S.outH,
    trim: { start: S.trimStart, end: S.trimEnd },
    captions: wantCaps ? { embed: S.capEmbed, srt: S.capSrt, txt: S.capTxt } : null,
    exportFolder: S.exportFolder,
    base: S.outName || 'clip',
  };

  const res = await window.clips.exportClip(opts);
  S.exporting = false;
  $('cancelBtn').classList.add('hidden');
  $('progBar').classList.add('hidden');
  $('progPct').classList.add('hidden');
  $('progFill').style.width = '0';
  $('exportBtn').disabled = false;

  if (res.cancelled) setStatus('Export canceled.', 'info');
  else if (res.ok) {
    chime();
    const saved = (res.output || res.folder || '').split(/[\\/]/).pop();
    if (S.queue.length > 1 && S.queueIndex + 1 < S.queue.length) {
      setStatus(`Saved ${saved} — loading clip ${S.queueIndex + 2}/${S.queue.length}…`, 'ok');
      S.queueIndex++; load(S.queue[S.queueIndex]);
    } else if (S.queue.length > 1) setStatus(`Batch complete — ${S.queue.length} clips exported.`, 'ok');
    else setStatus('Saved ' + saved, 'ok');
  } else setStatus('Export failed: ' + (res.error || 'unknown'), 'err');
  renderAll();
}

window.clips.onProgress((p) => {
  if (p.id !== exportId) return;
  $('progFill').style.width = Math.round(p.frac * 100) + '%';
  $('progPct').textContent = Math.round(p.frac * 100) + '%' + (p.which ? ' (' + p.which + ')' : '');
});

// Encode a short real sample at the current settings and use it to calibrate the live
// model (factor = measured / model). Runs automatically on load (so the first number is
// honest, not a wild guess) and on demand via the button. Cancel-safe: if the clip changes
// while it's encoding, the stale result is discarded.
async function hardEstimate() {
  if (!S.input || S.exporting || estimating) return;
  const forInput = S.input;
  estimating = true;
  $('hardEstBtn').textContent = 'Measuring…';
  $('hardEstBtn').disabled = true;
  updateEstimate();
  const bytes = await window.clips.hardEstimate({
    input: S.input, format: S.outFormat, quality: S.quality, fps: fpsOverride(),
    srcW: S.srcW, srcH: S.srcH, crop: S.cropOn ? { x: S.cropX, y: S.cropY, w: S.cropW, h: S.cropH } : null,
    outW: S.outW, outH: S.outH, trim: { start: S.trimStart, end: S.trimEnd },
  });
  estimating = false;
  $('hardEstBtn').textContent = 'Harder estimate';
  $('hardEstBtn').disabled = false;
  if (S.input !== forInput) return; // switched clips mid-measure → discard
  const model = liveBytes(S.outFormat, estParams());
  S.calib = bytes > 0 && model > 0 ? bytes / model : null;
  S.calibFormat = S.outFormat;
  updateEstimate();
}

// ---- recording -------------------------------------------------------------
let mediaRecorder = null, recChunks = [], recStream = null, recTimer = null;
let recSourceStreams = [];  // every getUserMedia stream, so we can stop all tracks
let recAudioCtx = null;     // WebAudio context when mixing >1 audio source

async function enumerateScreens() {
  try {
    S.sources = await window.clips.screenSources();
    if (S.selectedIndex >= S.sources.length) S.selectedIndex = 0;
    renderScreenBtn();
  } catch { S.sources = []; }
}
function renderScreenBtn() {
  $('screenBtn').textContent = `Screen ${S.selectedIndex} ▾`;
  $('screenBtn').disabled = S.mode === 'region';
}
function renderScreenMenu() {
  const m = $('screenMenu');
  m.innerHTML = '';
  S.sources.forEach((s, i) => {
    const b = document.createElement('button');
    b.className = 'small'; b.textContent = `Screen ${i}`;
    b.onclick = () => { S.selectedIndex = i; m.classList.add('hidden'); renderScreenBtn(); };
    m.appendChild(b);
  });
}

// Fill the mic dropdown. Device labels/ids are only exposed after a mic permission
// grant, so we briefly prime getUserMedia, then enumerate.
async function populateMicDevices() {
  const sel = $('micDevice');
  try {
    const probe = await navigator.mediaDevices.getUserMedia({ audio: true });
    probe.getTracks().forEach((t) => t.stop());
  } catch (e) {
    sel.innerHTML = '<option>Mic access denied</option>';
    return;
  }
  const devices = await navigator.mediaDevices.enumerateDevices();
  const inputs = devices.filter((d) => d.kind === 'audioinput');
  sel.innerHTML = '';
  inputs.forEach((d, i) => {
    const o = document.createElement('option');
    o.value = d.deviceId;
    o.textContent = d.label || `Microphone ${i + 1}`;
    sel.appendChild(o);
  });
  if (inputs.length && !inputs.some((d) => d.deviceId === S.micDeviceId)) S.micDeviceId = inputs[0].deviceId;
  if (S.micDeviceId) sel.value = S.micDeviceId;
}

async function startRecording() {
  let source = S.sources[S.selectedIndex];
  let region = null;
  let refresh = source ? source.refreshRate : 0;
  if (S.mode === 'region') {
    const b = await window.clips.regionBounds();
    if (b) {
      source = S.sources.find((s) => String(s.displayId) === String(b.displayId)) || source;
      region = { winBounds: b.winBounds, displayBounds: b.displayBounds, scaleFactor: b.scaleFactor };
      refresh = b.refreshRate || refresh;
    }
  }
  if (!source) { setStatus('No screen available to record.', 'err'); return; }

  // The recording's frame rate IS the display's refresh rate — a real, constant number the
  // editor can trust (and that the user can deliberately reduce later). Capture at that rate.
  const recRate = Math.max(24, Math.min(240, Math.round(refresh || 60)));

  const videoConstraints = {
    mandatory: {
      chromeMediaSource: 'desktop', chromeMediaSourceId: source.id,
      maxWidth: 3840, maxHeight: 2160, maxFrameRate: recRate,
    },
  };
  recSourceStreams = [];
  recAudioCtx = null;
  try {
    // Desktop video (+ system audio if requested).
    const desktop = await navigator.mediaDevices.getUserMedia({
      audio: S.sys ? { mandatory: { chromeMediaSource: 'desktop' } } : false,
      video: videoConstraints,
    });
    recSourceStreams.push(desktop);

    // Collect audio sources separately, then merge into ONE track (MediaRecorder only
    // records a single audio track, which is why adding a 2nd track dropped the mic).
    const audioStreams = [];
    if (S.sys && desktop.getAudioTracks().length) audioStreams.push(desktop);
    if (S.mic) {
      const micConstraints = S.micDeviceId ? { deviceId: { exact: S.micDeviceId } } : true;
      const micStream = await navigator.mediaDevices.getUserMedia({ audio: micConstraints, video: false });
      recSourceStreams.push(micStream);
      audioStreams.push(micStream);
    }

    const videoTrack = desktop.getVideoTracks()[0];
    let audioTracks = [];
    if (audioStreams.length === 1) {
      audioTracks = audioStreams[0].getAudioTracks();
    } else if (audioStreams.length > 1) {
      // Mix multiple sources (system + mic) into a single track via WebAudio.
      recAudioCtx = new AudioContext();
      const dest = recAudioCtx.createMediaStreamDestination();
      audioStreams.forEach((s) => recAudioCtx.createMediaStreamSource(s).connect(dest));
      audioTracks = dest.stream.getAudioTracks();
    }
    recStream = new MediaStream([videoTrack, ...audioTracks]);
  } catch (e) {
    setStatus('Could not start capture: ' + e.message, 'err');
    recSourceStreams.forEach((s) => s.getTracks().forEach((t) => t.stop()));
    return;
  }

  recChunks = [];
  const mime = MediaRecorder.isTypeSupported('video/webm;codecs=vp9,opus')
    ? 'video/webm;codecs=vp9,opus' : 'video/webm';
  mediaRecorder = new MediaRecorder(recStream, { mimeType: mime });
  mediaRecorder.ondataavailable = (e) => { if (e.data && e.data.size) recChunks.push(e.data); };
  mediaRecorder.onstop = async () => {
    const blob = new Blob(recChunks, { type: 'video/webm' });
    const buf = await blob.arrayBuffer();
    setStatus('Finalizing recording…', 'work');
    const path = await window.clips.saveRecording(buf, region, recRate);
    if (S.mode === 'region') window.clips.regionSetRecording(false);
    if (path) {
      if (!S.queue.length) { S.queue = [path]; S.queueIndex = 0; }
      else { S.queue.push(path); S.queueIndex = S.queue.length - 1; }
      await load(path);
    } else setStatus('Recording produced no file.', 'err');
  };

  mediaRecorder.start(1000); // flush a chunk every second (reliable; avoids one-blob failures)
  S.recording = true;
  S.recElapsed = 0;
  if (S.mode === 'region') window.clips.regionSetRecording(true);
  $('recIdle').classList.add('hidden');
  $('recActive').classList.remove('hidden');
  setStatus(`● Recording${S.mode === 'region' ? ' region' : ''}${S.mic ? ' + mic' : ''}${S.sys ? ' + audio' : ''} — click Stop when done.`, 'work');
  recTimer = setInterval(() => { S.recElapsed++; $('stopBtn').textContent = `■ Stop ${mmss(S.recElapsed)}`; }, 1000);
}

function stopRecording() {
  if (!mediaRecorder) return;
  clearInterval(recTimer); recTimer = null;
  S.recording = false;
  $('recActive').classList.add('hidden');
  $('recIdle').classList.remove('hidden');
  try { mediaRecorder.stop(); } catch {}
  if (recStream) recStream.getTracks().forEach((t) => t.stop());
  recSourceStreams.forEach((s) => s.getTracks().forEach((t) => t.stop()));
  recSourceStreams = [];
  if (recAudioCtx) { try { recAudioCtx.close(); } catch {} recAudioCtx = null; }
}

// ---- wire up events --------------------------------------------------------
function wire() {
  // drag & drop
  const unit = $('unit');
  ['dragenter', 'dragover'].forEach((ev) =>
    unit.addEventListener(ev, (e) => { e.preventDefault(); unit.classList.add('drop'); })
  );
  ['dragleave', 'drop'].forEach((ev) =>
    unit.addEventListener(ev, (e) => { e.preventDefault(); unit.classList.remove('drop'); })
  );
  unit.addEventListener('drop', (e) => {
    const paths = [...e.dataTransfer.files].map((f) => window.clips.pathForFile(f)).filter(Boolean);
    if (paths.length) addPaths(paths);
  });
  $('browseLink').addEventListener('click', async (e) => {
    e.preventDefault();
    const paths = await window.clips.openFiles();
    if (paths.length) addPaths(paths);
  });

  // playback
  $('playBtn').addEventListener('click', togglePlay);
  video.addEventListener('ended', () => { S.playing = false; $('playBtn').textContent = '▶'; });

  // timeline
  $('hStart').addEventListener('pointerdown', timelineDrag('start'));
  $('hEnd').addEventListener('pointerdown', timelineDrag('end'));
  $('track').addEventListener('pointerdown', timelineDrag('scrub'));

  // clip bar
  $('cropToggle').addEventListener('click', () => {
    S.cropOn = !S.cropOn;
    if (!S.cropOn) resetCropFull();
    renderAll(); scheduleEstimate();
  });
  $('cropReset').addEventListener('click', () => { resetCropFull(); renderAll(); scheduleEstimate(); });
  $('prevBtn').addEventListener('click', () => navQueue(-1));
  $('nextBtn').addEventListener('click', () => navQueue(1));
  $('removeBtn').addEventListener('click', removeCurrent);

  // sliders
  $('resSlider').addEventListener('input', (e) => {
    const cw = evenInt(S.cropW), ch = evenInt(S.cropH);
    const f = Math.max(0.1, Math.min(1, Number(e.target.value) / 100));
    S.outW = evenInt(cw * f); S.outH = evenInt(ch * f);
    renderSliders(); scheduleEstimate();
  });
  $('outW').addEventListener('change', (e) => {
    const cw = evenInt(S.cropW), ch = evenInt(S.cropH);
    const aspect = ch > 0 ? cw / ch : 1;
    let w = Math.min(cw, evenInt(Number(e.target.value)));
    S.outW = w; S.outH = Math.min(ch, evenInt(w / aspect));
    renderSliders(); scheduleEstimate();
  });
  $('outH').addEventListener('change', (e) => {
    const cw = evenInt(S.cropW), ch = evenInt(S.cropH);
    const aspect = ch > 0 ? cw / ch : 1;
    let h = Math.min(ch, evenInt(Number(e.target.value)));
    S.outH = h; S.outW = Math.min(cw, evenInt(h * aspect));
    renderSliders(); scheduleEstimate();
  });
  $('qSlider').addEventListener('input', (e) => { S.quality = 1 - Number(e.target.value); scheduleEstimate(); });
  const setFps = (v) => {
    const max = Math.max(1, Math.round(S.srcFps || 30)); // can't exceed the source rate
    S.fps = Math.max(1, Math.min(max, Math.round(Number(v) || 1)));
    renderSliders();
    updateEstimate();
  };
  $('fpsSlider').addEventListener('input', (e) => { S.fps = Number(e.target.value); renderSliders(); updateEstimate(); });
  $('fpsNum').addEventListener('change', (e) => setFps(e.target.value));

  // output row
  $('outName').addEventListener('input', (e) => { S.outName = e.target.value; });
  $('formatSel').addEventListener('change', (e) => { S.outFormat = e.target.value; updateEstimate(); });
  $('folderBtn').addEventListener('click', async () => {
    const f = await window.clips.chooseFolder(S.exportFolder);
    if (f) { S.exportFolder = f; S.folderName = f.split(/[\\/]/).pop(); $('folderBtn').textContent = '📁 ' + S.folderName; }
  });
  $('exportBtn').addEventListener('click', doExport);
  $('cancelBtn').addEventListener('click', () => { S.exportCancelled = true; window.clips.cancelExport(); });

  // captions popover
  $('capBtn').addEventListener('click', () => $('capMenu').classList.toggle('hidden'));
  $('capEmbed').addEventListener('change', (e) => { S.capEmbed = e.target.checked; renderCapNote(); scheduleEstimate(); });
  $('capSrt').addEventListener('change', (e) => { S.capSrt = e.target.checked; renderCapNote(); });
  $('capTxt').addEventListener('change', (e) => { S.capTxt = e.target.checked; renderCapNote(); });

  // hard estimate
  $('hardEstBtn').addEventListener('click', hardEstimate);

  // recording toolbar
  $('modeSeg').querySelectorAll('button').forEach((b) =>
    b.addEventListener('click', () => {
      S.mode = b.dataset.mode;
      $('modeSeg').querySelectorAll('button').forEach((x) => x.classList.toggle('on', x === b));
      if (S.mode === 'region') window.clips.regionOpen(); else window.clips.regionClose();
      renderScreenBtn();
    })
  );
  $('screenBtn').addEventListener('click', () => { renderScreenMenu(); $('screenMenu').classList.toggle('hidden'); });
  $('micChk').addEventListener('change', (e) => {
    S.mic = e.target.checked;
    $('micDevice').classList.toggle('hidden', !S.mic);
    if (S.mic) populateMicDevices();
  });
  $('micDevice').addEventListener('change', (e) => { S.micDeviceId = e.target.value; });
  $('sysChk').addEventListener('change', (e) => { S.sys = e.target.checked; });
  $('recordBtn').addEventListener('click', startRecording);
  $('stopBtn').addEventListener('click', stopRecording);

  // dismiss popovers on outside click
  document.addEventListener('click', (e) => {
    if (!e.target.closest('#capBtn') && !e.target.closest('#capMenu')) $('capMenu').classList.add('hidden');
    if (!e.target.closest('#screenBtn') && !e.target.closest('#screenMenu')) $('screenMenu').classList.add('hidden');
  });

  // keep crop/timeline positioned on resize
  new ResizeObserver(() => { renderCrop(); renderTimeline(); }).observe($('preview'));
  window.addEventListener('resize', () => { renderCrop(); renderTimeline(); });
}

// ---- boot ------------------------------------------------------------------
async function boot() {
  wire();
  const info = await window.clips.toolsInfo();
  S.whisper = !!info.whisper;
  renderCapNote();
  S.exportFolder = await window.clips.defaultFolder();
  S.folderName = S.exportFolder.split(/[\\/]/).pop();
  $('folderBtn').textContent = '📁 ' + S.folderName;
  await enumerateScreens();
  renderAll();
  requestAnimationFrame(tick);
}
boot();

// Dev/smoke hook: lets the main process drive the UI headlessly for verification.
window.__test = { S, load, addPaths, doExport };
