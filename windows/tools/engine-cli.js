// Headless driver for the media engine — verify probe/export/estimate against a
// real file without any UI. Uses ffmpeg/ffprobe from PATH (dev mode).
//
//   node tools/engine-cli.js probe   <file>
//   node tools/engine-cli.js export  <in> <out> [--format MP4] [--q 0.5] [--fps N]
//   node tools/engine-cli.js estimate <in> [--format MP4] [--q 0.5]
const path = require('path');
const engine = require('../src/main/engine');

function parseFlags(argv) {
  const flags = {};
  const pos = [];
  for (let i = 0; i < argv.length; i++) {
    if (argv[i].startsWith('--')) flags[argv[i].slice(2)] = argv[++i];
    else pos.push(argv[i]);
  }
  return { flags, pos };
}

function bar(frac) {
  const n = Math.round(frac * 30);
  return '[' + '#'.repeat(n) + '-'.repeat(30 - n) + '] ' + Math.round(frac * 100) + '%';
}

async function main() {
  const tools = engine.resolveTools();
  const [cmd, ...rest] = process.argv.slice(2);
  const { flags, pos } = parseFlags(rest);

  if (cmd === 'probe') {
    const info = await engine.probe(tools.ffprobe, path.resolve(pos[0]));
    console.log(JSON.stringify(info, null, 2));
    return;
  }

  if (cmd === 'estimate') {
    const input = path.resolve(pos[0]);
    const info = await engine.probe(tools.ffprobe, input);
    const params = {
      outFormat: flags.format || 'MP4',
      quality: flags.q != null ? Number(flags.q) : 0.5,
      outW: info.w, outH: info.h, srcFps: info.fps, fpsOverride: null,
      trimStart: 0, trimEnd: info.duration, capBurn: false,
    };
    const live = engine.liveBytes(params.outFormat, params);
    console.log('live estimate: ' + engine.humanSize(live) + ' (' + engine.qLabel(params.quality) + ')');
    process.stdout.write('measuring (harder estimate)… ');
    const hard = await engine.hardEstimate({
      tools, input, format: params.outFormat, quality: params.quality, fps: null,
      srcW: info.w, srcH: info.h, crop: null, outW: info.w, outH: info.h,
      trim: { start: 0, end: info.duration },
    });
    console.log(engine.humanSize(hard));
    return;
  }

  if (cmd === 'export') {
    const input = path.resolve(pos[0]);
    const output = path.resolve(pos[1]);
    const info = await engine.probe(tools.ffprobe, input);
    console.log(`source: ${info.w}x${info.h} ${info.duration.toFixed(2)}s ${info.fps.toFixed(2)}fps`);
    const t0 = Date.now();
    let last = '';
    const res = await engine.exportClip({
      tools, input, output,
      format: flags.format || 'MP4',
      quality: flags.q != null ? Number(flags.q) : 0.5,
      fps: flags.fps != null ? Number(flags.fps) : null,
      srcW: info.w, srcH: info.h, crop: null, outW: info.w, outH: info.h,
      trim: { start: 0, end: info.duration },
      onProgress: (frac) => {
        const line = bar(frac);
        if (line !== last) { process.stdout.write('\r' + line); last = line; }
      },
    });
    process.stdout.write('\n');
    if (res.ok) {
      console.log(`OK  ${output}  (${engine.humanSize(engine.fileBytes(output))}, ${((Date.now() - t0) / 1000).toFixed(1)}s)`);
    } else {
      console.log('FAILED: ' + (res.cancelled ? 'cancelled' : res.error));
      process.exit(1);
    }
    return;
  }

  console.log('usage: probe <file> | export <in> <out> [--format] [--q] [--fps] | estimate <in> [--format] [--q]');
  process.exit(1);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
