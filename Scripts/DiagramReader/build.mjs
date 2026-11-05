import { build } from "esbuild";
import { cpSync, mkdirSync, readFileSync, writeFileSync, readdirSync } from "node:fs";
import { createHash } from "node:crypto";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..", "..");
const destination = resolve(root, "aReuImpress-iPhone", "Resources", "DiagramReader");
mkdirSync(destination, { recursive: true });
await build({
  entryPoints: [resolve(import.meta.dirname, "host.js")],
  outfile: resolve(destination, "reader.js"),
  bundle: true, platform: "browser", format: "iife", target: ["safari17"],
  minify: true, legalComments: "linked", define: { "process.env.NODE_ENV": '"production"' },
  logLevel: "warning"
});
cpSync(resolve(import.meta.dirname, "index.html"), resolve(destination, "index.html"));
cpSync(resolve(import.meta.dirname, "THIRD_PARTY_LICENSES.txt"),
  resolve(destination, "THIRD_PARTY_LICENSES.txt"));
const manifest = {};
for (const file of ["reader.js", "index.html", "THIRD_PARTY_LICENSES.txt"]) {
  const data = readFileSync(resolve(destination, file));
  manifest[file] = { size: data.byteLength,
    sha256: createHash("sha256").update(data).digest("hex") };
}
manifest.engines = { mermaid: "11.12.2", "markmap-lib": "0.18.12", "markmap-view": "0.18.12" };
manifest.licenses = { mermaid: "MIT", markmap: "MIT", esbuild: "MIT" };
writeFileSync(resolve(destination, "manifest.json"), JSON.stringify(manifest, null, 2) + "\n");
console.log("OFFLINE_DIAGRAM_ASSETS", JSON.stringify(manifest));
// Share the already audited, pinned Mermaid/Markmap runtime with a
// distinct read-only Markdown page; do not install a second graphics engine.
const markdownDestination = resolve(root, "aReuImpress-iPhone", "Resources", "MarkdownReader");
mkdirSync(markdownDestination, { recursive: true });
await build({
  entryPoints: [resolve(import.meta.dirname, "markdown-host.js")],
  outfile: resolve(markdownDestination, "reader.js"),
  bundle: true, platform: "browser", format: "iife", target: ["safari17"],
  minify: true, legalComments: "linked",
  define: { "process.env.NODE_ENV": '"production"' }, logLevel: "warning"
});
cpSync(resolve(import.meta.dirname, "markdown-index.html"),
  resolve(markdownDestination, "index.html"));
// Graph bundles are inert on ordinary notes and load by a same-folder
// script tag only when Mermaid/Markmap is present.
await build({
  entryPoints: [resolve(import.meta.dirname, "markdown-graphs.js")],
  outfile: resolve(markdownDestination, "graphs.js"),
  bundle: true, platform: "browser", format: "iife", target: ["safari17"],
  minify: true, legalComments: "linked",
  define: { "process.env.NODE_ENV": '"production"' }, logLevel: "warning"
});

const markdownLicense = readFileSync(resolve(import.meta.dirname, "THIRD_PARTY_LICENSES.txt"), "utf8") +
  "\n=== MARKDOWN-IT LICENSE (14.1.0) ===\n" +
  readFileSync(resolve(import.meta.dirname, "MARKDOWN_IT_LICENSE.txt"), "utf8") + "\n";
const licensedMarkdown = markdownLicense + "\n=== KATEX LICENSE (0.16.22) ===\n" +
  readFileSync(resolve(import.meta.dirname, "KATEX_LICENSE.txt"), "utf8") + "\n";
writeFileSync(resolve(markdownDestination, "THIRD_PARTY_LICENSES.txt"), licensedMarkdown);
// KaTeX runs entirely offline. WOFF2 is available on the iOS 26 floor,
// avoiding copies of legacy TTF and WOFF variants in a small IPA.
const katexAssets = resolve(import.meta.dirname, "node_modules", "katex", "dist");
cpSync(resolve(katexAssets, "katex.min.css"),
  resolve(markdownDestination, "katex.min.css"));
const localFontDir = resolve(markdownDestination, "fonts");
mkdirSync(localFontDir, { recursive: true });
for (const name of readdirSync(resolve(katexAssets, "fonts"))) {
  if (!name.endsWith(".woff2")) continue;
  cpSync(resolve(katexAssets, "fonts", name), resolve(localFontDir, name));
}
const markdownManifest = {};
for (const name of ["reader.js", "graphs.js", "index.html", "katex.min.css", "THIRD_PARTY_LICENSES.txt"]) {
  const data = readFileSync(resolve(markdownDestination, name));
  markdownManifest[name] = {
    size: data.byteLength, sha256: createHash("sha256").update(data).digest("hex")
  };
}
for (const name of readdirSync(localFontDir).filter((n) => n.endsWith(".woff2"))) {
  const data = readFileSync(resolve(localFontDir, name));
  markdownManifest["fonts/" + name] = {
    size: data.byteLength, sha256: createHash("sha256").update(data).digest("hex")
  };
}
markdownManifest.engines = {
  "markdown-it": "14.1.0", katex: "0.16.22", mermaid: "11.12.2",
  "markmap-lib": "0.18.12", "markmap-view": "0.18.12"
};
markdownManifest.runtimePolicy = "offline-read-only";
writeFileSync(resolve(markdownDestination, "manifest.json"),
  JSON.stringify(markdownManifest, null, 2) + "\n");
console.log("OFFLINE_MARKDOWN_ASSETS", JSON.stringify(markdownManifest));
