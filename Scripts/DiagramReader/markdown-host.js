import MarkdownIt from "markdown-it";
import katex from "katex";
import { inlineArrowheadGeometry } from "./inline-excalidraw-geometry.mjs";
import { inlineCanvasEdgeGeometry } from "./inline-canvas-edge.mjs";
import { inlineExcalidrawTextLayout, orderExcalidrawPaint } from "./inline-excalidraw-text.mjs";
import { MAX_GRAPH_SOURCE_CHARACTERS } from "./safe-diagram-policy.mjs";
import { inlineExcalidrawBitmap } from "./inline-excalidraw-image.mjs";
import { inlineExcalidrawFrame, inlineExcalidrawImagePlacement } from "./inline-excalidraw-projection.mjs";
import { inlineExcalidrawDegrees } from "./inline-excalidraw-angle.mjs";
import { inlineExcalidrawResourceBudget } from "./inline-excalidraw-resource-budget.mjs";

const root = document.getElementById("reader");
const style = document.getElementById("impress-reading-css");
const markdown = new MarkdownIt({ html: false, linkify: false, breaks: true, typographer: false });
const escapeHtml = (input) => markdown.utils.escapeHtml(String(input || ""));
const cleanText = (source) => String(source || "")
  .replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");
const diagrams = [];
let serial = 0;
let liveMaps = [];
let propertyDocumentKey = "";
let propertiesExpanded = true;

// Trusted, typed metadata only; no YAML/HTML is interpreted in the web page.
// The native bridge is responsible for all Vault identity/version checks.
function renderNativeDocumentHeader(options, currentEpoch) {
  const header = document.createElement("header");
  header.className = "im-document-header";
  const title = document.createElement("h1");
  title.className = "im-document-title";
  title.id = "impress.notes.document-title";
  title.textContent = String(options?.documentTitle || "");
  header.append(title);
  const rawFields = Array.isArray(options?.properties) ? options.properties : [];
  const fields = rawFields.slice(0, 128).filter(
    (field) => field && typeof field.name === "string" &&
      typeof field.value === "string");
  const diagnostic = String(options?.propertiesDiagnostic || "").slice(0, 320);
  const key = String(options?.documentKey || "");
  if (propertyDocumentKey !== key) {
    propertyDocumentKey = key;
    propertiesExpanded = true;
  }
  if (fields.length > 0) {
    const details = document.createElement("details");
    details.className = "im-properties";
    details.open = propertiesExpanded;
    const summary = document.createElement("summary");
    summary.id = "impress.notes.properties-toggle";
    summary.textContent = "属性 (" + fields.length + ")";
    details.append(summary);
    const table = document.createElement("div");
    table.className = "im-properties-grid";
    for (const item of fields) {
      const name = document.createElement("span");
      name.className = "im-property-name";
      name.textContent = item.name.slice(0, 160);
      const value = document.createElement("span");
      value.className = "im-property-value";
      value.id = "impress.notes.property-value." + name.textContent;
      value.textContent = item.value.slice(0, 4096);
      table.append(name, value);
    }
    details.append(table);
    details.addEventListener("toggle", () => {
      if (serial === currentEpoch) propertiesExpanded = details.open;
    });
    header.append(details);
  }
  if (diagnostic) {
    const note = document.createElement("p");
    note.className = "im-properties-diagnostic";
    note.textContent = diagnostic + " · 请从更多操作查看 Markdown 源码";
    header.append(note);
  }
  return header;
}
const report = (state, diagramCount, failures, rendered = 0, mathCount = 0) => {
  window.webkit?.messageHandlers?.markdownState?.postMessage({
    state, diagramCount, failures, rendered, mathCount
  });
};


