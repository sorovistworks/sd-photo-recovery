// Signature carving: find JPEG/PNG headers at sector boundaries, walk the format to its real end.
// shortcut: assumes each file is stored contiguously (no fragment reassembly), which holds for most camera SD cards.
const SECTOR = 512, CHUNK = 8 << 20, MAX_FILE = 64 << 20;
const PNG_SIG = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

// Each *End returns: >0 end offset in b, -1 need more bytes, 0 not a valid file.
function jpegEnd(b) {
  if (b[0] !== 0xFF || b[1] !== 0xD8 || b[2] !== 0xFF) return 0;
  let i = 2;
  for (;;) {
    if (i + 4 > b.length) return -1;
    if (b[i] !== 0xFF) return 0;
    const m = b[i + 1];
    if (m === 0xFF) { i++; continue; }                       // fill byte
    if (m === 0xD9) return i + 2;                            // EOI
    if ((m >= 0xD0 && m <= 0xD7) || m === 0x01) { i += 2; continue; }
    const len = (b[i + 2] << 8) | b[i + 3];
    if (len < 2) return 0;
    i += 2 + len;                                            // skips APP1, so EXIF thumbnails aren't mistaken for the end
    if (m === 0xDA) {                                        // scan data runs until a real marker (not FF00 / RSTn)
      for (;;) {
        if (i + 1 >= b.length) return -1;
        const n = b[i + 1];
        if (b[i] === 0xFF && n !== 0 && !(n >= 0xD0 && n <= 0xD7)) break;
        i++;
      }
    }
  }
}

function pngEnd(b) {
  for (let k = 0; k < 8; k++) if (b[k] !== PNG_SIG[k]) return 0;
  let i = 8;
  for (;;) {
    if (i + 12 > b.length) return -1;
    const len = ((b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3]) >>> 0;
    for (let k = 4; k < 8; k++) { const c = b[i + k] | 0x20; if (c < 0x61 || c > 0x7A) return 0; }
    const iend = b[i + 4] === 0x49 && b[i + 5] === 0x45 && b[i + 6] === 0x4E && b[i + 7] === 0x44;
    i += 12 + len;
    if (iend) return i <= b.length ? i : -1;
  }
}

function sniff(b, o) {
  if (o + 8 > b.length) return null;
  if (b[o] === 0xFF && b[o + 1] === 0xD8 && b[o + 2] === 0xFF) return { ext: 'jpg', type: 'image/jpeg', end: jpegEnd };
  if (b[o] === 0x89 && b[o + 1] === 0x50 && b[o + 2] === 0x4E && b[o + 3] === 0x47) return { ext: 'png', type: 'image/png', end: pngEnd };
  return null;
}

async function findEnd(read, size, start, end) {
  for (let win = 1 << 20; ; win *= 4) {
    const n = Math.min(win, MAX_FILE, size - start);
    const r = end(await read(start, n));
    if (r > 0) return start + r;
    if (r === 0 || n === MAX_FILE || n === size - start) return 0;  // invalid, too big, or truncated by end of image
  }
}

// read(offset, length) -> Promise<Uint8Array>. Yields {start, end, ext, type}.
async function* carve(read, size, onProgress = () => {}) {
  let pos = 0;
  while (pos < size) {
    const buf = await read(pos, Math.min(CHUNK, size - pos));
    let next = pos + buf.length;
    for (let off = 0; off < buf.length; off += SECTOR) {
      const kind = sniff(buf, off);
      if (!kind) continue;
      const start = pos + off, end = await findEnd(read, size, start, kind.end);
      if (!end) continue;
      yield { start, end, ext: kind.ext, type: kind.type };
      next = Math.ceil(end / SECTOR) * SECTOR;
      break;
    }
    pos = next;
    onProgress(Math.min(pos, size), size);
  }
}

if (typeof module !== 'undefined') module.exports = { carve };
