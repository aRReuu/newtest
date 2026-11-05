import test from "node:test";
import assert from "node:assert/strict";
import { inlineExcalidrawBounds as bounds, inlineExcalidrawFrame as frame,
  inlineExcalidrawImagePlacement as placement } from "./inline-excalidraw-projection.mjs";
const close = (a, b) => assert.ok(Math.abs(a - b) < 1e-6, `${a} ≠ ${b}`);

test("rotated frame expands viewBox for 45 and 90 degree Excalidraw elements", () => {
  const a = bounds({x:0,y:0,w:100,h:20,raw:{angle:Math.PI/4}});
  const diagonal = (100+20)/Math.sqrt(2);
  close(a.maxX-a.minX, diagonal); close(a.maxY-a.minY, diagonal);
  const box = frame([{x:0,y:0,w:100,h:20,raw:{angle:Math.PI/2}}]);
  close(box.width, 84); close(box.height, 164);
  close(box.dx, -8); close(box.dy, 72);
  const original = frame([{x:0,y:0,w:100,h:20,raw:{angle:0}}]);
  close(original.width,164); close(original.height,84);
});

test("frame rejects infinite geometry, huge rotated area and unsafe lists", () => {
  assert.equal(frame([{x:0,y:0,w:10000,h:10000,raw:{angle:1}}]), null);
  assert.equal(frame([{x:Infinity,y:0,w:2,h:3,raw:{angle:0}}]), null);
  assert.equal(frame(new Array(351).fill({x:0,y:0,w:2,h:3})), null);
  assert.equal(bounds({x:0,y:0,w:NaN,h:20}), null);
});

test("image crop window maps natural image pixels into rotated/flip-safe SVG viewport", () => {
  const img={width:800,height:600};
  const element={scale:[-1,1],crop:{x:100,y:50,width:400,height:300,naturalWidth:800,naturalHeight:600}};
  assert.deepEqual(placement(element,img,200,150),
    {x:-50,y:-25,width:400,height:300,flipX:-1,flipY:1,preserveAspectRatio:"none"});
  assert.deepEqual(placement({scale:[1,-1]},img,200,150),
    {x:0,y:0,width:200,height:150,flipX:1,flipY:-1,preserveAspectRatio:"xMidYMid meet"});
});

test("malformed crop, cross-file dimensions, invalid flips and crop bombs fail closed", () => {
  const raster={width:800,height:600};
  const normal={x:0,y:0,width:400,height:300,naturalWidth:800,naturalHeight:600};
  for (const changes of [{x:-1},{width:0},{x:500},{naturalWidth:801},
    {height:NaN},{naturalHeight:Infinity},{width:0.00001}]) {
    assert.equal(placement({crop:{...normal,...changes}},raster,200,150),null);
  }
  assert.equal(placement({scale:[2,1]},raster,200,150),null);
  assert.equal(placement({crop:{...normal,width:1}},raster,200,150),null);
  assert.equal(placement({},raster,Infinity,150),null);
});

test("negative freehand/arrow vertices expand SVG bounds beyond serialized box", () => {
  const point = { x:300, y:220, w:100, h:60,
    raw:{type:"arrow",angle:0,points:[[0,0],[-240,-120],[100,60]]}};
  const result = frame([point]);
  close(result.width, 404); close(result.height, 244);
  close(result.dx, -28); close(result.dy, -68);
  const frameWithNoPoints = frame([{...point,raw:{type:"arrow",angle:0}}]);
  close(frameWithNoPoints.width, 164);
  assert.ok(result.width > frameWithNoPoints.width);
});

test("rotated freehand vertices use the same rotation center as drawn SVG", () => {
  const point={x:100,y:200,w:60,h:40,
    raw:{type:"freedraw",angle:Math.PI/2,points:[[-80,-10],[0,0]]}};
  const result=bounds(point);
  // (-80,-10) maps from (20,190) to (160,110) about center (130,220).
  close(result.minY, 110);
  close(result.maxX, 160);
  const view=frame([point]);
  close(view.height, 204);
});

