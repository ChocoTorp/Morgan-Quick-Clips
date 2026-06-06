// Fetch the bundled captions assets (git-ignored, so re-fetchable for a build):
//   - whisper.cpp Windows binaries -> resources/win/bin/
//   - ggml base.en model           -> models/ggml-base.en.bin
// Run: node scripts/fetch-whisper.mjs   (skips anything already present)
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import { Readable } from 'node:stream';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const WHISPER_VERSION = 'v1.8.6';
const WHISPER_ZIP = `https://github.com/ggml-org/whisper.cpp/releases/download/${WHISPER_VERSION}/whisper-bin-x64.zip`;
const MODEL_URL = 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin';

const binDir = path.join(root, 'resources', 'win', 'bin');
const modelsDir = path.join(root, 'models');
// whisper-cli.exe + its runtime DLLs (ggml-base.dll triggers GGML_BACKEND_PATH discovery).
const NEEDED = ['whisper-cli.exe', 'ggml-base.dll', 'ggml-cpu.dll', 'ggml.dll', 'whisper.dll'];

async function download(url, dest) {
  const r = await fetch(url);
  if (!r.ok) throw new Error(`${r.status} ${r.statusText} for ${url}`);
  await fs.promises.mkdir(path.dirname(dest), { recursive: true });
  const out = fs.createWriteStream(dest);
  await new Promise((res, rej) => {
    Readable.fromWeb(r.body).pipe(out).on('finish', res).on('error', rej);
  });
}

function unzip(zip, dir) {
  if (process.platform === 'win32') {
    execFileSync('powershell', ['-NoProfile', '-Command',
      `Expand-Archive -Path '${zip}' -DestinationPath '${dir}' -Force`], { stdio: 'inherit' });
  } else {
    execFileSync('unzip', ['-o', zip, '-d', dir], { stdio: 'inherit' });
  }
}

async function main() {
  fs.mkdirSync(binDir, { recursive: true });
  fs.mkdirSync(modelsDir, { recursive: true });

  const haveBins = NEEDED.every((f) => fs.existsSync(path.join(binDir, f)));
  if (haveBins) {
    console.log('whisper binaries already present, skipping');
  } else {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'whisper-'));
    const zip = path.join(tmp, 'whisper.zip');
    console.log('downloading whisper binaries...');
    await download(WHISPER_ZIP, zip);
    unzip(zip, tmp);
    // The zip lays files out under Release/ (or similar) — find each needed file.
    const find = (name) => {
      const stack = [tmp];
      while (stack.length) {
        const d = stack.pop();
        for (const e of fs.readdirSync(d, { withFileTypes: true })) {
          const p = path.join(d, e.name);
          if (e.isDirectory()) stack.push(p);
          else if (e.name.toLowerCase() === name.toLowerCase()) return p;
        }
      }
      return null;
    };
    for (const f of NEEDED) {
      const src = find(f);
      if (!src) throw new Error('missing in whisper zip: ' + f);
      fs.copyFileSync(src, path.join(binDir, f));
    }
    fs.rmSync(tmp, { recursive: true, force: true });
    console.log('whisper binaries -> ' + binDir);
  }

  const model = path.join(modelsDir, 'ggml-base.en.bin');
  if (fs.existsSync(model)) {
    console.log('model already present, skipping');
  } else {
    console.log('downloading ggml-base.en.bin (~142MB)...');
    await download(MODEL_URL, model);
    console.log('model -> ' + model);
  }
  console.log('done');
}

main().catch((e) => { console.error(e); process.exit(1); });
