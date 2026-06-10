// Inspect a media file with ffprobe: dimensions, duration, frame rate, subtitles.
// Ports the four ffprobe calls in load() from the macOS app.
const { runTool } = require('./ffmpeg');
const { parsePackets } = require('./estimate');

async function probe(ffprobe, filePath) {
  const dims = await runTool(ffprobe, [
    '-v', 'error', '-select_streams', 'v:0',
    '-show_entries', 'stream=width,height', '-of', 'csv=p=0', filePath,
  ]);
  const durStr = await runTool(ffprobe, [
    '-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', filePath,
  ]);
  // avg_frame_rate is the REAL average; r_frame_rate is the timebase and can be bogus
  // (e.g. 1000 for variable-rate MediaRecorder webm). Prefer avg, fall back to r.
  const rate = (s) => {
    if (!s) return 0;
    const p = s.split('/');
    if (p.length === 2) { const n = parseFloat(p[0]); const d = parseFloat(p[1]); return d > 0 ? n / d : 0; }
    return parseFloat(s) || 0;
  };
  const avgStr = await runTool(ffprobe, [
    '-v', 'error', '-select_streams', 'v:0',
    '-show_entries', 'stream=avg_frame_rate', '-of', 'csv=p=0', filePath,
  ]);
  let fps = rate(avgStr);
  if (!(fps > 0)) {
    const rStr = await runTool(ffprobe, [
      '-v', 'error', '-select_streams', 'v:0',
      '-show_entries', 'stream=r_frame_rate', '-of', 'csv=p=0', filePath,
    ]);
    fps = rate(rStr);
  }

  // Any subtitle stream -> the clip carries captions.
  const subStr = await runTool(ffprobe, [
    '-v', 'error', '-select_streams', 's',
    '-show_entries', 'stream=index', '-of', 'csv=p=0', filePath,
  ]);

  const parts = dims.split(',');
  const w = parts.length > 0 ? parseInt(parts[0], 10) || 0 : 0;
  const h = parts.length > 1 ? parseInt(parts[1], 10) || 0 : 0;
  const duration = parseFloat(durStr) || 0;

  return { w, h, duration, fps, hasSubs: subStr.length > 0 };
}

// Per-second video byte histogram for the content-anchored size estimate. Demux only
// (no decode), so it's fast even for long files (~0.3s for a 5-minute recording).
// Returns { cum, total } — see estimate.parsePackets.
async function packetStats(ffprobe, filePath) {
  const csv = await runTool(ffprobe, [
    '-v', 'error', '-select_streams', 'v:0',
    '-show_entries', 'packet=pts_time,size', '-of', 'csv=p=0', filePath,
  ]);
  return parsePackets(csv);
}

module.exports = { probe, packetStats };
