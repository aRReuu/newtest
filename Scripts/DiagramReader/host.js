import mermaid from "mermaid";
import { Transformer } from "markmap-lib";
import { Markmap } from "markmap-view";
import { boundedGraphSource, sanitizeMermaidSource } from "./safe-diagram-policy.mjs";
import { createDiagramRenderGate } from "./render-generation.mjs";

const viewport = document.getElementById("diagram");
const status = document.getElementById("status");
const safeText = (value) => String(value || "").replaceAll("&", "&amp;")
  .replaceAll("<", "&lt;").replaceAll(">", "&gt;");
const renderGate = createDiagramRenderGate();

async function renderDiagram(request, ticket) {
  if (!renderGate.isCurrent(ticket)) return;
  const kind = request?.kind;
  const raw = boundedGraphSource(request?.source);
  if (!["mermaid", "markmap"].includes(kind)) {
    throw new Error("Invalid local diagram scope");
  }
  viewport.replaceChildren();
  status.textContent = "";
  if (kind === "mermaid") {
    mermaid.initialize({
      startOnLoad: false, securityLevel: "strict", theme: request.dark ? "dark" : "default",
      suppressErrorRendering: true, maxTextSize: 200000,
      flowchart: { htmlLabels: false, useMaxWidth: false }
    });
    // Read-only screen projection: directives and click callbacks cannot
    // override the host's trusted renderer/security configuration.
    const sanitized = sanitizeMermaidSource(raw);
    const result = await mermaid.render("impress-mermaid-" + Math.random().toString(36).slice(2),
      sanitized);
    // Theme/source changes may supersede a still-running Mermaid promise.
    // A stale result must never replace the newer graph or report success.
    if (!renderGate.isCurrent(ticket)) return;
    const holder = document.createElement("div");
    holder.className = "mermaid-result";
    holder.innerHTML = result.svg;
    viewport.append(holder);
    viewport.querySelectorAll("a").forEach((link) => {
      const text = document.createElement("span");
      text.textContent = link.textContent;
      link.replaceWith(text);
    });
    return;
  }
  // Raw HTML is inert; the original Markdown bytes remain in the Vault.
  const transformer = new Transformer();
  const parsed = transformer.transform(safeText(raw));
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("id", "mindmap");
  svg.setAttribute("width", "100%");
  svg.setAttribute("height", "100%");
  viewport.append(svg);
  const map = Markmap.create(svg, { duration: 0, autoFit: true, maxWidth: 280 }, parsed.root);
  if (!renderGate.track(ticket, map)) return;
  if (map && typeof map.fit === "function") await map.fit();
}
window.renderImpressDiagram = (request) => {
  // Re-rendering on light/dark changes is legal while previous async
  // Mermaid/Markmap work is still pending; latest request owns the view.
  const ticket = renderGate.begin();
  Promise.resolve().then(() => renderDiagram(request, ticket)).then(() => {
    if (!renderGate.isCurrent(ticket)) return;
    status.textContent = "";
    window.webkit?.messageHandlers?.diagramState?.postMessage({ state: "ready" });
  }).catch((error) => {
    if (!renderGate.isCurrent(ticket)) return;
    renderGate.clear();
    viewport.replaceChildren();
    status.textContent = "Diagram could not render safely: " + String(error?.message || "unknown");
    window.webkit?.messageHandlers?.diagramState?.postMessage({ state: "failed" });
  });
};