// Deterministic, offline-only geometry used by the read-only inline SVG preview.
// Never trusts authored angles, crops, or image dimensions as executable input.
import { inlineArrowheadGeometry } from "./inline-excalidraw-geometry.mjs";
import { inlineExcalidrawTextLayout } from "./inline-excalidraw-text.mjs";
import { inlineExcalidrawRadians } from "./inline-excalidraw-angle.mjs";
const finite = value => typeof value === "number" && Number.isFinite(value);
const boundedGeometry = value => finite(value) && value > 0 && value <= 12000;

export function inlineExcalidrawBounds(element) {
  if (!element || ![element.x, element.y, element.w, element.h].every(finite) ||
      !boundedGeometry(element.w) || !boundedGeometry(element.h)) return null;
  // Match the exact normalized angle used by the SVG painter and text.
  const theta = inlineExcalidrawRadians(element.raw?.angle);
  const cosine = Math.cos(theta), sine = Math.sin(theta);
  const horizontal = Math.abs(cosine) * element.w / 2 +
    Math.abs(sine) * element.h / 2;
  const vertical = Math.abs(sine) * element.w / 2 +
    Math.abs(cosine) * element.h / 2;
  const cx = element.x + element.w / 2;
  const cy = element.y + element.h / 2;
  const bounds = { minX: cx - horizontal, minY: cy - vertical,
    maxX: cx + horizontal, maxY: cy + vertical };
  const includeRotated = (sourceX, sourceY) => {
    const x = sourceX - cx, y = sourceY - cy;
    const rotatedX = cx + x * cosine - y * sine;
    const rotatedY = cy + x * sine + y * cosine;
    if (!finite(rotatedX) || !finite(rotatedY)) return false;
    bounds.minX = Math.min(bounds.minX, rotatedX);
    bounds.minY = Math.min(bounds.minY, rotatedY);
    bounds.maxX = Math.max(bounds.maxX, rotatedX);
    bounds.maxY = Math.max(bounds.maxY, rotatedY);
    return true;
  };

  // Text with explicit breaks or a large authored font may paint below its
  // serialized element height. Frame bounds must include the very same
  // bounded ink projection used by the SVG text painter, before rotation.
  if (element.raw?.type === "text") {
    const layout = inlineExcalidrawTextLayout(element.raw, {
      x: element.x, y: element.y, width: element.w, height: element.h
    });
    if (!layout) return null;
    if (layout.lines.some(line => line.length > 0)) {
      const inkTop = layout.baselineY - layout.fontSize;
      const inkBottom = layout.baselineY +
        (layout.lines.length - 1) * layout.lineHeight + layout.fontSize * 0.35;
      // Non-ASCII shaping/emoji may overhang the nominal text box.
      const horizontalMargin = layout.fontSize * 2;
      for (const [x, y] of [
        [element.x - horizontalMargin, inkTop],
        [element.x + element.w + horizontalMargin, inkTop],
        [element.x - horizontalMargin, inkBottom],
        [element.x + element.w + horizontalMargin, inkBottom]
      ]) {
        if (!includeRotated(x, y)) return null;
      }
    }
  }

  // Excalidraw freehand, line and arrow points are relative to element.x/y.
  // They can extend outside its serialized width/height, including negatives.
  // Match the SAME first 1200 points the SVG renderer actually draws, then
  // rotate about its element center before computing the SVG viewBox.
  if (["line", "arrow", "freedraw"].includes(element.raw?.type) &&
      Array.isArray(element.raw.points)) {
    const points = element.raw.points.slice(0, 1200);
    if (points.some(p => !Array.isArray(p) || p.length < 2 ||
        !finite(p[0]) || !finite(p[1]))) return null;
    for (const [localX, localY] of points) {
      if (!includeRotated(element.x + localX, element.y + localY)) return null;
    }
    if (element.raw.type === "arrow" && points.length >= 2) {
      const sourceStroke = element.raw.strokeWidth == null ? 1.5 : Number(element.raw.strokeWidth);
      const strokeWidth = Number.isFinite(sourceStroke) ?
        Math.min(20, Math.max(0.5, sourceStroke)) : 1.5;
      const heads = [
        [element.raw.startArrowhead, points[0], points[1]],
        [element.raw.endArrowhead, points[points.length - 1], points[points.length - 2]]
      ];
      for (const [style, tip, neighbor] of heads) {
        const geometry = inlineArrowheadGeometry(style,
          [element.x + tip[0], element.y + tip[1]],
          [element.x + neighbor[0], element.y + neighbor[1]], strokeWidth);
        if (!geometry) continue; // Unpainted malformed/unsupported arrowheads.
        const b = geometry.extent;
        // Rotate the painted geometry's enclosing box, including circular arcs.
        for (const [x,y] of [[b.minX,b.minY],[b.minX,b.maxY],
                              [b.maxX,b.minY],[b.maxX,b.maxY]]) {
          if (!includeRotated(x,y)) return null;
        }
      }
    }
  }
  return Object.values(bounds).every(finite) ? bounds : null;
}

