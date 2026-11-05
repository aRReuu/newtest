// One trusted orientation rule for source-number angles across the read-only
// inline painter, painted text and conservative SVG viewBox geometry.
// Excalidraw stores radians as numbers; malformed strings are not angles.
const TAU = 2 * Math.PI;
export function inlineExcalidrawRadians(value) {
  if (typeof value !== "number" || !Number.isFinite(value)) return 0;
  const theta = value % TAU;
  return Object.is(theta, -0) ? 0 : theta;
}
export function inlineExcalidrawDegrees(value) {
  return inlineExcalidrawRadians(value) * 180 / Math.PI;
}
