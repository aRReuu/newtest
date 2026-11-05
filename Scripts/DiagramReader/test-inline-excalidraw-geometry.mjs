import test from "node:test";
import assert from "node:assert/strict";
import { inlineArrowheadGeometry as head } from "./inline-excalidraw-geometry.mjs";

test("explicit arrowhead geometry preserves source types",()=>{
  const arrow=head("arrow",[100,40],[0,0],2);
  const triangle=head("triangle",[100,40],[0,0],2);
  const hollow=head("triangle_outline",[100,40],[0,0],2);
  const circle=head("dot",[100,40],[0,0],2);
  assert.equal(arrow.filled,false);
  assert.equal(arrow.d.endsWith(" Z"),false);
  assert.equal(triangle.filled,true);
  assert.equal(hollow.filled,false);
  assert.match(triangle.d,/ Z$/);
  assert.match(circle.d,/ A/);
  assert.equal(circle.filled,true);
  assert.notEqual(arrow.d,triangle.d);
});
test("no-head, unknown and malformed input fail closed",()=>{
  for(const kind of [undefined,null,"none","script","<svg>"]){
    assert.equal(head(kind,[100,40],[0,0]),null);
  }
  assert.equal(head("arrow",[1,1],[1,1]),null);
  assert.equal(head("triangle",[Infinity,1],[0,0]),null);
  assert.equal(head("triangle",[100000000,0],[0,0]),null);
  assert.equal(head("triangle",[1,2],[NaN,0]),null);
});
test("start and end reverse their orientation without changing coordinates",()=>{
  const start=head("bar",[0,0],[100,0]);
  const end=head("bar",[100,0],[0,0]);
  assert.match(start.d,/M0\.000/);
  assert.match(end.d,/M100\.000/);
  assert.notEqual(start.d,end.d);
});
test("stroke width changes endpoint dimensions but is bounded",()=>{
  const thin=head("diamond",[60,20],[0,0],1);
  const thick=head("diamond",[60,20],[0,0],10);
  const enormous=head("diamond",[60,20],[0,0],Infinity);
  assert.notEqual(thin.d,thick.d);
  assert.ok(enormous && enormous.d.length<250);
});

test("painted diamond and circle arrowheads expose matching viewBox extents",()=>{
  const diamond=head("diamond",[0,0],[2,0],12);
  assert.equal(diamond.extent.maxX,48);
  assert.equal(diamond.extent.minX,0);
  const circle=head("dot",[0,0],[10,0],12);
  assert.ok(Math.abs(circle.extent.minX+7.2)<1e-6);
  assert.ok(Math.abs(circle.extent.maxY-7.2)<1e-6);
});
