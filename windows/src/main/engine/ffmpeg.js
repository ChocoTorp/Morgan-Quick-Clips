// Process runners for ffmpeg/ffprobe/whisper.
//
// Ports runTool() and runFFmpegProgress() from the macOS app. Like the original,
// every tool is launched with an ARGUMENT ARRAY (never a shell string), so file
// names and paths are passed as literal argv entries and shell injection is
// impossible. stderr is merged into stdout (the Swift app's "2>&1").
const { spawn } = require('child_process');
const { lastOutTime } = require('./util');

// Run a tool to completion; resolve with merged stdout+stderr (trimmed).
// Never rejects — a spawn error resolves to "" (matches the Swift behavior).
function runTool(exe, args, { env } = {}) {
  return new Promise((resolve) => {
    let child;
    try {
      child = spawn(exe, args, { env: env ? { ...process.env, ...env } : process.env });
    } catch {
      resolve('');
      return;
    }
    let out = '';
    child.stdout.on('data', (d) => (out += d.toString()));
    child.stderr.on('data', (d) => (out += d.toString()));
    child.on('error', () => resolve(''));
    child.on('close', () => resolve(out.trim()));
  });
}

// Run ffmpeg with `-progress pipe:1`, reporting 0..1 as it encodes.
// Resolves with { output, code, cancelled }. `onStart(child)` hands back the
// child process so the caller can terminate it (Cancel). `total` is the trimmed
// duration in seconds used to turn out_time into a fraction.
function runFFmpegProgress(ffmpeg, args, total, { onStart, onProgress } = {}) {
  return new Promise((resolve) => {
    let child;
    try {
      child = spawn(ffmpeg, args);
    } catch {
      resolve({ output: '', code: -1, cancelled: false });
      return;
    }
    if (onStart) onStart(child);
    let collected = '';
    const handle = (d) => {
      collected += d.toString();
      if (total > 0 && onProgress) {
        const t = lastOutTime(collected);
        if (t != null) onProgress(Math.min(1, Math.max(0, t / total)));
      }
    };
    child.stdout.on('data', handle);
    child.stderr.on('data', handle);
    child.on('error', () => resolve({ output: collected.trim(), code: -1, cancelled: false }));
    child.on('close', (code, signal) =>
      resolve({ output: collected.trim(), code, cancelled: signal != null })
    );
  });
}

module.exports = { runTool, runFFmpegProgress };