// Safe, local TeX projection. Input is data, never trusted HTML or arbitrary JS.
markdown.inline.ruler.before("escape", "impress_math_inline", (state, silent) => {
  const src=state.src, start=state.pos;
  if(src[start]!=="$" || src[start+1]==="$" || src[start+1]===" ")return false;
  let end=start+1;
  while((end=src.indexOf("$",end))!==-1) {
    if(src[end-1]!=="\\" && src[end-1]!==" " && end>start+1)break;
    end++;
  }
  if(end<0)return false;
  if(!silent) {
    const token=state.push("im_math_inline","math",0);
    token.content=src.slice(start+1,end);
  }
  state.pos=end+1;
  return true;
});
markdown.block.ruler.before("fence","impress_math_display",
  (state,startLine,endLine,silent) => {
    const first=state.src.slice(state.bMarks[startLine]+state.tShift[startLine],
      state.eMarks[startLine]).trim();
    if(first!=="$$")return false;
    let close=startLine+1;
    while(close<endLine) {
      const value=state.src.slice(state.bMarks[close]+state.tShift[close],
        state.eMarks[close]).trim();
      if(value==="$$")break;
      close++;
    }
    if(close===endLine)return false;
    if(!silent) {
      const token=state.push("im_math_display","math",0);
      token.block=true;
      token.content=state.getLines(startLine+1,close,0,true);
      token.map=[startLine,close+1];
    }
    state.line=close+1;
    return true;
  });
function renderMath(source, displayMode) {
  const tex=String(source||"");
  if(tex.length>10000)return "<span class=\"im-diagram-error\">公式过长，请查看源码。</span>";
  try {
    return katex.renderToString(tex,{displayMode,throwOnError:false,
      trust:false,strict:"ignore",maxExpand:200,maxSize:12});
  } catch (_) {
    return "<span class=\"im-diagram-error\">公式语法不可读。</span>";
  }
}
markdown.renderer.rules.im_math_inline=(tokens,idx)=>renderMath(tokens[idx].content,false);
markdown.renderer.rules.im_math_display=(tokens,idx)=>renderMath(tokens[idx].content,true);

const originalFence = markdown.renderer.rules.fence ||
  ((tokens, index, options, env, self) => self.renderToken(tokens, index, options));
markdown.renderer.rules.fence = (tokens, index, options, env, self) => {
  const info = (tokens[index].info || "").trim().split(/\s+/)[0].toLowerCase();
  if (!["mermaid", "markmap", "impress-canvas", "impress-excalidraw"].includes(info)) {
    return originalFence(tokens, index, options, env, self);
  }
  const source = tokens[index].content || "";
  const isEngineGraph = info === "mermaid" || info === "markmap";
  if (source.length > 950000 ||
      (isEngineGraph && source.length > MAX_GRAPH_SOURCE_CHARACTERS) ||
      diagrams.length >= 24) {
    return "<aside class=\"im-diagram-error\">图形超出离线阅读限制，请查看源码。</aside>";
  }
  const indexInDocument = diagrams.push({ kind: info, source }) - 1;
  return "<section class=\"im-diagram " + info + "\" data-im-index=\"" +
    indexInDocument + "\" aria-label=\"" + info + " 离线图形\"><p>图形加载中…</p></section>";
};

const originalImage = markdown.renderer.rules.image ||
  ((tokens, idx, options, env, self) => self.renderToken(tokens, idx, options));
markdown.renderer.rules.image = (tokens, idx, options, env, self) => {
  const url = tokens[idx].attrGet("src") || "";
  if (!/^data:image\/jpeg;base64,[A-Za-z0-9+/=]{1,650000}$/.test(url)) {
    return "<span class=\"im-diagram-error\">（图片被安全策略阻止）</span>";
  }
  return originalImage(tokens, idx, options, env, self);
};


