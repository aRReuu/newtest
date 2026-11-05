// JSON Canvas 1.0 edge projection for offline, read-only Markdown previews.
// Edges carry explicit source-side and arrow/label semantics; no navigation or Vault IO.
const SIDES = new Set(["top", "right", "bottom", "left"]);
const PRESET = Object.freeze({
  "1": "#c95b68", "2": "#ca8644", "3": "#b49b3a",
  "4": "#3c976b", "5": "#358fa6", "6": "#9568b5"
});

export function inlineCanvasColor(value, fallback = "#888890") {
  const key = String(value ?? "");
  return /^#[0-9a-fA-F]{6}$/.test(key) ? key : (PRESET[key] ?? fallback);
}

function endpoint(node, side, dx, dy) {
  const { x, y, w, h } = node;
  if (![x,y,w,h,dx,dy].every(n => Number.isFinite(n) && Math.abs(n) <= 1000000) ||
      w <= 0 || h <= 0) return null;
  const left = x + dx, top = y + dy;
  switch (side) {
    case "top": return { p:[left+w/2, top], outward:[0,-1] };
    case "bottom": return { p:[left+w/2, top+h], outward:[0,1] };
    case "left": return { p:[left, top+h/2], outward:[-1,0] };
    default: return { p:[left+w, top+h/2], outward:[1,0] };
  }
}

const fmt = n => Number(n.toFixed(3));
export function inlineCanvasEdgeGeometry(from, to, edge = {}, dx = 0, dy = 0) {
  if (!from || !to || !edge || typeof edge !== "object") return null;
  const fromSide = SIDES.has(edge.fromSide) ? edge.fromSide : "right";
  const toSide = SIDES.has(edge.toSide) ? edge.toSide : "left";
  const a = endpoint(from, fromSide, dx, dy);
  const b = endpoint(to, toSide, dx, dy);
  if (!a || !b) return null;
  const distance = Math.hypot(b.p[0]-a.p[0], b.p[1]-a.p[1]);
  const strength = Math.min(24, Math.max(12, distance*0.2));
  const p1 = [a.p[0]+a.outward[0]*strength, a.p[1]+a.outward[1]*strength];
  const p2 = [b.p[0]+b.outward[0]*strength, b.p[1]+b.outward[1]*strength];
  const center = [0,1].map(i => (a.p[i]+3*p1[i]+3*p2[i]+b.p[i])/8);
  const d = "M"+fmt(a.p[0])+" "+fmt(a.p[1])+" C"+fmt(p1[0])+" "+fmt(p1[1])+" "+fmt(p2[0])+" "+fmt(p2[1])+" "+fmt(b.p[0])+" "+fmt(b.p[1]);
  return {
    d, start:a.p, end:b.p, controlStart:p1, controlEnd:p2, labelAt:center,
    startArrow:edge.fromEnd === "arrow",
    endArrow:edge.toEnd !== "none",
    color:inlineCanvasColor(edge.color)
  };
}