export function inlineExcalidrawFrame(list, padding = 32) {
  if (!Array.isArray(list) || !list.length || list.length > 350 ||
      !finite(padding) || padding < 0 || padding > 128) return null;
  const bounds = list.map(inlineExcalidrawBounds);
  if (bounds.some(item => !item)) return null;
  const minX = Math.min(...bounds.map(b => b.minX));
  const minY = Math.min(...bounds.map(b => b.minY));
  const maxX = Math.max(...bounds.map(b => b.maxX));
  const maxY = Math.max(...bounds.map(b => b.maxY));
  const width = maxX - minX + padding * 2;
  const height = maxY - minY + padding * 2;
  if (!finite(width) || !finite(height) || width <= 0 || height <= 0 ||
      width > 12000 || height > 12000 || width * height > 20000000) return null;
  return { width, height, dx: padding - minX, dy: padding - minY };
}

export function inlineExcalidrawImagePlacement(element, bitmap, width, height) {
  if (!element || !bitmap || !boundedGeometry(width) || !boundedGeometry(height) ||
      !boundedGeometry(bitmap.width) || !boundedGeometry(bitmap.height)) return null;
  const scale = element.scale == null ? [1, 1] : element.scale;
  if (!Array.isArray(scale) || scale.length !== 2 ||
      !scale.every(value => value === 1 || value === -1)) return null;
  const flipX = scale[0], flipY = scale[1];
  if (element.crop == null) return {
    x: 0, y: 0, width, height, flipX, flipY,
    // Official Excalidraw SVG exports keep the embedded PNG/JPEG aspect
    // ratio (SVG image default xMidYMid meet). Stretching a natural 318×335
    // bitmap into a 100×100 element was distorting all four official
    // rotated/mirrored image fixtures. A crop intentionally fills its box.
    preserveAspectRatio: "xMidYMid meet"
  };
  const crop = element.crop;
  if (!crop || typeof crop !== "object" || Array.isArray(crop)) return null;
  const values = [crop.x, crop.y, crop.width, crop.height,
    crop.naturalWidth, crop.naturalHeight];
  if (!values.every(finite) || crop.x < 0 || crop.y < 0 ||
      crop.width <= 0 || crop.height <= 0 ||
      crop.naturalWidth !== bitmap.width || crop.naturalHeight !== bitmap.height ||
      crop.x + crop.width > bitmap.width + 1e-6 ||
      crop.y + crop.height > bitmap.height + 1e-6) return null;
  const scaleX = width / crop.width, scaleY = height / crop.height;
  const placement = { x: -crop.x * scaleX, y: -crop.y * scaleY,
    width: bitmap.width * scaleX, height: bitmap.height * scaleY,
    flipX, flipY, preserveAspectRatio: "none" };
  if (!Object.entries(placement).every(([key, value]) =>
      key === "preserveAspectRatio" || finite(value)) ||
      placement.width > 60000 || placement.height > 60000) return null;
  return placement;
}
