// Self-check: node test.js  — builds a fake disk image and asserts every planted photo is carved byte-exact.
const assert = require('assert'), fs = require('fs'), path = require('path'), crypto = require('crypto');
const { carve } = require('./carve.js');

// Minimal JPEG with an embedded EXIF-style thumbnail (FFD8..FFD9 inside APP1), stuffed FF00 and an RST marker.
const thumb = [0xFF, 0xD8, 0xFF, 0xD9];
const app1 = [0xFF, 0xE1, 0x00, 2 + thumb.length, ...thumb];
const sos = [0xFF, 0xDA, 0x00, 0x08, 1, 1, 0, 0, 63, 0];
const synthJpeg = Buffer.from([0xFF, 0xD8, ...app1, ...sos, 0x12, 0xFF, 0x00, 0x34, 0xFF, 0xD0, 0x56, 0xFF, 0xD9]);

const real = ['C:/Windows/Web/Wallpaper/Windows/img0.jpg', 'C:/Windows/Web/Screen/img100.jpg']
  .filter(p => fs.existsSync(p)).map(p => fs.readFileSync(p));
const pngDir = 'C:/Windows/ImmersiveControlPanel/images';
if (fs.existsSync(pngDir)) real.push(...fs.readdirSync(pngDir).filter(f => f.endsWith('.png')).slice(0, 2).map(f => fs.readFileSync(path.join(pngDir, f))));

const photos = [synthJpeg, ...real];
const parts = [], expected = [];
const pad = () => { const len = parts.reduce((a, b) => a + b.length, 0); parts.push(Buffer.alloc((512 - len % 512) % 512)); };
parts.push(crypto.randomBytes(3000)); pad();
parts.push(Buffer.from([0xFF, 0xD8, 0xFF, 0x00, 0x01])); parts.push(crypto.randomBytes(2000)); pad();  // bogus header
for (const p of photos) {
  expected.push({ start: parts.reduce((a, b) => a + b.length, 0), data: p });
  parts.push(p, crypto.randomBytes(1500)); pad();
}
const img = Buffer.concat(parts);

(async () => {
  const read = async (o, n) => img.subarray(o, o + n);
  const got = [];
  for await (const f of carve(read, img.length)) got.push(f);
  assert.strictEqual(got.length, expected.length, `found ${got.length}, expected ${expected.length}`);
  got.forEach((f, i) => {
    assert.strictEqual(f.start, expected[i].start);
    assert.ok(img.subarray(f.start, f.end).equals(expected[i].data), `file ${i} bytes differ`);
  });
  console.log(`OK: carved ${got.length} photos (${real.length} real Windows images + 1 synthetic) byte-exact`);
})().catch(e => { console.error(e); process.exit(1); });
