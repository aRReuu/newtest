import test from "node:test";
import assert from "node:assert/strict";
import { inlineExcalidrawTextLayout as layout, orderExcalidrawPaint as paint }
  from "./inline-excalidraw-text.mjs";

const frame = { x: 24, y: 40, width: 360, height: 180 };
test("authored Chinese bound text preserves geometry and typography", () => {
  const projected = layout({
    type: "text", text: "任务文字：复习及理解 🧠",
    fontSize: 32, fontFamily: 3, strokeColor: "#223344",
    opacity: 60, lineHeight: 1.4, verticalAlign: "middle",
    textAlign: "center", angle: Math.PI / 2
  }, frame);
  assert.equal(projected.fontSize, 32);
  assert.equal(projected.lineHeight, 44.8);
  assert.equal(projected.ink, "#223344");
  assert.equal(projected.opacity, 0.6);
  assert.equal(projected.textAnchor, "middle");
  assert.equal(projected.anchorX, 204);
  assert.match(projected.fontFamily, /monospace/);
  assert.match(projected.rotation, /^rotate\(90\.000 204 130\)$/);
  assert.ok(projected.lines.join("").includes("🧠"));
  assert.ok(projected.baselineY > frame.y + 3 + 32);
});

test("emoji grapheme clusters, explicit breaks and right alignment survive", () => {
  const projected = layout({
    type: "text", text: "👨‍👩‍👧‍👦 Family\n另一行", fontSize: 20,
    textAlign: "right", verticalAlign: "bottom"
  }, { x: 0, y: 0, width: 200, height: 100 });
  assert.equal(projected.textAnchor, "end");
  assert.equal(projected.anchorX, 197);
  assert.equal(projected.lines.length, 2);
  assert.equal(projected.lines[0].startsWith("👨‍👩‍👧‍👦"), true);
  assert.equal(projected.lines[1], "另一行");
  assert.equal(projected.rotation, null);
});

test("untrusted text and malformed dimensions remain bounded inert projection", () => {
  const projected = layout({
    type: "text", text: "<script>bad()</script>".repeat(1000),
    fontSize: Infinity, opacity: -900, lineHeight: Infinity,
    strokeColor: "url(https://evil.example)", angle: Infinity
  }, { x: Infinity, y: NaN, width: Infinity, height: Infinity });
  assert.ok(projected.lines.length <= 24);
  assert.ok(projected.lines.join("").length <= 2400);
  assert.equal(projected.fontSize, 20);
  assert.equal(projected.opacity, 0);
  assert.equal(projected.ink, "#34343a");
  assert.equal(projected.rotation, null);
  assert.ok(projected.lines.join("").includes("<script>"));
  assert.equal(layout({ type: "rectangle", text: "ignore" }, frame), null);
});

test("bound text follows container z order regardless of serialization position", () => {
  const input = [
    {raw:{id:"bound",type:"text",containerId:"shape"}},
    {raw:{id:"unrelated",type:"rectangle"}},
    {raw:{id:"shape",type:"rectangle"}},
    {raw:{id:"later",type:"ellipse"}}
  ];
  assert.deepEqual(paint(input).map(x=>x.raw.id),
    ["unrelated","shape","bound","later"]);
  const normal = [...input.slice(1),input[0]];
  assert.deepEqual(paint(normal).map(x=>x.raw.id),
    ["unrelated","shape","bound","later"]);
  // Real Excalidraw exports may place a bound label after later shapes.
  // It is logically owned by its container and cannot jump in front of
  // a later-painted, occluding shape.
  const late = [
    {raw:{id:"base",type:"rectangle"}},
    {raw:{id:"front",type:"ellipse"}},
    {raw:{id:"late-bound",type:"text",containerId:"base"}}
  ];
  assert.deepEqual(paint(late).map(x=>x.raw.id),
    ["base","late-bound","front"]);
  const missing = [
    {raw:{id:"front",type:"ellipse"}},
    {raw:{id:"orphan",type:"text",containerId:"missing"}}
  ];
  assert.deepEqual(paint(missing).map(x=>x.raw.id),["front","orphan"],
    "Without an existing container, preserve authored paint order");
});


test("oversized text and pathological combining marks are bounded before segmentation", () => {
  const millions = layout({ type: "text", text: "学习".repeat(600000) },
    { x: 0, y: 0, width: 300, height: 180 });
  assert.ok(millions.lines.join("").length <= 2400);
  assert.ok(millions.lines.length <= 24);
  const combining = layout({
    type: "text", text: "a" + "\u0301".repeat(500000)
  }, { x: 0, y: 0, width: 300, height: 180 });
  assert.ok(combining.lines.join("").length <= 16384);
  assert.ok(combining.lines.length <= 24);
});