test("malformed point coordinates cannot create unbounded geometry", () => {
  const base={x:0,y:0,w:40,h:40};
  for(const invalid of [[Infinity,2], [NaN,3], ["99999",5], null]) {
    assert.equal(frame([{...base,raw:{type:"line",points:[[0,0],invalid]}}]),null);
  }
  assert.equal(frame([{...base,raw:{type:"freedraw",points:[[0,0],[1e9,0]]}}]),null);
});

test("short opposing diamond arrowheads expand the inline SVG frame", () => {
  const arrow={x:0,y:0,w:2,h:40,raw:{type:"arrow",angle:0,strokeWidth:12,
    startArrowhead:"diamond",endArrowhead:"diamond_outline",points:[[0,20],[2,20]]}};
  const result=bounds(arrow);
  assert.ok(result.minX < -32 && result.maxX > 34);
  const view=frame([arrow]);
  assert.ok(view.dx > 64 && view.width > 120);
});

test("short arrowhead extents use the same rotated center as painted SVG", () => {
  const arrow={x:0,y:0,w:2,h:40,raw:{type:"arrow",angle:Math.PI/2,
    strokeWidth:12,endArrowhead:"diamond",points:[[0,20],[2,20]]}};
  const result=bounds(arrow);
  assert.ok(result.minY < -20 && result.maxY >= 21);
  assert.ok(frame([arrow]).height > 64);
});

test("unpaintable arrowheads stay ignored without weakening malformed point rejection", () => {
  const base={x:0,y:0,w:50,h:50};
  assert.ok(bounds({...base,raw:{type:"arrow",startArrowhead:"unsupported",
    points:[[-150,0],[50,0]]}}).minX<=-150);
  assert.equal(frame([{...base,raw:{type:"arrow",endArrowhead:"diamond",
    points:[[0,0],[Infinity,0]]}}]),null);
});

test("multiline Chinese text ink is included beyond a short serialized height", () => {
  const element={x:100,y:40,w:140,h:20,raw:{type:"text",
    text:"第一行 🧠\n第二行 🌱\n第三行 🐚",fontSize:42,lineHeight:1.5}};
  const ink=bounds(element);
  assert.ok(ink.maxY > element.y+element.h+125,
    "all three painted baselines must fit, not merely the serialized box");
  const view=frame([element]);
  assert.ok(view.height>200);
  assert.ok(view.width>element.w+64);
});

test("oversized rotated bound text expands the viewBox while empty ink stays safe", () => {
  const element={x:0,y:0,w:100,h:16,raw:{type:"text",angle:Math.PI/2,
    text:"标题\n内容\n结论",fontSize:36,lineHeight:1.6}};
  const ink=bounds(element);
  assert.ok(ink.minX < -80);
  assert.ok(frame([element]).width > 190);
  assert.ok(bounds({...element,raw:{type:"text",text:"",fontSize:36}}));
  assert.equal(frame([{...element,raw:{...element.raw,fontSize:Infinity}}])!==null,true);
});

test("uncropped embedded image uses official aspect; cropped image fills window", () => {
  const bitmap = {width:318,height:335};
  const plain = placement({scale:[-1,-1]},bitmap,100,100);
  assert.equal(plain.preserveAspectRatio,"xMidYMid meet");
  const scale = Math.min(100/bitmap.width,100/bitmap.height);
  close(bitmap.width*scale,94.92537313432835);
  close(bitmap.height*scale,100);
  const clipped = placement({scale:[-1,-1],crop:{
    x:0,y:0,width:318,height:335,naturalWidth:318,naturalHeight:335
  }},bitmap,100,100);
  assert.equal(clipped.preserveAspectRatio,"none");
  assert.equal(placement({crop:{x:0,y:0,width:318,height:335,
    naturalWidth:319,naturalHeight:335}},bitmap,100,100),null);
});
