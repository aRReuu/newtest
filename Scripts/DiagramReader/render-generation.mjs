// Per-view async render ownership. Old Mermaid promises and Markmap fit() must
// never replace a newer read-only graph or report a stale render as "ready".
export function createDiagramRenderGate() {
  let generation = 0;
  let active = null;
  const dispose = (value) => {
    if (typeof value?.destroy === "function") {
      try { value.destroy(); } catch (_) { /* stale renderer already detached */ }
    }
  };
  return {
    begin() {
      ++generation;
      dispose(active);
      active = null;
      return generation;
    },
    isCurrent(ticket) { return ticket === generation; },
    track(ticket, renderer) {
      if (ticket !== generation) {
        dispose(renderer);
        return false;
      }
      dispose(active);
      active = renderer;
      return true;
    },
    clear() {
      dispose(active);
      active = null;
    }
  };
}
