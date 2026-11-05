import mermaid from "mermaid";
import { Transformer } from "markmap-lib";
import { Markmap } from "markmap-view";
import { boundedGraphSource, sanitizeMermaidSource } from "./safe-diagram-policy.mjs";

function removeRemoteLinks(container) {
  for (const link of container.querySelectorAll("a")) {
    const node = document.createElement("span");
    node.textContent = link.textContent || "";
    link.replaceWith(node);
  }
}
window.ImpressMarkdownGraphics = {
  async drawMermaid(container, source, dark, id) {
    mermaid.initialize({
      startOnLoad: false, securityLevel: "strict",
      theme: dark ? "dark" : "default", suppressErrorRendering: true,
      maxTextSize: 200000,
      flowchart: { htmlLabels: false, useMaxWidth: false }
    });
    const result = await mermaid.render("im-read-graph-" + id,
      sanitizeMermaidSource(source));
    container.replaceChildren();
    const mount = document.createElement("div");
    mount.innerHTML = result.svg;
    removeRemoteLinks(mount);
    container.append(mount);
  },
  async drawMarkmap(container, source) {
    const transformer = new Transformer();
    const transformed = transformer.transform(boundedGraphSource(source));
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    container.replaceChildren(svg);
    const map = Markmap.create(svg, {
      duration: 0, autoFit: true, maxWidth: 280
    }, transformed.root);
    if (map?.fit) await map.fit();
    removeRemoteLinks(container);
    return map;
  }
};
