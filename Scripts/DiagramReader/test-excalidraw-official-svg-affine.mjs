// Same-element geometry from Excalidraw's own export.test.tsx and the
// matching svg-image-exporting-reference.svg, frozen at upstream commit
// excalidraw/excalidraw@14bb42edee3d6fee6be264e3ee78670b3b9cee79.
// This is an OFFICIAL EXPORT AFFINE A/B CHECK, not pixel/fidelity approval.
// Reference: packages/excalidraw/tests/fixtures/svg-image-exporting-reference.svg
// It validates geometry/orientation without fetching any SVG, images or fonts.
import test from "node:test";
import assert from "node:assert/strict";
import { inlineExcalidrawFrame, inlineExcalidrawBounds,
  inlineExcalidrawImagePlacement } from "./inline-excalidraw-projection.mjs";
import { inlineExcalidrawRadians, inlineExcalidrawDegrees }
  from "./inline-excalidraw-angle.mjs";
import { inlineExcalidrawTextLayout } from "./inline-excalidraw-text.mjs";

const close = (actual, expected, tolerance = 1e-6) =>
  assert.ok(Math.abs(actual - expected) <= tolerance,
    "upstream SVG " + expected + " != Impress " + actual);
const deg = value => value * Math.PI / 180;
// Four source images from the official Excalidraw transformed-image SVG test.
const upstreamImages = [
  { x:0, y:0, w:100, h:100, angle:315, scale:[1,1] },
  { x:100, y:0, w:50, h:50, angle:45, scale:[-1,1] },
  { x:0, y:100, w:100, h:100, angle:45, scale:[1,-1] },
  { x:100, y:100, w:50, h:50, angle:315, scale:[-1,-1] }
];
const elements = upstreamImages.map(item => ({
  x:item.x, y:item.y, w:item.w, h:item.h,
  raw:{ type:"image", angle:deg(item.angle), scale:item.scale }
}));

test("official Excalidraw 4-image SVG A/B: same bbox and source transforms", () => {
  // The upstream SVG export uses exportPadding=10. The app uses 32 for
  // additional drawing stroke safety; compare the *same* padding here.
  const picture = inlineExcalidrawFrame(elements, 10);
  assert.ok(picture);
  close(picture.width, 201.06601717798213);
  close(picture.height, 261.4213562373095);
  close(picture.dx, 30.710678118654755);
  close(picture.dy, 30.710678118654755);
  const sourceTranslations = [
    [30.710678118654755,30.710678118654755],
    [130.71067811865476,30.710678118654755],
    [30.710678118654755,130.71067811865476],
    [130.71067811865476,130.71067811865476]
  ];
  elements.forEach((element,index) => {
    const [refX,refY] = sourceTranslations[index];
    close(element.x + picture.dx, refX);
    close(element.y + picture.dy, refY);
    close(inlineExcalidrawDegrees(element.raw.angle) < 0
      ? inlineExcalidrawDegrees(element.raw.angle) + 360
      : inlineExcalidrawDegrees(element.raw.angle), upstreamImages[index].angle);
    const mapped = inlineExcalidrawImagePlacement(
      {scale:element.raw.scale}, {width:318,height:335}, element.w, element.h);
    assert.ok(mapped);
    assert.equal(mapped.flipX,upstreamImages[index].scale[0]);
    assert.equal(mapped.flipY,upstreamImages[index].scale[1]);
    close(mapped.width,element.w);
    close(mapped.height,element.h);
    assert.equal(mapped.preserveAspectRatio, "xMidYMid meet",
      "The official SVG <image> uses the default meet aspect; never stretch");
    // Same source 318×335 PNG reused by all four official transformed images.
    // Under the upstream SVG image viewport the paint is centered, not scaled
    // non-uniformly. Flips affect orientation, not image content bounds.
    const factor = Math.min(mapped.width / 318, mapped.height / 335);
    const imageWidth = 318 * factor, imageHeight = 335 * factor;
    close(imageHeight, element.h);
    close(imageWidth, element.w * 318 / 335);
    close((mapped.width - imageWidth) / 2, element.w * (1 - 318 / 335) / 2);
  });
});

test("large finite angles do not desynchronize text ink, shape and viewBox", () => {
  const source=1000 * 2 * Math.PI + Math.PI / 2;
  close(inlineExcalidrawDegrees(source),90,0.000001);
  const text={type:"text",text:"学习 🧠\n归纳",fontSize:36,angle:source};
  const layout=inlineExcalidrawTextLayout(text,
    {x:20,y:30,width:120,height:24});
  assert.match(layout.rotation,/^rotate\(90\.000 80 42\)$/);
  const bound=inlineExcalidrawBounds({
    x:20,y:30,w:120,h:24,raw:text
  });
  assert.ok(bound.minX<0 && bound.maxY>100);
  close(inlineExcalidrawRadians(source),Math.PI/2,0.000001);
  // Numerically shaped source strings must not rotate paint while the
  // bounds unrotate (a real mismatch in the previous production path).
  assert.equal(inlineExcalidrawDegrees("1.5707963267948966"),0);
  assert.equal(inlineExcalidrawTextLayout({...text,angle:"1.57"},
    {x:20,y:30,width:120,height:24}).rotation,null);
});

test("invalid and out-of-budget angles cannot emit invalid SVG rotate", () => {
  for (const angle of [undefined,NaN,Infinity,-Infinity,"Infinity",{},null]) {
    assert.equal(inlineExcalidrawRadians(angle),0);
    assert.equal(inlineExcalidrawDegrees(angle),0);
  }
  for (const source of [1e100,-1e100,-0]) {
    assert.ok(Number.isFinite(inlineExcalidrawRadians(source)));
    assert.ok(Math.abs(inlineExcalidrawDegrees(source))<=360);
  }
});