const svgNS = "http://www.w3.org/2000/svg";
function svgMake(parent, tag, attrs = {}, text = null) {
  const el = document.createElementNS(svgNS, tag);
  for (const [key,value] of Object.entries(attrs)) el.setAttribute(key, String(value));
  if (text !== null) el.textContent = String(text);
  parent.append(el);
  return el;
}
function unpack(encoded) {
  if (encoded.length > 950000 || !/^[A-Za-z0-9+/=\s]+$/.test(encoded))
    throw Error("Embedded data too large");
  return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(
    Uint8Array.from(atob(encoded.trim()), (c) => c.charCodeAt(0))));
}
const val = (v, d = 0) => Number.isFinite(Number(v)) ? Number(v) : d;
const safeColor = (v,d="#62626a") => /^#[0-9a-fA-F]{6}$/.test(String(v || "")) ? v : d;
function diagramFrame(host, list) {
  const frame=inlineExcalidrawFrame(list);
  if (!frame) throw Error("Invalid composite geometry");
  host.replaceChildren();
  const svg=svgMake(host,"svg",{viewBox:"0 0 "+frame.width+" "+frame.height,
    width:"100%",height:Math.max(240,Math.min(650,frame.height)),
    role:"img","aria-label":"授权文件的只读图形预览"});
  return {svg,dx:frame.dx,dy:frame.dy};
}
function textAt(svg,x,y,content,width) {
  const letters=String(content || "").slice(0,1400);
  const chars=Math.max(6,Math.min(50,Math.floor(width/12)));
  const chunks=letters.split("\n").flatMap(line=>{
    const parts=[];
    for(let i=0;i<line.length;i+=chars)parts.push(line.slice(i,i+chars));
    return parts.length?parts:[""];
  }).slice(0,18);
  const text=svgMake(svg,"text",{x,y,"font-size":15,fill:"currentColor",
    "font-family":"-apple-system,system-ui,sans-serif"});
  for(const [idx,line] of chunks.entries())
    svgMake(text,"tspan",{x,dy:idx?19:0},line);
  svgMake(text,"title",{},letters);
}
// Preview text remains bounded and inert, but follows source font, ink,
// multiline, alignment, opacity, rotation and bound-text paint order.
function drawExcalidrawText(svg, raw, x, y, width, height) {
  const layout = inlineExcalidrawTextLayout(raw, { x, y, width, height });
  if (!layout) return;
  const group = svgMake(svg, "g", layout.rotation
    ? { transform: layout.rotation } : {});
  const text = svgMake(group, "text", {
    x: layout.anchorX, y: layout.baselineY,
    "font-size": layout.fontSize, "font-family": layout.fontFamily,
    "text-anchor": layout.textAnchor, fill: layout.ink,
    opacity: layout.opacity, "xml:space": "preserve"
  });
  layout.lines.forEach((line, index) => {
    svgMake(text, "tspan", {
      x: layout.anchorX, dy: index === 0 ? 0 : layout.lineHeight
    }, line);
  });
}
export function drawNativeGeometry(host,encoded,kind,mediaBudget) {
  const data=unpack(encoded);
  const isCanvas=kind==="impress-canvas";
  const raw=isCanvas?data.nodes:data.elements;
  const edges=isCanvas?(data.edges || []):[];
  if(!Array.isArray(raw)||raw.length===0||raw.length>350||edges.length>600)
    throw Error("Composite limits exceeded");
  const list=raw.filter(e=>!e.isDeleted).map(e=>({raw:e,x:val(e.x),y:val(e.y),
    w:Math.max(1,val(e.width,1)),h:Math.max(1,val(e.height,1))}));
  if(!list.length)throw Error("Empty drawing");
  const {svg,dx,dy}=diagramFrame(host,list);
  let imageCount=0, imageCharacters=0;
  if(isCanvas) {
    const nodes=new Map(list.map(e=>[e.raw.id,e]));
    for(const edge of edges) {
      if(!edge || typeof edge !== "object") continue;
      const a=nodes.get(edge.fromNode),b=nodes.get(edge.toNode);
      if(!a||!b)continue;
      const projection=inlineCanvasEdgeGeometry(a,b,edge,dx,dy);
      if(!projection)continue;
      svgMake(svg,"path",{d:projection.d,fill:"none",stroke:projection.color,
        "stroke-width":2,"data-canvas-edge":String(edge.id||"").slice(0,128)});
      const tips=[
        ["from",projection.startArrow,projection.start,projection.controlStart],
        ["to",projection.endArrow,projection.end,projection.controlEnd]
      ];
      for(const [side,enabled,at,neighbor] of tips) {
        if(!enabled)continue;
        const tip=inlineArrowheadGeometry("arrow",at,neighbor,2);
        if(tip)svgMake(svg,"path",{d:tip.d,fill:"none",stroke:projection.color,
          "stroke-width":2,"stroke-linecap":"round","stroke-linejoin":"round",
          "data-canvas-arrow":side});
      }
      if(typeof edge.label==="string" && edge.label.length) {
        let label="",count=0;
        for(const char of edge.label) {
          if(++count>128)break;
          label+=char;
        }
        if(label.trim())svgMake(svg,"text",{
          x:projection.labelAt[0],y:projection.labelAt[1]-8,
          "text-anchor":"middle","font-size":14,
          "font-family":"-apple-system,system-ui,sans-serif",
          fill:projection.color
        },label);
      }
    }
  }
  for(const e of isCanvas ? list : orderExcalidrawPaint(list)) {
    const n=e.raw,x=e.x+dx,y=e.y+dy,w=e.w,h=e.h;
    const color=safeColor(isCanvas?n.color:n.strokeColor);
    const width=isCanvas?1.6:Math.min(20,Math.max(0.5,
      n.strokeWidth==null?1.5:val(n.strokeWidth,1.5)));
    const opacity=isCanvas||n.opacity==null?1:
      Math.min(1,Math.max(0,val(n.opacity,100)/100));
    const dash=n.strokeStyle==="dashed"?"8 8":
      n.strokeStyle==="dotted"?"1 6":"none";
    const attrs={stroke:color,"stroke-width":width,
      fill:safeColor(n.backgroundColor,"transparent"),
      opacity,"stroke-dasharray":isCanvas?"none":dash,
      "stroke-linecap":n.strokeStyle==="dotted"?"round":"butt"};
    const decorated=[];
    let shape;
    let visibleImage=false;
    if(n.type==="ellipse")shape=svgMake(svg,"ellipse",{cx:x+w/2,cy:y+h/2,rx:w/2,ry:h/2,...attrs});
    else if(n.type==="diamond")shape=svgMake(svg,"polygon",{points:(x+w/2)+","+y+" "+(x+w)+","+(y+h/2)+" "+(x+w/2)+","+(y+h)+" "+x+","+(y+h/2),...attrs});
    else if(["line","arrow","freedraw"].includes(n.type)&&Array.isArray(n.points)) {
      const points=n.points.slice(0,1200).filter(p=>Array.isArray(p)&&p.length>=2)
        .map(p=>[x+val(p[0]),y+val(p[1])]);
      shape=svgMake(svg,"polyline",{points:points.map(p=>p.join(",")).join(" "),
        fill:"none",stroke:color,"stroke-width":width,opacity,
        "stroke-dasharray":dash,"stroke-linecap":attrs["stroke-linecap"]});
      if(!isCanvas && n.type==="arrow" && points.length>=2) {
        const endings=[["start",n.startArrowhead,points[0],points[1]],
          ["end",n.endArrowhead,points[points.length-1],points[points.length-2]]];
        for(const [side,style,tip,neighbor] of endings) {
          const result=inlineArrowheadGeometry(style,tip,neighbor,width);
          if(!result)continue;
          decorated.push(svgMake(svg,"path",{d:result.d,
            "data-arrowhead":side,stroke:color,
            "stroke-width":width,
            "stroke-linecap":"round","stroke-linejoin":"round",
            fill:result.filled?color:"none",opacity}));
        }
      }
    } else if(!isCanvas && n.type==="image") {
      // Offline PNG/JPEG from the current drawing's fileId only.
      const bitmap=imageCount<12?inlineExcalidrawBitmap(n,data.files):null;
      const placement=bitmap?inlineExcalidrawImagePlacement(n,bitmap,w,h):null;
      if(bitmap&&placement&&imageCharacters+bitmap.href.length<=750000&&
          mediaBudget.reserve(bitmap)){
        // Nested SVG supplies a deterministic, per-element crop viewport:
        // the image cannot draw outside its authored box after flips/rotation.
        shape=svgMake(svg,"g");
        const viewport=svgMake(shape,"svg",{x,y,width:w,height:h,
          viewBox:"0 0 "+w+" "+h,overflow:"hidden",opacity,
          role:"img","aria-label":"图纸中内嵌的离线图片"});
        const imageGroup=svgMake(viewport,"g",{
          transform:"translate("+(placement.flipX===-1?w:0)+" "+
            (placement.flipY===-1?h:0)+") scale("+
            placement.flipX+" "+placement.flipY+")"
        });
        svgMake(imageGroup,"image",{x:placement.x,y:placement.y,
          width:placement.width,height:placement.height,
          href:bitmap.href,preserveAspectRatio:placement.preserveAspectRatio});
        imageCount++;imageCharacters+=bitmap.href.length;
        visibleImage=true;
      }else{
        shape=svgMake(svg,"rect",{x,y,width:w,height:h,fill:"none",
          stroke:"#888890","stroke-dasharray":"6 4"});
      }
    } else if(n.type!=="text" || isCanvas) {
      // JSON Canvas text nodes are cards, not free-floating Excalidraw text.
      // Keep their native hit-box visible in embedded, read-only previews.
      const customRadius=n.roundness && Number.isFinite(n.roundness.value)
        ? Math.max(0,n.roundness.value) : 32;
      const radius=n.type==="rectangle"&&n.roundness?.type===3
        ?Math.min(customRadius,Math.min(w,h)/2):
        n.type==="rectangle"&&[1,2].includes(n.roundness?.type)
          ?Math.min(w,h)*0.25:
          n.type==="rectangle"||n.type==="frame"?0:4;
      shape=svgMake(svg,"rect",{x,y,width:w,height:h,rx:radius,...attrs,
        "stroke-dasharray":n.type==="group"?"7 5":attrs["stroke-dasharray"]});
    }
    if (shape && !isCanvas) {
      const degrees = inlineExcalidrawDegrees(n.angle);
      if (Math.abs(degrees) > 0.00000001) {
        // Never emit unbounded SVG transforms that disagree with the viewBox.
        const transform = "rotate(" + degrees + " " + (x+w/2) + " " + (y+h/2) + ")";
        shape.setAttribute("transform", transform);
        for (const mark of decorated) mark.setAttribute("transform", transform);
      }
    }
    if(!isCanvas && n.type==="text")
      drawExcalidrawText(svg,n,x,y,w,h);
    else if(isCanvas)
      textAt(svg,x+8,y+20,n.text||n.label||n.file||n.url||"",w-16);
    if(n.type==="image" && !visibleImage)
      textAt(svg,x+6,y+21,"图片不可用于安全离线预览",w-12);
  }
}

