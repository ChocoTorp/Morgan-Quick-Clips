// Electron main process — app shell + IPC bridge to the media engine, plus screen
// enumeration and the floating region-selector window used for region recording.
const { app, BrowserWindow, ipcMain, dialog, desktopCapturer, screen, session, shell } = require('electron');
const path = require('path');
const os = require('os');
const fs = require('fs');
const engine = require('./engine');

let tools = null;
let mainWin = null;
let regionWin = null;
let regionDragBounds = null; // window bounds captured at the start of a drag

// The app icon must be a REAL file on disk for the Windows taskbar/title bar to load it —
// a path inside app.asar is silently ignored and Windows falls back to the default icon.
// Packaged: shipped via extraResources to <resources>/icon.ico. Dev: build/icon.ico.
const ICON_PATH = app.isPackaged
  ? path.join(process.resourcesPath, 'icon.ico')
  : path.join(__dirname, '..', '..', 'build', 'icon.ico');

function createWindow() {
  mainWin = new BrowserWindow({
    width: 1000,
    height: 820,
    minWidth: 680,
    minHeight: 640,
    backgroundColor: '#1c1c1e',
    title: 'SimpleClips',
    icon: ICON_PATH,
    // Native title bar hidden; the renderer draws its own (icon + name + version) and
    // Windows overlays the min/max/close buttons on top of it.
    titleBarStyle: 'hidden',
    titleBarOverlay: { color: '#1c1c1e', symbolColor: '#e6e6e6', height: 34 },
    webPreferences: {
      preload: path.join(__dirname, '..', 'preload', 'index.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });
  mainWin.loadFile(path.join(__dirname, '..', 'renderer', 'index.html'));

  // Forward renderer errors/load failures to stdout (dev aid).
  mainWin.webContents.on('console-message', (_e, level, message, line, src) => {
    if (level >= 2) console.log(`[renderer] ${message} (${src}:${line})`);
  });
  mainWin.webContents.on('did-fail-load', (_e, code, desc) => console.log(`[load-fail] ${code} ${desc}`));
  mainWin.webContents.on('render-process-gone', (_e, d) => console.log(`[render-gone] ${JSON.stringify(d)}`));

  // SMOKE mode: drive the UI through a full load+export, print the result, then quit.
  if (process.env.SMOKE) {
    mainWin.webContents.on('did-finish-load', async () => {
      const SAMPLE = JSON.stringify(process.env.SMOKE_SAMPLE || '');
      const OUTDIR = JSON.stringify(process.env.SMOKE_OUT || '');
      try {
        const r = await mainWin.webContents.executeJavaScript(`(async () => {
          const T = window.__test;
          const t = await window.clips.toolsInfo();
          const srcCount = (await window.clips.screenSources()).length;
          await T.load(${SAMPLE});
          const a = {
            clips: !!window.clips, ffmpeg: !!t.ffmpeg, whisper: !!t.whisper, screens: srcCount,
            srcW: T.S.srcW, srcH: T.S.srcH, dur: Math.round(T.S.duration),
            est: document.getElementById('estBytes').textContent,
            slidersVisible: !document.getElementById('sliders').classList.contains('hidden'),
          };
          T.S.exportFolder = ${OUTDIR}; T.S.outName = 'uiclip'; T.S.outFormat = 'MP4';
          await T.doExport();
          a.status = document.getElementById('statusText').textContent;
          return a;
        })()`);
        console.log('SMOKE_RESULT ' + JSON.stringify(r));
      } catch (e) {
        console.log('SMOKE_ERROR ' + e.message);
      }
      setTimeout(() => app.quit(), 400);
    });
  }

  // Closing the main window must also tear down the floating region overlay — otherwise
  // it lingers on screen and keeps the app alive (window-all-closed never fires).
  mainWin.on('closed', () => {
    if (regionWin && !regionWin.isDestroyed()) regionWin.destroy();
    regionWin = null;
    mainWin = null;
  });
  return mainWin;
}

app.whenReady().then(() => {
  if (process.platform === 'win32') app.setAppUserModelId('com.morgan.simpleclips');
  tools = engine.resolveTools();

  // This is a trusted, fully-local app: grant the media permissions screen capture
  // and mic recording need, so getUserMedia(desktop)/MediaRecorder work first try.
  const ses = session.defaultSession;
  ses.setPermissionRequestHandler((_wc, _permission, cb) => cb(true));
  ses.setPermissionCheckHandler(() => true);
  // getDisplayMedia fallback: hand back the primary screen if the renderer ever uses it.
  if (ses.setDisplayMediaRequestHandler) {
    ses.setDisplayMediaRequestHandler((_req, cb) => {
      desktopCapturer.getSources({ types: ['screen'] }).then((sources) => {
        cb({ video: sources[0], audio: 'loopback' });
      });
    }, { useSystemPicker: false });
  }

  createWindow();
  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('before-quit', () => {
  if (regionWin && !regionWin.isDestroyed()) regionWin.destroy();
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});

// ---- IPC: info + dialogs ---------------------------------------------------

ipcMain.handle('tools:info', () => ({ ...tools, whisper: engine.whisperAvailable(tools) }));

ipcMain.handle('app:defaultFolder', () => app.getPath('desktop'));

// Patch-notes display version: semver 1.0.x → "1.0x" (V1.01, V1.02, ...).
ipcMain.handle('app:version', () => {
  const v = app.getVersion().split('.');
  return v.length === 3 && v[1] === '0' ? `${v[0]}.${String(v[2]).padStart(2, '0')}` : app.getVersion();
});

ipcMain.handle('shell:reveal', (_e, p) => { shell.showItemInFolder(path.normalize(p)); });

const VIDEO_EXTS = [
  'mp4', 'mov', 'm4v', 'gif', 'webm', 'mkv', 'avi', 'wmv', 'flv', 'ts', 'mts',
  'm2ts', 'mpg', 'mpeg', 'm2v', '3gp', '3g2', 'ogv', 'vob', 'asf', 'f4v', 'divx',
  'qt', 'mxf', 'dv', 'y4m',
];

ipcMain.handle('dialog:openFiles', async () => {
  const r = await dialog.showOpenDialog(mainWin, {
    properties: ['openFile', 'multiSelections'],
    filters: [{ name: 'Video', extensions: VIDEO_EXTS }, { name: 'All Files', extensions: ['*'] }],
  });
  return r.canceled ? [] : r.filePaths;
});

ipcMain.handle('dialog:chooseFolder', async (_e, current) => {
  const r = await dialog.showOpenDialog(mainWin, {
    properties: ['openDirectory', 'createDirectory'],
    defaultPath: current,
  });
  return r.canceled ? null : r.filePaths[0];
});

// Expand dropped paths: directories -> their video files; keep files as-is. Returns a
// flat, de-duped, natural-sorted list of accepted video paths.
ipcMain.handle('media:expandPaths', (_e, paths) => {
  const accepted = new Set(VIDEO_EXTS);
  const out = [];
  for (const p of paths) {
    let stat;
    try { stat = fs.statSync(p); } catch { continue; }
    if (stat.isDirectory()) {
      for (const name of fs.readdirSync(p)) {
        const ext = path.extname(name).slice(1).toLowerCase();
        if (accepted.has(ext)) out.push(path.join(p, name));
      }
    } else {
      const ext = path.extname(p).slice(1).toLowerCase();
      if (accepted.has(ext)) out.push(p);
    }
  }
  return [...new Set(out)].sort((a, b) =>
    path.basename(a).localeCompare(path.basename(b), undefined, { numeric: true })
  );
});

// ---- IPC: media engine -----------------------------------------------------

ipcMain.handle('media:probe', (_e, filePath) => engine.probe(tools.ffprobe, filePath));
ipcMain.handle('media:packets', (_e, filePath) => engine.packetStats(tools.ffprobe, filePath));
ipcMain.handle('media:proxy', (_e, filePath) => engine.makeProxy(tools, filePath));

// Scrub-proxy builds are best-effort background work: a newer clip's request kills the
// previous build so we never burn CPU on a clip the user already left.
let scrubChild = null;
ipcMain.handle('media:scrubProxy', async (_e, filePath) => {
  if (scrubChild) { try { scrubChild.kill(); } catch {} }
  const out = await engine.makeScrubProxy(tools, filePath, { onStart: (c) => { scrubChild = c; } });
  scrubChild = null;
  return out;
});
ipcMain.handle('media:fileSize', (_e, filePath) => engine.fileBytes(filePath));
ipcMain.handle('media:estimate', (_e, params) => engine.liveBytes(params.outFormat, params));
ipcMain.handle('media:hardEstimate', (_e, opts) => engine.hardEstimate({ ...opts, tools }));

// Currently-running ffmpeg child, so Cancel can terminate it.
let currentChild = null;
ipcMain.handle('media:cancel', () => {
  if (currentChild) { try { currentChild.kill(); } catch {} }
});

ipcMain.handle('media:export', async (_e, opts) => {
  const sender = _e.sender;
  const onProgress = (frac, which) => sender.send('media:progress', { id: opts.id, frac, which });
  const onStart = (child) => { currentChild = child; };
  const folder = opts.exportFolder;
  fs.mkdirSync(folder, { recursive: true });

  if (opts.format === 'Web') {
    const r = await engine.exportWeb({ ...opts, tools, onStart, onProgress, base: opts.base, exportFolder: folder });
    currentChild = null;
    return r;
  }

  // Collision-safe output name (clip, clip_1, ...), computed here where fs lives.
  const ext = engine.extFor(opts.format);
  const output = engine.uniqueOutputPath(folder, opts.base, ext);
  const outBase = path.basename(output, '.' + ext);

  let captions = null;
  if (opts.captions && (opts.captions.embed || opts.captions.srt || opts.captions.txt)) {
    captions = {
      ...opts.captions,
      onCaptions: (caps) => {
        if (opts.captions.srt && caps.srt) {
          try { fs.copyFileSync(caps.srt, engine.uniqueOutputPath(folder, outBase, 'srt')); } catch {}
        }
        if (opts.captions.txt && caps.txt) {
          try { fs.copyFileSync(caps.txt, engine.uniqueOutputPath(folder, outBase, 'txt')); } catch {}
        }
      },
    };
  }

  const r = await engine.exportClip({ ...opts, tools, output, captions, onStart, onProgress });
  currentChild = null;
  return r;
});

// ---- IPC: screen recording -------------------------------------------------

ipcMain.handle('screen:sources', async () => {
  const displays = screen.getAllDisplays();
  const sources = await desktopCapturer.getSources({ types: ['screen'], thumbnailSize: { width: 0, height: 0 } });
  // Pair each capturer source with its Electron display (for bounds/scale mapping).
  return sources.map((s, i) => {
    const disp = displays.find((d) => String(d.id) === String(s.display_id)) || displays[i] || displays[0];
    return {
      id: s.id,
      name: `Screen ${i}`,
      index: i,
      displayId: disp ? disp.id : null,
      bounds: disp ? disp.bounds : null,
      scaleFactor: disp ? disp.scaleFactor : 1,
      refreshRate: disp ? disp.displayFrequency || 0 : 0, // monitor refresh (Hz) → record fps (capped to 120 at record time)
    };
  });
});

// Save a recorded webm (ArrayBuffer), then run the ffmpeg "finish" pass: transcode the
// whole stream to a clean, seekable h264 mp4 (fixes the MediaRecorder no-duration "one
// frame" bug) and, for region recordings, crop to the selected rect in the same pass.
// Region rect is mapped proportionally (DIP fractions × recorded pixels), so DPI scaling
// doesn't matter. Returns the final mp4 path (or the raw webm if the finish pass failed).
ipcMain.handle('rec:save', async (e, { buffer, region, fps, duration, container, h264 }) => {
  const raw = path.join(os.tmpdir(), `screc_raw_${Date.now()}.${container || 'webm'}`);
  fs.writeFileSync(raw, Buffer.from(buffer));

  const info = await engine.probe(tools.ffprobe, raw); // dims only; duration is untrusted here
  let crop = null;
  if (region) {
    // The captured desktop video is at PHYSICAL pixels, so map the region's logical/DIP
    // rect to physical via the display scale factor. This makes the recorded resolution
    // exactly match the size the region overlay reported. Clamp to the captured frame.
    const db = region.displayBounds;
    const wb = region.winBounds;
    const sf = region.scaleFactor || 1;
    let x = Math.max(0, Math.round((wb.x - db.x) * sf));
    let y = Math.max(0, Math.round((wb.y - db.y) * sf));
    const w = Math.min(info.w - x, Math.round(wb.width * sf));
    const h = Math.min(info.h - y, Math.round(wb.height * sf));
    crop = { x, y, w, h };
  }

  const out = path.join(os.tmpdir(), `screc_${Date.now()}.mp4`);
  const ok = await engine.finishRecording({
    tools, input: raw, output: out, srcW: info.w, srcH: info.h, crop, fps, duration,
    h264: !!h264,
    onProgress: (frac) => e.sender.send('media:progress', { id: 'rec', frac }),
  });
  // Keep the raw webm when the finish pass fails — it's the only copy of the recording
  // (and Chromium can still play it), so deleting it would lose the user's clip.
  if (!ok) return raw;
  try { fs.unlinkSync(raw); } catch {}
  return out;
});

// ---- IPC: region overlay window --------------------------------------------

function makeRegionWindow() {
  const win = new BrowserWindow({
    width: 640, height: 360, x: 320, y: 240,
    frame: false, transparent: true, resizable: true, movable: true,
    alwaysOnTop: true, skipTaskbar: true, hasShadow: false, fullscreenable: false,
    webPreferences: {
      preload: path.join(__dirname, '..', 'preload', 'region.js'),
      contextIsolation: true,
    },
  });
  win.setAlwaysOnTop(true, 'screen-saver');
  win.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
  // Exclude the overlay from ALL screen capture (Win10 2004+ / Win11): the blue outline
  // stays visible to the user but never appears in the recording.
  win.setContentProtection(true);
  win.loadFile(path.join(__dirname, '..', 'renderer', 'region.html'));
  // Start click-through (transparent middle passes clicks); the renderer re-enables
  // mouse capture only while hovering the label/grips (forward:true delivers the moves).
  win.setIgnoreMouseEvents(true, { forward: true });
  return win;
}

ipcMain.handle('region:open', () => {
  if (!regionWin || regionWin.isDestroyed()) regionWin = makeRegionWindow();
  regionWin.showInactive();
  // Re-apply after showing — content protection can drop across hide/show on Windows.
  regionWin.setContentProtection(true);
  regionWin.setIgnoreMouseEvents(true, { forward: true });
  return true;
});

// Renderer toggles capture on/off as the pointer enters/leaves the label/grips.
ipcMain.on('region:setIgnore', (_e, ignore) => {
  if (regionWin && !regionWin.isDestroyed()) regionWin.setIgnoreMouseEvents(!!ignore, { forward: true });
});

ipcMain.handle('region:close', () => {
  if (regionWin && !regionWin.isDestroyed()) regionWin.hide();
  return true;
});

// Current overlay bounds mapped to the display it mostly overlaps.
ipcMain.handle('region:bounds', () => {
  if (!regionWin || regionWin.isDestroyed()) return null;
  const wb = regionWin.getBounds();
  const disp = screen.getDisplayMatching(wb);
  return {
    winBounds: wb, displayBounds: disp.bounds, displayId: disp.id,
    scaleFactor: disp.scaleFactor, refreshRate: disp.displayFrequency || 0,
  };
});

// During recording: thin outline + fully click-through (the renderer stops toggling
// capture so nothing in the overlay intercepts clicks).
ipcMain.handle('region:setRecording', (_e, on) => {
  if (!regionWin || regionWin.isDestroyed()) return;
  regionWin.setContentProtection(true); // ensure it's still excluded from capture
  regionWin.setIgnoreMouseEvents(true, { forward: true });
  regionWin.webContents.send('region:recording', !!on);
});

// Absolute drag: capture bounds at start, then apply the TOTAL mouse delta each move.
ipcMain.on('region:dragStart', () => {
  if (regionWin && !regionWin.isDestroyed()) regionDragBounds = regionWin.getBounds();
});
ipcMain.on('region:dragEnd', () => { regionDragBounds = null; });
ipcMain.on('region:dragMove', (_e, { kind, dx = 0, dy = 0 }) => {
  if (!regionWin || regionWin.isDestroyed() || !regionDragBounds) return;
  const s = regionDragBounds;
  let x = s.x, y = s.y, width = s.width, height = s.height;
  if (kind === 'move') {
    x = s.x + dx; y = s.y + dy; // size unchanged → a move can never grow the box
  } else {
    if (kind === 'br') { width = s.width + dx; height = s.height + dy; }
    else if (kind === 'tr') { y = s.y + dy; width = s.width + dx; height = s.height - dy; }
    else if (kind === 'bl') { x = s.x + dx; width = s.width - dx; height = s.height + dy; }
    else if (kind === 'tl') { x = s.x + dx; y = s.y + dy; width = s.width - dx; height = s.height - dy; }
    const MINW = 80, MINH = 60;
    if (width < MINW) { if (kind === 'tl' || kind === 'bl') x = s.x + (s.width - MINW); width = MINW; }
    if (height < MINH) { if (kind === 'tl' || kind === 'tr') y = s.y + (s.height - MINH); height = MINH; }
  }
  regionWin.setBounds({ x: Math.round(x), y: Math.round(y), width: Math.round(width), height: Math.round(height) });
});

module.exports = { createWindow };
