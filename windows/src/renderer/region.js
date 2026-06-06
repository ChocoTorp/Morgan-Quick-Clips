'use strict';
// Region-selector overlay logic. Loaded as an EXTERNAL script — this window's CSP
// (default-src 'self') blocks inline scripts. Move via the center label, resize via the
// four corners, click-through on the transparent middle, fade to a thin outline while
// recording.
//
// Dragging uses an ABSOLUTE model: we capture the window bounds at mousedown (in main)
// and apply the TOTAL mouse delta from the start each move. This avoids the feedback
// that an incremental model has while the window is moving under the cursor (which made
// a move drift into a resize). For a move, width/height are re-set to the start size, so
// it can never change size.
const api = window.region;
const frame = document.getElementById('frame');
const label = document.getElementById('label');
const grips = Array.from(document.querySelectorAll('.grip'));
const interactive = new Set([label, ...grips]);

let recording = false;
let drag = null; // { kind: 'move'|'tl'|'tr'|'bl'|'br' }
let startX = 0;
let startY = 0;

// Show the PHYSICAL pixels being recorded, not logical/DIP pixels. On a scaled display
// (e.g. 150%) the captured video is at physical resolution, so multiply by the device
// pixel ratio (= the display's scale factor) and round to even (yuv420p / crop output).
function updateLabel() {
  const dpr = window.devicePixelRatio || 1;
  const ev = (v) => { const i = Math.round(v); return i - (i % 2); };
  label.textContent = ev(window.innerWidth * dpr) + ' × ' + ev(window.innerHeight * dpr);
}
window.addEventListener('resize', updateLabel);
updateLabel();

// Click-through: keep the window transparent to the mouse except over a control, so the
// clear middle passes clicks to whatever is behind it.
window.addEventListener('mousemove', (e) => {
  if (recording || drag) return;
  api.setIgnore(!interactive.has(e.target));
});

function beginDrag(kind, e) {
  drag = { kind };
  startX = e.screenX;
  startY = e.screenY;
  api.setIgnore(false);
  api.dragStart();
  e.preventDefault();
  e.stopPropagation();
}
label.addEventListener('mousedown', (e) => beginDrag('move', e));
grips.forEach((g) => g.addEventListener('mousedown', (e) => beginDrag(g.id, e)));

window.addEventListener('mousemove', (e) => {
  if (!drag) return;
  api.dragMove({ kind: drag.kind, dx: e.screenX - startX, dy: e.screenY - startY });
});
window.addEventListener('mouseup', () => {
  if (drag) { drag = null; api.dragEnd(); }
});

api.onRecording((on) => {
  recording = on;
  frame.classList.toggle('recording', on);
});
