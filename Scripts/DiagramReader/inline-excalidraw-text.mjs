// Offline Excalidraw text projection shared by all inline Markdown previews.
import { inlineExcalidrawDegrees } from "./inline-excalidraw-angle.mjs";
// Draw only authored text; never evaluate its markup or fetch custom fonts.
const segmenter = typeof Intl !== "undefined" && typeof Intl.Segmenter === "function"
  ? new Intl.Segmenter(undefined, { granularity: "grapheme" }) : null;
const graphemes = s => segmenter
  ? Array.from(segmenter.segment(s), item => item.segment) : Array.from(s);
// A diagram may contain almost 1MB of untrusted JSON. Never eagerly
// segment the entire authored text (or one unbounded combining cluster).
// This cap applies before Intl.Segmenter allocates its iterator state.
const boundedTextPrefix = value => {
  const source = String(value ?? "").slice(0, 16384);
  const result = [];
  if (segmenter) {
    for (const { segment } of segmenter.segment(source)) {
      if (result.length >= 2400) break;
      result.push(segment);
    }
  } else {
    for (const glyph of source) {
      if (result.length >= 2400) break;
      result.push(glyph);
    }
  }
  return result.join("");
};
const bounded = (raw, min, max, fallback) => {
  if (raw === null || raw === undefined || raw === "") return fallback;
  const number = Number(raw);
  return Number.isFinite(number) ? Math.max(min, Math.min(max, number)) : fallback;
};
const textWidthUnits = glyph => {
  if (/^\s+$/u.test(glyph)) return 0.34;
  if (/[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Extended_Pictographic}]/u.test(glyph)) return 1;
  return /[A-Z0-9]/u.test(glyph) ? 0.65 : 0.57;
};
export function inlineExcalidrawTextLayout(raw, { x, y, width, height }) {
  if (!raw || raw.type !== "text") return null;
  // SVG textContent is inert: even literal <script> remains a glyph.
  const content = boundedTextPrefix(raw.text);
  const fontSize = bounded(raw.fontSize, 1, 320, 20);
  const lineHeight = fontSize * bounded(raw.lineHeight, 0.5, 5, 1.25);
  const ink = /^#[0-9a-fA-F]{6}$/.test(String(raw.strokeColor ?? ""))
    ? String(raw.strokeColor) : "#34343a";
  const opacity = bounded(raw.opacity, 0, 100, 100) / 100;
  const align = raw.textAlign === "center" ? "middle" :
    raw.textAlign === "right" ? "end" : "start";
  const safeWidth = Math.max(1, bounded(width, 1, 12000, 1));
  const safeHeight = Math.max(1, bounded(height, 1, 12000, 1));
  const left = bounded(x, -1000000, 1000000, 0);
  const topY = bounded(y, -1000000, 1000000, 0);
  const maxUnits = Math.max(1, (safeWidth - 6) / fontSize);
  const lines = [];
  for (const paragraph of content.split(/\r\n|\r|\n/)) {
    let fragment = "", units = 0;
    for (const glyph of graphemes(paragraph)) {
      const glyphUnits = textWidthUnits(glyph);
      if (fragment && units + glyphUnits > maxUnits) {
        lines.push(fragment);
        fragment = "";
        units = 0;
        if (lines.length >= 24) break;
      }
      fragment += glyph;
      units += glyphUnits;
    }
    if (lines.length >= 24) break;
    lines.push(fragment);
    if (lines.length >= 24) break;
  }
  const visible = lines.length ? lines : [""];
  const naturalHeight = lineHeight * visible.length;
  const inset = raw.verticalAlign === "middle"
    ? Math.max(3, (safeHeight - naturalHeight) / 2) :
    raw.verticalAlign === "bottom"
      ? Math.max(3, safeHeight - naturalHeight - 3) : 3;
  const anchorX = left + (align === "middle" ? safeWidth / 2 :
    align === "end" ? safeWidth - 3 : 3);
  const degrees = inlineExcalidrawDegrees(raw.angle);
  return {
    lines: visible, fontSize, lineHeight, ink, opacity,
    fontFamily: raw.fontFamily === 3 ? "ui-monospace,monospace" :
      "-apple-system,system-ui,sans-serif",
    anchorX, baselineY: topY + inset + fontSize,
    textAnchor: align,
    rotation: Math.abs(degrees) > 0.0001
      ? "rotate(" + degrees.toFixed(3) + " " +
        (left + safeWidth / 2) + " " + (topY + safeHeight / 2) + ")" : null
  };
}

// Match native UIKit: bound text paints immediately above its container,
// even if serialized after a later occluding shape. The container's
// source order, not the detached label's index, owns its visual layer.
export function orderExcalidrawPaint(list) {
  const indexByID = new Map(list.map((item, index) => [item.raw?.id, index]));
  return list.map((item, index) => {
    const ownerIndex = item.raw?.type === "text"
      ? indexByID.get(item.raw?.containerId) : undefined;
    return { item, z: ownerIndex === undefined ? index :
      ownerIndex + 0.25 };
  }).sort((a, b) => a.z - b.z).map(entry => entry.item);
}
