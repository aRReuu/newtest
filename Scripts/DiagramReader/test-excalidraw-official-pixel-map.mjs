// Source-pixel A/B against Excalidraw's MIT-licensed SVG export fixture.
// This compares actual production SVG DOM with upstream source-pixel mapping
// across image aspect ratio, rotation, orientation and both axis flips.
// It does NOT replace UIKit/WKWebView screenshots or typography A/B.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { inlineExcalidrawResourceBudget } from "./inline-excalidraw-resource-budget.mjs";

class OfflineNode {
  constructor(tag) { this.tag = tag; this.attrs = {}; this.children = []; }
  setAttribute(key, value) { this.attrs[key] = String(value); }
  append(...children) { this.children.push(...children); }
  replaceChildren(...children) { this.children = children; }
}
globalThis.document = {
  getElementById: id => new OfflineNode(id),
  createElementNS: (_, tag) => new OfflineNode(tag),
  createElement: tag => new OfflineNode(tag)
};
globalThis.window = {};
const { drawNativeGeometry } = await import("./markdown-host.js");
const reference = readFileSync(new URL("./fixtures/excalidraw-upstream-four-images.svg", import.meta.url), "utf8");
const sourceURL = reference.match(/<image\b[^>]*\bhref="(data:image\/png;base64,[^"]+)"/)?.[1];
assert.ok(sourceURL, "Official source must embed the actual image, without network");
const png = Buffer.from(sourceURL.split(",")[1], "base64");
assert.equal(png.subarray(0,8).toString("hex"), "89504e470d0a1a0a");
const imageWidth=png.readUInt32BE(16), imageHeight=png.readUInt32BE(20);
assert.deepEqual([imageWidth,imageHeight],[318,335]);

const upstream=[...reference.matchAll(/<g transform="translate\(([^)]+)\) rotate\(([^)]+)\)"><use\b[^>]*width="([^"]+)" height="([^"]+)"(?: transform="([^"]+)")?><\/use><\/g>/g)].map(match=>{
  const [tx,ty]=match[1].trim().split(/\s+/).map(Number);
  const [angle,cx,cy]=match[2].trim().split(/\s+/).map(Number);
  const scale=match[5]?.match(/scale\((-?\d+),\s*(-?\d+)\)/);
  return {tx,ty,angle,cx,cy,w:Number(match[3]),h:Number(match[4]),
    flipX:scale?Number(scale[1]):1,flipY:scale?Number(scale[2]):1,
    aspect:"xMidYMid meet"};
});
assert.equal(upstream.length,4,"Compare all four actual upstream export transforms");
const elements=upstream.map((ref,index)=>({
  id:"official-"+index,type:"image",fileId:"upstream-file",
  x:[0,100,0,100][index],y:[0,0,100,100][index],
  width:ref.w,height:ref.h,angle:ref.angle*Math.PI/180,
  scale:[ref.flipX,ref.flipY]
}));
const host=new OfflineNode("host");
drawNativeGeometry(host,Buffer.from(JSON.stringify({
  elements,files:{"upstream-file":{dataURL:sourceURL,mimeType:"image/png"}}
}),"utf8").toString("base64"),"impress-excalidraw",inlineExcalidrawResourceBudget());
const root=host.children[0];
assert.equal(root.tag,"svg");
const groups=root.children.filter(child=>child.tag==="g");
assert.equal(groups.length,4);
const app=groups.map(group=>{
  const angle=group.attrs.transform?.match(/^rotate\(([-\d.]+) ([-\d.]+) ([-\d.]+)\)$/);
  assert.ok(angle,"Real renderer must rotate the painted image group");
  const viewport=group.children.find(child=>child.tag==="svg");
  assert.ok(viewport,"Real renderer must create the clipped SVG viewport");
  const flip=viewport.children[0]?.attrs.transform?.match(/scale\((-?\d+) (-?\d+)\)/);
  assert.ok(flip,"Explicit image scale/flip required");
  const image=viewport.children[0].children.find(child=>child.tag==="image");
  assert.equal(image?.attrs.href,sourceURL,"Must use identical upstream image bytes");
  // App padding=32; upstream export padding=10. Normalize coordinates only.
  const extraPadding=22;
  const tx=Number(viewport.attrs.x)-extraPadding;
  const ty=Number(viewport.attrs.y)-extraPadding;
  return {tx,ty,angle:Number(angle[1]),
    cx:Number(angle[2])-extraPadding-tx,
    cy:Number(angle[3])-extraPadding-ty,
    w:Number(viewport.attrs.width),h:Number(viewport.attrs.height),
    flipX:Number(flip[1]),flipY:Number(flip[2]),
    aspect:image.attrs.preserveAspectRatio};
});

// Sample the exact source PNG pixel address at each output pixel center.
// Matching addresses + identical PNG bytes imply matching sampled pixels;
// WebKit interpolation/antialiasing still requires an additional visual test.
function pixelAddress(item,px,py) {
  const radians=item.angle*Math.PI/180;
  const cs=Math.cos(radians),sn=Math.sin(radians);
  const dx=px-item.tx-item.cx,dy=py-item.ty-item.cy;
  let x=item.cx+cs*dx+sn*dy;
  let y=item.cy-sn*dx+cs*dy;
  if(x<0||x>=item.w||y<0||y>=item.h)return -1;
  if(item.flipX===-1)x=item.w-x;
  if(item.flipY===-1)y=item.h-y;
  let sx,sy;
  if(item.aspect==="none"){
    sx=x*imageWidth/item.w;
    sy=y*imageHeight/item.h;
  }else{
    const factor=Math.min(item.w/imageWidth,item.h/imageHeight);
    sx=(x-(item.w-imageWidth*factor)/2)/factor;
    sy=(y-(item.h-imageHeight*factor)/2)/factor;
  }
  if(sx<0||sx>=imageWidth||sy<0||sy>=imageHeight)return -1;
  return Math.floor(sy)*imageWidth+Math.floor(sx);
}
function topPixel(items,x,y) {
  for(let i=items.length-1;i>=0;i--){
    const pixel=pixelAddress(items[i],x,y);
    if(pixel>=0)return pixel;
  }
  return -1;
}
test("official SVG and production DOM map every output pixel to the same source PNG pixel",()=>{
  const viewBox=reference.match(/\bviewBox="0 0 ([\d.]+) ([\d.]+)"/);
  assert.ok(viewBox);
  const width=Math.ceil(Number(viewBox[1])),height=Math.ceil(Number(viewBox[2]));
  let compared=0,mismatches=0;
  for(let y=0;y<height;y++)for(let x=0;x<width;x++){
    const expected=topPixel(upstream,x+0.5,y+0.5);
    const actual=topPixel(app,x+0.5,y+0.5);
    compared++;
    if(expected!==actual)mismatches++;
  }
  assert.ok(compared>50_000);
  assert.ok(mismatches<=8,mismatches+"/"+compared+" source-pixel mapping mismatches");
});
