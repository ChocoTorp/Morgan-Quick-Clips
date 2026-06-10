// Pure-logic unit checks for the ported engine. No ffmpeg required — these verify
// that plan()/util/estimate match the macOS app's behavior exactly.
const assert = require('assert');
const { plan, splitArgs } = require('../src/main/engine/plan');
const { humanSize, mmss, etaString, extFor, qLabel, lastOutTime, evenInt } = require('../src/main/engine/util');
const { liveBytes, anchoredBytes, parsePackets, rangeBytes, estSig } = require('../src/main/engine/estimate');

let passed = 0;
function check(name, fn) {
  fn();
  passed++;
  console.log('  ok  ' + name);
}

console.log('plan():');
check('MP4 @ q=0.5 balanced', () => {
  const p = plan('MP4', 0.5, 'crop=100:100:0:0', null);
  assert.strictEqual(p.vf, 'crop=100:100:0:0');
  assert.strictEqual(
    p.codec,
    '-c:v libx264 -crf 22 -preset medium -pix_fmt yuv420p -c:a aac -b:a 176k -movflags +faststart'
  );
});
check('GIF @ q=0.5', () => {
  const p = plan('GIF', 0.5, 'crop=100:100:0:0', null);
  assert.strictEqual(
    p.vf,
    'crop=100:100:0:0,fps=16,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer'
  );
  assert.strictEqual(p.codec, '');
});
check('WEBM @ q=0 with fps override', () => {
  const p = plan('WEBM', 0.0, 'crop=10:10:0:0', 30);
  assert.strictEqual(
    p.codec,
    '-c:v libvpx-vp9 -crf 18 -b:v 0 -row-mt 1 -pix_fmt yuv420p -r 30 -c:a libopus -b:a 192k'
  );
});
check('3GP gets baseline profile', () => {
  const p = plan('3GP', 1.0, 'crop=8:8:0:0', null);
  assert.ok(p.codec.includes('-profile:v baseline -level 3.1'));
  assert.ok(!p.codec.includes('+faststart'));
});
check('splitArgs drops empties', () => {
  assert.deepStrictEqual(splitArgs('  -c:v   libx264  -crf 22 '), ['-c:v', 'libx264', '-crf', '22']);
  assert.deepStrictEqual(splitArgs(''), []);
});

console.log('util:');
check('humanSize', () => {
  assert.strictEqual(humanSize(1048576), '1.0 MB');
  assert.strictEqual(humanSize(1024), '1 KB');
});
check('mmss', () => assert.strictEqual(mmss(65), '1:05'));
check('etaString', () => {
  assert.strictEqual(etaString(12), '~12s left');
  assert.strictEqual(etaString(65), '~1m 05s left');
  assert.strictEqual(etaString(0), '');
});
check('extFor', () => {
  assert.strictEqual(extFor('WEBM'), 'webm');
  assert.strictEqual(extFor('MP4'), 'mp4');
  assert.strictEqual(extFor('anything-else'), 'mp4');
});
check('qLabel', () => {
  assert.strictEqual(qLabel(0.1), 'high fidelity');
  assert.strictEqual(qLabel(0.5), 'balanced');
  assert.strictEqual(qLabel(0.9), 'high optimization');
});
check('lastOutTime parses streamed progress', () => {
  const stream = 'frame=10\nout_time=00:00:01.500000\nspeed=1x\nout_time=00:00:03.250000\n';
  assert.strictEqual(lastOutTime(stream), 3.25);
  assert.strictEqual(lastOutTime('no time here'), null);
});
check('evenInt', () => {
  assert.strictEqual(evenInt(101), 100);
  assert.strictEqual(evenInt(1), 2);
});

console.log('estimate:');
check('liveBytes positive + Web = webm + gif', () => {
  const p = { outFormat: 'WEBM', quality: 0.5, outW: 640, outH: 480, srcFps: 30, fpsOverride: null, trimStart: 0, trimEnd: 5, capBurn: false };
  assert.ok(liveBytes('WEBM', p) > 0);
  const web = liveBytes('Web', p);
  assert.strictEqual(web, liveBytes('WEBM', p) + liveBytes('GIF', p));
});
check('estSig is stable + setting-sensitive', () => {
  const base = { outFormat: 'MP4', quality: 0.5, outW: 640, outH: 480, fpsOverride: null, trimStart: 0, trimEnd: 5, capBurn: false };
  assert.strictEqual(estSig(base), estSig({ ...base }));
  assert.notStrictEqual(estSig(base), estSig({ ...base, quality: 0.6 }));
});
check('parsePackets buckets into cumulative seconds', () => {
  const r = parsePackets('0.10,100\n0.90,100\n1.50,50\nN/A,10\n');
  assert.strictEqual(r.total, 260);
  assert.deepStrictEqual(r.cum, [0, 200, 260]); // N/A joins the last seen bucket
});
check('rangeBytes interpolates within buckets', () => {
  const cum = [0, 100, 300];
  assert.strictEqual(rangeBytes(cum, 0, 2), 300);
  assert.strictEqual(rangeBytes(cum, 0.5, 1), 50);
  assert.strictEqual(rangeBytes(cum, 1, 1.5), 100);
});
check('anchoredBytes: identity at source settings, null fallbacks', () => {
  // 10s of uniform 1000 B/s source; output = source size/fps and outCrf(0.375) = srcCrf 20
  const cum = Array.from({ length: 11 }, (_, i) => i * 1000);
  const anchor = { cum, total: 10000, srcW: 100, srcH: 100, srcCrf: 20 };
  const p = { quality: 0.375, outW: 100, outH: 100, srcFps: 30, fpsOverride: null, trimStart: 0, trimEnd: 10 };
  const audio = ((256 - 0.375 * 160) * 1000 * 10) / 8;
  assert.ok(Math.abs(anchoredBytes('MP4', p, anchor) - (10000 + audio)) < 1e-6);
  assert.strictEqual(anchoredBytes('MP4', p, null), null); // no anchor yet
  assert.strictEqual(anchoredBytes('GIF', p, anchor), null); // palette-driven → model
  // halving the trim halves the video part (audio scales with duration too)
  const half = anchoredBytes('MP4', { ...p, trimEnd: 5 }, anchor);
  assert.ok(Math.abs(half - (5000 + audio / 2)) < 1e-6);
  // Web = anchored WEBM + modelled GIF
  const web = anchoredBytes('Web', p, anchor);
  assert.strictEqual(web, anchoredBytes('WEBM', p, anchor) + liveBytes('GIF', p));
});
check('anchoredBytes: +6 equivalent CRF halves the video bytes', () => {
  const cum = Array.from({ length: 11 }, (_, i) => i * 1000);
  const anchor = { cum, total: 10000, srcW: 100, srcH: 100, srcCrf: 20 };
  const p = { outW: 100, outH: 100, srcFps: 30, fpsOverride: null, trimStart: 0, trimEnd: 10 };
  const vid = (q) => anchoredBytes('MP4', { ...p, quality: q }, anchor) - ((256 - q * 160) * 1000 * 10) / 8;
  assert.ok(Math.abs(vid(0.75) / vid(0.375) - 0.5) < 1e-9); // crf 26 vs 20
});

console.log('\n' + passed + ' checks passed.');
