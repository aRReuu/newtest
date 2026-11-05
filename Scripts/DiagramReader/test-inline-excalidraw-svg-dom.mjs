// Actual production DOM renderer test, rather than geometry-helper-only probes.
// The four transformed source elements are from Excalidraw's upstream SVG
// export.test.tsx / svg-image-exporting-reference.svg @14bb42ed.
// This proves inline SVG DOM semantics and safety, NOT full pixel-level A/B.
import test from "node:test";
import assert from "node:assert/strict";
import { deflateSync } from "node:zlib";
import { inlineExcalidrawResourceBudget } from "./inline-excalidraw-resource-budget.mjs";

class OfflineNode {
  constructor(tag) { this.tag = tag; this.attrs = {}; this.children = []; }
  setAttribute(name, value) { this.attrs[name] = String(value); }
  append(...nodes) { this.children.push(...nodes); }
  replaceChildren(...nodes) { this.children = [...nodes]; }
}
globalThis.document = {
  getElementById: (id) => new OfflineNode(id),
  createElementNS: (_namespace, tag) => new OfflineNode(tag),
  createElement: (tag) => new OfflineNode(tag)
};
globalThis.window = {};
const { drawNativeGeometry } = await import("./markdown-host.js");
const walk = node => [node, ...node.children.flatMap(walk)];
const packed = data => Buffer.from(JSON.stringify(data), "utf8").toString("base64");
const close = (actual, expected, tolerance = 0.00001) =>
  assert.ok(Math.abs(Number(actual) - expected) <= tolerance,
    "expected " + expected + ", got " + actual);