function promoteCallouts() {
  const kinds = new Set(["NOTE","TIP","IMPORTANT","WARNING","CAUTION","QUOTE","TODO"]);
  for (const block of root.querySelectorAll("blockquote")) {
    const heading = block.querySelector(":scope > p:first-child > strong:first-child");
    if (!heading) continue;
    const kind = (heading.textContent || "").trim().split(/\s*[·:]\s*/)[0].toUpperCase();
    if (!kinds.has(kind)) continue;
    block.classList.add("im-callout","im-callout-" + kind.toLowerCase());
    heading.classList.add("im-callout-heading");
  }
}
function markTasks() {
  for (const li of root.querySelectorAll("li")) {
    const direct = li.querySelector(":scope > p") || li;
    const child = Array.from(direct.childNodes).find((node) => node.nodeType === Node.TEXT_NODE &&
      node.textContent.trim().length > 0);
    if (!child) continue;
    const match = child.textContent.match(/^\s*\[([ xX])\]\s*/);
    if (!match) continue;
    child.textContent = child.textContent.slice(match[0].length);
    const input = document.createElement("input");
    input.type = "checkbox";
    input.disabled = true;
    input.className = "im-task";
    input.checked = match[1].toLowerCase() === "x";
    input.setAttribute("aria-label", input.checked ? "已完成任务" : "待办任务");
    direct.insertBefore(input, direct.firstChild);
  }
}
// A normal Markdown note does not initialize any diagram engine.
// This fixed, bundled local script is added only for a real graph fence.
let graphicsPromise;
function localGraphics() {
  if (window.ImpressMarkdownGraphics) return Promise.resolve(window.ImpressMarkdownGraphics);
  if (!graphicsPromise) {
    graphicsPromise = new Promise((resolve, reject) => {
      const script = document.createElement("script");
      script.src = "graphs.js";
      script.onload = () => window.ImpressMarkdownGraphics
        ? resolve(window.ImpressMarkdownGraphics) : reject(Error("Missing bundled graph engine"));
      script.onerror = () => reject(Error("Offline graph assets unavailable"));
      document.head.append(script);
    });
  }
  return graphicsPromise;
}
async function drawMermaid(host,source,dark,id) {
  const renderer=await localGraphics();
  await renderer.drawMermaid(host,source,dark,id);
}
async function drawMarkmap(host,source) {
  const renderer=await localGraphics();
  return await renderer.drawMarkmap(host,cleanText(source));
}

