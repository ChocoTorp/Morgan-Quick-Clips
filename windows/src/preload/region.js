// Preload for the floating region-selector window.
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('region', {
  // Toggle OS mouse capture: false while hovering a control, true (click-through) otherwise.
  setIgnore: (ignore) => ipcRenderer.send('region:setIgnore', ignore),
  // Absolute drag: capture start bounds, then apply total mouse delta each move.
  dragStart: () => ipcRenderer.send('region:dragStart'),
  dragMove: (d) => ipcRenderer.send('region:dragMove', d),
  dragEnd: () => ipcRenderer.send('region:dragEnd'),
  // Main tells us recording started/stopped → fade to / from the thin outline.
  onRecording: (cb) => ipcRenderer.on('region:recording', (_e, on) => cb(on)),
});
