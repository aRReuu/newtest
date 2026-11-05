// Pure Excalidraw inline preview geometry. No DOM, Vault, network or code evaluation.
// Native renderer and this read-only SVG projection consume the same authored
// endpoint type and must be compared against official SVG before fidelity PASS.
export function inlineArrowheadGeometry(style, tip, neighbor, strokeWidth = 1.5) {
  if (!["arrow", "triangle", "triangle_outline", "dot", "circle",
        "circle_outline", "bar", "diamond", "diamond_outline"].includes(style)) return null;
  if (!Array.isArray(tip) || !Array.isArray(neighbor) ||
      tip.length < 2 || neighbor.length < 2) return null;
  const [tx, ty] = tip.map(Number), [nx, ny] = neighbor.map(Number);
  if (![tx,ty,nx,ny].every(v=>Number.isFinite(v)&&Math.abs(v)<=1000000)) return null;
  const dx=tx-nx,dy=ty-ny,dist=Math.hypot(dx,dy);
  if (!Number.isFinite(dist)||dist<=0.001) return null;
  const ux=dx/dist,uy=dy/dist,px=-uy,py=ux;
  const weight=Math.min(24,Math.max(0.5,Number(strokeWidth)||1.5));
  const length=Math.min(24,Math.max(10,10+weight*2));
  const spread=length*0.46;
  const bx=tx-ux*length,by=ty-uy*length;
  const left=[bx+px*spread,by+py*spread];
  const right=[bx-px*spread,by-py*spread];
  const far=[tx-ux*length*2,ty-uy*length*2];
  const fmt=point=>point[0].toFixed(3)+" "+point[1].toFixed(3);
  const at=[tx,ty];
  // Reuse the painted SVG's own vertices for conservative viewBox limits.
  const result=(d,filled,points)=>({d,filled,extent:{
    minX:Math.min(...points.map(p=>p[0])),minY:Math.min(...points.map(p=>p[1])),
    maxX:Math.max(...points.map(p=>p[0])),maxY:Math.max(...points.map(p=>p[1]))
  }});
  switch(style) {
    case "arrow":
      return result("M"+fmt(left)+" L"+fmt(at)+" L"+fmt(right),false,[left,at,right]);
    case "triangle":
    case "triangle_outline":
      return result("M"+fmt(at)+" L"+fmt(left)+" L"+fmt(right)+" Z",
        style==="triangle",[at,left,right]);
    case "bar": {
      const a=[tx+px*spread,ty+py*spread];
      const b=[tx-px*spread,ty-py*spread];
      return result("M"+fmt(a)+" L"+fmt(b),false,[a,b]);
    }
    case "dot":
    case "circle":
    case "circle_outline": {
      const radius=length*0.30;
      return result("M"+(tx-radius).toFixed(3)+" "+ty.toFixed(3)+
        " A"+radius.toFixed(3)+" "+radius.toFixed(3)+" 0 1 0 "+
        (tx+radius).toFixed(3)+" "+ty.toFixed(3)+
        " A"+radius.toFixed(3)+" "+radius.toFixed(3)+" 0 1 0 "+
        (tx-radius).toFixed(3)+" "+ty.toFixed(3)+" Z",
        style==="dot"||style==="circle",
        [[tx-radius,ty-radius],[tx+radius,ty+radius]]);
    }
    case "diamond":
    case "diamond_outline":
      return result("M"+fmt(at)+" L"+fmt(left)+" L"+fmt(far)+
        " L"+fmt(right)+" Z",style==="diamond",[at,left,far,right]);
    default: return null;
  }
}