window.renderImpressMarkdown = async (body, options) => {
  const epoch = ++serial;
  // One render shares a single budget across all embedded drawing fences.
  // Per-image header checks alone permitted hundreds of decoded pixel bombs.
  const mediaBudget = inlineExcalidrawResourceBudget();
  const plain = String(body || "");
  const beforeKey = propertyDocumentKey;
  const beforeScroll = window.scrollY;
  if (plain.length > 8 * 1024 * 1024) {
    root.textContent = "文档超出阅读器安全预算，请切换到源码视图。";
    report("failed", 0, 1);
    return;
  }
  liveMaps.forEach((map) => {
    if (typeof map.destroy === "function") map.destroy();
  });
  liveMaps = [];
  diagrams.length = 0;
  const fontSize = Math.max(12, Math.min(42, Number(options?.fontSize) || 17));
  style.textContent = String(options?.css || "") +
    "\n.markdown-body{font-size:" + fontSize + "px!important;}";
  root.innerHTML = markdown.render(plain);
  const firstHeading = root.firstElementChild;
  if (firstHeading?.tagName === "H1" && String(options?.documentTitle || "").trim() ===
      firstHeading.textContent.trim()) {
    firstHeading.hidden = true; // Keep source AST; show one document title.
  }
  root.prepend(renderNativeDocumentHeader(options, epoch));
  markTasks();
  promoteCallouts();
  // Never make network requests for untrusted links or local Vault resources.
  // The native WKNavigationDelegate approves only explicit internal WikiLinks.
  const items = Array.from(root.querySelectorAll(".im-diagram[data-im-index]"));
  let failures = 0;
  for (let index = 0; index < items.length; index++) {
    if (epoch !== serial) return;
    const container = items[index];
    const spec = diagrams[Number(container.dataset.imIndex)];
    if (!spec) continue;
    try {
      if (spec.kind === "mermaid") {
        await drawMermaid(container, spec.source, !!options?.dark, epoch + "-" + index);
      } else if (spec.kind === "markmap") {
        const instance = await drawMarkmap(container, spec.source);
        // A switched note can finish an older Markmap fit() after the old
        // document's maps were destroyed. Never retain orphan event handlers.
        if (epoch !== serial) {
          if (typeof instance?.destroy === "function") instance.destroy();
          return;
        }
        liveMaps.push(instance);
      } else {
        drawNativeGeometry(container, spec.source, spec.kind, mediaBudget);
      }
      if (epoch !== serial) return;
    } catch (error) {
      if (epoch !== serial) return;
      failures++;
      container.replaceChildren();
      const note = document.createElement("div");
      note.className = "im-diagram-error";
      note.textContent = "离线图形无法解析；其他正文不受影响。";
      const details = document.createElement("details");
      const summary = document.createElement("summary");
      summary.textContent = "查看当前图形源码";
      const code = document.createElement("pre");
      code.textContent = spec.source;
      details.append(summary, code);
      container.append(note, details);
    }
  }
  if (epoch === serial) {
    // Preserve the one scroll position when a theme/font/preview projection
    // rerenders the same source. A different document always opens at top.
    requestAnimationFrame(() => {
      if (epoch === serial) {
        window.scrollTo(0, beforeKey === propertyDocumentKey ? beforeScroll : 0);
      }
    });
    const rendered = items.filter((item) => item.querySelector("svg")).length;
    const actualFailures = Math.max(failures, items.length - rendered);
    const mathCount = root.querySelectorAll(".katex").length;
    report(actualFailures ? "partial" : "ready",
      items.length, actualFailures, rendered, mathCount);
  }
};
