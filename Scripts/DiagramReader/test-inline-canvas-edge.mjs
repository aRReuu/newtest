import test from "node:test";
import assert from "node:assert/strict";
import { inlineCanvasEdgeGeometry as edge, inlineCanvasColor } from "./inline-canvas-edge.mjs";

const a = {x:10,y:20,w:100,h:60};
const b = {x:230,y:170,w:80,h:50};

test("JSON Canvas 1.0 default endpoints have a directed arrow and centered label anchor", () => {
  const e = edge(a,b,{});
  assert.deepEqual(e.start,[110,50]);
  assert.deepEqual(e.end,[230,195]);
  assert.equal(e.startArrow,false);
  assert.equal(e.endArrow,true);
  assert.match(e.d,/^M110 50 C/);
  assert.ok(e.labelAt.every(Number.isFinite));
});

test("explicit top/bottom/left/right, both endpoint shapes and translation", () => {
  const e = edge(a,b,{fromSide:"top",toSide:"bottom",fromEnd:"arrow",toEnd:"none"},32,40);
  assert.deepEqual(e.start,[92,60]);
  assert.deepEqual(e.end,[302,260]);
  assert.deepEqual(e.controlStart,[92,36]);
  assert.deepEqual(e.controlEnd,[302,284]);
  assert.equal(e.startArrow,true);
  assert.equal(e.endArrow,false);
  const f = edge(a,b,{fromSide:"left",toSide:"right"});
  assert.deepEqual(f.start,[10,50]);
  assert.deepEqual(f.end,[310,195]);
});

test("official numbered canvas colors and hex are inert, unknown fallback safe",()=>{
  for(const key of ["1","2","3","4","5","6"]) assert.match(inlineCanvasColor(key),/^#[0-9a-fA-F]{6}$/);
  assert.equal(inlineCanvasColor("#A1b2C3"),"#A1b2C3");
  assert.equal(inlineCanvasColor("url(https://invalid)"),"#888890");
  assert.equal(inlineCanvasColor("var(--unsafe)"),"#888890");
});

test("invalid geometry fails closed without evaluating source text",()=>{
  for(const invalid of [{...a,x:Infinity},{...a,w:-1},{...a,h:0},{...a,x:2000000}]) {
    assert.equal(edge(invalid,b,{}),null);
  }
  assert.equal(edge(a,b,null),null);
  assert.equal(edge(a,b,{},Infinity,0),null);
  const fallback=edge(a,b,{fromSide:"<script>",toSide:"bad",fromEnd:"<script>",toEnd:"none"});
  assert.deepEqual(fallback.start,[110,50]);
  assert.equal(fallback.startArrow,false);
  assert.equal(fallback.endArrow,false);
});
