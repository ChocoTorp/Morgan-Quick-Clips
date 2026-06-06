// Pure-logic unit checks for the ported engine. No ffmpeg required — these verify
// that plan()/util/estimate match the macOS app's behavior exactly.
const assert = require('assert');
const { plan, splitArgs } = require('../src/main/engine/plan');
const { humanSize, mmss, etaString, extFor, qLabel, lastOutTime, evenInt } = require('../src/main/engine/util');
const { liveBytes, estSig } = require('../src/main/engine/estimate');

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

console.log('\n' + passed + ' checks passed.');
