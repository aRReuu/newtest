import test from "node:test";
import assert from "node:assert/strict";
import { deflateSync } from "node:zlib";
import { inlineExcalidrawBitmap as project } from "./inline-excalidraw-image.mjs";

// Public source contains no prebuilt or base64-embedded image fixtures.
// Build a minimal PNG in memory solely when this test executes.
function crc32(bytes) {
  let crc = 0xffffffff;
  for (const byte of bytes) {
    crc ^= byte;
    for (let b = 0; b < 8; b += 1) {
      crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
    }
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function chunk(type, payload) {
  const data = Buffer.from(type, "ascii");
  const size = Buffer.alloc(4);
  size.writeUInt32BE(payload.length);
  const checksum = Buffer.alloc(4);
  checksum.writeUInt32BE(crc32(Buffer.concat([data, payload])));
  return Buffer.concat([size, data, payload, checksum]);
}

function singlePixelPng() {
  const signature = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
  const header = Buffer.alloc(13);
  header.writeUInt32BE(1, 0);
  header.writeUInt32BE(1, 4);
  header[8] = 8; // 8-bit channels
  header[9] = 6; // RGBA
  const row = Buffer.from([0, 255, 0, 0, 255]); // filter + one red pixel
  return Buffer.concat([
    signature,
    chunk("IHDR", header),
    chunk("IDAT", deflateSync(row)),
    chunk("IEND", Buffer.alloc(0))
  ]);
}

const png = "data:image/png;base64," + singlePixelPng().toString("base64");
const elem = { type: "image", fileId: "selected" };
const probe = (url, mimeType) =>
  project(elem, { selected: { dataURL: url, mimeType } });

test("generated in-memory PNG preserves actual dimensions and bytes", () => {
  assert.deepEqual(probe(png, "image/png"), { href: png, width: 1, height: 1 });
});

test("remote links, SVG, HTML, source mismatch and missing files fail closed", () => {
  for (const input of [
    "https://example.org/a.png",
    "file:///private/img.png",
    "data:image/svg+xml;base64,AAAA",
    "data:text/html;base64,AAAA",
    "data:image/png;base64,!!",
    png + "X"
  ]) {
    assert.equal(probe(input), null);
  }
  assert.equal(probe(png, "image/jpeg"), null);
  assert.equal(project({ type: "rectangle", fileId: "selected" },
    { selected: { dataURL: png } }), null);
  assert.equal(project({ type: "image", fileId: "absent" },
    { selected: { dataURL: png } }), null);
  assert.equal(project(elem, Object.create({ selected: { dataURL: png } })), null);
});

test("pixel bombs, oversized encoded input and corrupt JPEG are rejected", () => {
  const buffer = Buffer.from(png.split(",")[1], "base64");
  buffer.writeUInt32BE(9000, 16);
  assert.equal(probe("data:image/png;base64," + buffer.toString("base64")), null);
  buffer.writeUInt32BE(4000, 16);
  buffer.writeUInt32BE(4000, 20);
  assert.equal(probe("data:image/png;base64," + buffer.toString("base64")), null);
  assert.equal(probe("data:image/png;base64," + "AAAA".repeat(170000)), null);
  assert.equal(probe("data:image/jpeg;base64," + Buffer.from("bad").toString("base64")), null);
});
