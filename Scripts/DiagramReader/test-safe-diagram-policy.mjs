import test from "node:test";
import assert from "node:assert/strict";
import { MAX_GRAPH_SOURCE_CHARACTERS, boundedGraphSource,
  sanitizeMermaidSource } from "./safe-diagram-policy.mjs";

test("Mermaid init directives and interaction callbacks never reach either renderer", () => {
  const source = `flowchart LR\n%%{init: {"securityLevel":"loose"}}%%\n  A[中文 🧠] --> B[Safe]\n  click A "https://example.invalid/private"\n`;
  const safe = sanitizeMermaidSource(source);
  assert.match(safe, /A\[中文 🧠\]/);
  assert.doesNotMatch(safe, /init:|securityLevel|click A|example\.invalid/);
});

test("Mermaid and Markmap share strict character budget and do not truncate input", () => {
  const atLimit = "a".repeat(MAX_GRAPH_SOURCE_CHARACTERS);
  assert.equal(boundedGraphSource(atLimit), atLimit);
  assert.equal(sanitizeMermaidSource(atLimit), atLimit);
  assert.throws(() => boundedGraphSource(atLimit + "b"), /source budget/);
  assert.throws(() => sanitizeMermaidSource(atLimit + "b"), /source budget/);
  assert.equal(boundedGraphSource("# 标题\n- 内容"), "# 标题\n- 内容");
});

test("Mermaid directive stripping does not discard adjacent source lines", () => {
  const source = 'A-->B\n%%{init: {"flowchart": {"htmlLabels": true}}}%%\nB-->C';
  assert.equal(sanitizeMermaidSource(source), "A-->B\n\nB-->C");
});
