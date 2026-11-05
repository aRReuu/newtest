// Read-only, offline Mermaid/Markmap source policy shared by both readers.
// An oversized or directive-bearing note must never weaken renderer limits.
export const MAX_GRAPH_SOURCE_CHARACTERS = 200000;

export function boundedGraphSource(source) {
  const text = String(source ?? "");
  if (text.length > MAX_GRAPH_SOURCE_CHARACTERS) {
    throw new Error("Offline graph exceeds source budget");
  }
  return text;
}

export function sanitizeMermaidSource(source) {
  return boundedGraphSource(source)
    .replace(/%%\{[\s\S]*?\}%%/g, "")
    .replace(/^\s*click\s+.*$/gm, "");
}