// A real, offline 318×335 PNG, the dimensions of the upstream affine fixture.
// Quadrant pixels make a future screenshot comparison detect incorrect flips.
function pngFixture() {
  const width = 318, height = 335, row = width * 4 + 1;
  const bytes = Buffer.alloc(row * height);
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const offset = y * row + 1 + x * 4;
      bytes[offset] = x < width / 2 ? 225 : 35;
      bytes[offset + 1] = y < height / 2 ? 55 : 205;
      bytes[offset + 2] = 90;
      bytes[offset + 3] = 255;
    }
  }
  const crc = input => {
    let c = 0xffffffff;
    for (const byte of input) {
      c ^= byte;
      for (let i = 0; i < 8; i++)
        c = (c >>> 1) ^ ((c & 1) ? 0xedb88320 : 0);
    }
    return (c ^ 0xffffffff) >>> 0;
  };
  const chunk = (name, payload) => {
    const type = Buffer.from(name);
    const size = Buffer.alloc(4), checksum = Buffer.alloc(4);
    size.writeUInt32BE(payload.length);
    checksum.writeUInt32BE(crc(Buffer.concat([type, payload])));
    return Buffer.concat([size, type, payload, checksum]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8; ihdr[9] = 6;
  return "data:image/png;base64," + Buffer.concat([
    Buffer.from("89504e470d0a1a0a", "hex"),
    chunk("IHDR", ihdr),
    chunk("IDAT", deflateSync(bytes, { level: 9 })),
    chunk("IEND", Buffer.alloc(0))
  ]).toString("base64");
}

test("upstream four-image SVG affine fixture survives the real offline DOM painter", () => {
  const input = [
    [0, 0, 100, 100, 315, 1, 1],
    [100, 0, 50, 50, 45, -1, 1],
    [0, 100, 100, 100, 45, 1, -1],
    [100, 100, 50, 50, 315, -1, -1]
  ];
  const elements = input.map(([x,y,width,height,degrees,flipX,flipY], index) => ({
    id:"upstream-image-" + index, type:"image", fileId:"same-image",
    x,y,width,height,angle:degrees*Math.PI/180,scale:[flipX,flipY]
  }));
  const host = new OfflineNode("host");
  const budget = inlineExcalidrawResourceBudget();
  drawNativeGeometry(host, packed({
    elements, files:{"same-image":{dataURL:pngFixture(),mimeType:"image/png"}}
  }), "impress-excalidraw", budget);
  const svg = host.children[0];
  assert.equal(svg.tag, "svg");
  const viewBox = svg.attrs.viewBox.split(" ").map(Number);
  assert.deepEqual(viewBox.slice(0,2), [0,0]);
  close(viewBox[2], 245.06601717798213);
  close(viewBox[3], 305.4213562373095);
  const groups = svg.children.filter(node => node.tag === "g");
  assert.equal(groups.length, 4);
  const images = walk(svg).filter(node => node.tag === "image");
  assert.equal(images.length, 4);
  const expectedFlips = [
    "translate(0 0) scale(1 1)",
    "translate(50 0) scale(-1 1)",
    "translate(0 100) scale(1 -1)",
    "translate(50 50) scale(-1 -1)"
  ];
  for (let i = 0; i < 4; i++) {
    const group = groups[i];
    const transform = group.attrs.transform.match(/^rotate\(([-\d.]+) ([-\d.]+) ([-\d.]+)\)$/);
    assert.ok(transform, "expected one numeric SVG rotation");
    close(transform[1], input[i][4]);
    close(transform[2], input[i][0] + 52.710678118654755 + input[i][2]/2);
    close(transform[3], input[i][1] + 52.710678118654755 + input[i][3]/2);
    const viewport = group.children[0];
    assert.equal(viewport.tag, "svg");
    close(viewport.attrs.width, input[i][2]);
    close(viewport.attrs.height, input[i][3]);
    assert.equal(viewport.attrs.overflow, "hidden");
    assert.equal(viewport.children[0].attrs.transform, expectedFlips[i]);
    assert.equal(images[i].attrs.preserveAspectRatio, "xMidYMid meet");
    close(images[i].attrs.width, input[i][2]);
    close(images[i].attrs.height, input[i][3]);
    assert.ok(images[i].attrs.href.startsWith("data:image/png;base64,"));
  }
  assert.equal(budget.pixels, 4 * 318 * 335);
  assert.equal(walk(svg).filter(node => node.tag === "script").length, 0);
});

test("JSON Canvas text and file nodes retain their real card geometry and links", () => {
  const host = new OfflineNode("host");
  drawNativeGeometry(host, packed({
    nodes: [
      { id:"one",type:"text",x:10,y:10,width:200,height:100,text:"理解 🧠\n下一步" },
      { id:"two",type:"file",x:290,y:30,width:160,height:80,file:"Vault/知识.md" }
    ],
    edges:[{fromNode:"one",toNode:"two",color:"#336699"}]
  }), "impress-canvas", inlineExcalidrawResourceBudget());
  const svg = host.children[0];
  const cards = walk(svg).filter(node=>node.tag==="rect");
  assert.equal(cards.length, 2, "Canvas text nodes must have a visible card outline");
  const labels = walk(svg).filter(node=>node.tag==="title").map(n=>n.textContent);
  assert.ok(labels.some(s=>s.includes("理解 🧠")));
  assert.equal(walk(svg).filter(node=>node.tag==="path").length, 2,
    "JSON Canvas 1.0 defaults to one target arrowhead");
});

test("Excalidraw text remains inert SVG text, including authored HTML syntax", () => {
  const host = new OfflineNode("host");
  drawNativeGeometry(host, packed({
    elements: [
      {id:"shape",type:"rectangle",x:0,y:0,width:190,height:80},
      {id:"label",type:"text",containerId:"shape",x:5,y:7,
       width:180,height:64,text:"<script>bad()</script>\n中文 🧠",fontSize:22}
    ]
  }), "impress-excalidraw", inlineExcalidrawResourceBudget());
  const svg = host.children[0];
  const nodes = walk(svg);
  assert.equal(nodes.filter(n=>n.tag==="script").length, 0);
  const rawText = nodes.filter(n=>n.tag==="tspan").map(n=>n.textContent).join("");
  assert.ok(rawText.includes("<script>bad()</script>"));
  assert.ok(rawText.includes("中文 🧠"));
});

test("JSON Canvas explicit side anchors, arrow ends, labels and preset colors reach actual SVG", () => {
  const host = new OfflineNode("host");
  drawNativeGeometry(host, packed({
    nodes: [
      {id:"a",type:"text",x:10,y:20,width:100,height:60,text:"起点"},
      {id:"b",type:"text",x:230,y:170,width:80,height:50,text:"终点"}
    ],
    edges:[{id:"edge-1",fromNode:"a",fromSide:"top",fromEnd:"arrow",
      toNode:"b",toSide:"bottom",toEnd:"none",color:"5",label:"方向 🧠 <script>"}]
  }), "impress-canvas", inlineExcalidrawResourceBudget());
  const svg = host.children[0];
  const nodes = walk(svg);
  const line = nodes.find(node=>node.attrs?.["data-canvas-edge"]==="edge-1");
  assert.ok(line);
  assert.match(line.attrs.d,/^M[0-9.]+ [0-9.]+ C/);
  assert.equal(line.attrs.stroke,"#358fa6");
  assert.equal(nodes.filter(node=>node.attrs?.["data-canvas-arrow"]==="from").length,1);
  assert.equal(nodes.filter(node=>node.attrs?.["data-canvas-arrow"]==="to").length,0);
  assert.ok(nodes.some(node=>node.tag==="text" &&
    node.textContent==="方向 🧠 <script>"),"Edge label is inert SVG text");
  assert.equal(nodes.filter(node=>node.tag==="script").length,0);
});
