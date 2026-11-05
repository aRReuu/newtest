// Bounded per-document quota for source-embedded read-only PNG/JPEG drawings.
// The same local file may appear in many drawing elements and Markdown fences;
// each painted instance is conservatively charged to protect iPhone memory.
// No file bytes, Vault identity, network URL, or user text is retained here.
export const MAX_INLINE_EXCALIDRAW_DOCUMENT_PIXELS = 16_000_000;
export const MAX_INLINE_EXCALIDRAW_DOCUMENT_URL_CHARS = 4_000_000;

export function inlineExcalidrawResourceBudget() {
  let reservedPixels = 0;
  let reservedURLChars = 0;
  return {
    reserve(bitmap) {
      const w = bitmap?.width, h = bitmap?.height;
      const chars = bitmap?.href?.length;
      if (!Number.isInteger(w) || !Number.isInteger(h) ||
          w <= 0 || h <= 0 || !Number.isSafeInteger(w * h) ||
          !Number.isSafeInteger(chars) || chars <= 0 ||
          reservedPixels + w * h > MAX_INLINE_EXCALIDRAW_DOCUMENT_PIXELS ||
          reservedURLChars + chars > MAX_INLINE_EXCALIDRAW_DOCUMENT_URL_CHARS)
        return false;
      reservedPixels += w * h;
      reservedURLChars += chars;
      return true;
    },
    get pixels() { return reservedPixels; },
    get characters() { return reservedURLChars; }
  };
}
