// Preload for the main window — exposes a minimal IPC surface. contextIsolation is
// on, so the renderer never touches Node/Electron internals directly.
const { contextBridge, ipcRenderer, webUtils } = require('electron');

contextBridge.exposeInMainWorld('clips', {
  // info + dialogs
  toolsInfo: () => ipcRenderer.invoke('tools:info'),
  defaultFolder: () => ipcRenderer.invoke('app:defaultFolder'),
  openFiles: () => ipcRenderer.invoke('dialog:openFiles'),
  expandPaths: (paths) => ipcRenderer.invoke('media:expandPaths', paths),
  chooseFolder: (current) => ipcRenderer.invoke('dialog:chooseFolder', current),
  // resolve a dropped File to its absolute path (replaces the removed File.path)
  pathForFile: (file) => webUtils.getPathForFile(file),

  // media engine
  probe: (filePath) => ipcRenderer.invoke('media:probe', filePath),
  proxy: (filePath) => ipcRenderer.invoke('media:proxy', filePath),
  fileSize: (filePath) => ipcRenderer.invoke('media:fileSize', filePath),
  estimate: (params) => ipcRenderer.invoke('media:estimate', params),
  hardEstimate: (opts) => ipcRenderer.invoke('media:hardEstimate', opts),
  exportClip: (opts) => ipcRenderer.invoke('media:export', opts),
  cancelExport: () => ipcRenderer.invoke('media:cancel'),
  onProgress: (cb) => {
    const handler = (_e, payload) => cb(payload);
    ipcRenderer.on('media:progress', handler);
    return () => ipcRenderer.removeListener('media:progress', handler);
  },

  // screen recording
  screenSources: () => ipcRenderer.invoke('screen:sources'),
  saveRecording: (buffer, region, fps) => ipcRenderer.invoke('rec:save', { buffer, region, fps }),

  // region overlay window
  regionOpen: () => ipcRenderer.invoke('region:open'),
  regionClose: () => ipcRenderer.invoke('region:close'),
  regionBounds: () => ipcRenderer.invoke('region:bounds'),
  regionSetRecording: (on) => ipcRenderer.invoke('region:setRecording', on),
});
