// Build the Windows icon set from a source image (PNG or macOS .icns).
// Writes build/icon.png + build/icon.ico (multi-resolution).
//   node scripts/make-icon.mjs [sourceImage]
// Default source: build/icon-source.png, else build/AppIcon.icns.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import png2icons from 'png2icons';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const outDir = path.join(root, 'build');
const PNG_SIG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

function pickSource() {
  if (process.argv[2]) return process.argv[2];
  const png = path.join(outDir, 'icon-source.png');
  if (fs.existsSync(png)) return png;
  return path.join(outDir, 'AppIcon.icns');
}

// Return the base PNG buffer from either a PNG file or an .icns container.
function basePng(src) {
  const buf = fs.readFileSync(src);
  if (buf.subarray(0, 8).equals(PNG_SIG)) return buf; // already a PNG
  if (buf.toString('ascii', 0, 4) === 'icns') {
    let off = 8, best = null;
    while (off + 8 <= buf.length) {
      const len = buf.readUInt32BE(off + 4);
      if (len < 8 || off + len > buf.length) break;
      const data = buf.subarray(off + 8, off + len);
      if (data.length >= 8 && data.subarray(0, 8).equals(PNG_SIG) && (!best || data.length > best.length)) best = data;
      off += len;
    }
    if (best) return best;
    throw new Error('no PNG image found inside ' + src);
  }
  throw new Error('unsupported icon source (need PNG or icns): ' + src);
}

const src = pickSource();
const png = basePng(src);
fs.mkdirSync(outDir, { recursive: true });
fs.writeFileSync(path.join(outDir, 'icon.png'), png);
const ico = png2icons.createICO(png, png2icons.BICUBIC, 0, false);
fs.writeFileSync(path.join(outDir, 'icon.ico'), ico);
console.log(`source ${path.basename(src)} -> icon.png ${png.length}B, icon.ico ${ico.length}B`);
