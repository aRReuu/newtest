import test from "node:test";
import assert from "node:assert/strict";
import { createDiagramRenderGate } from "./render-generation.mjs";

test("older async Mermaid completion cannot replace or report a newer drawing", async () => {
  const gate = createDiagramRenderGate();
  let completeOld;
  const oldWork = new Promise((resolve) => { completeOld = resolve; });
  const events = [];
  const first = gate.begin();
  const stale = oldWork.then(() => { if (gate.isCurrent(first)) events.push("old-ready"); });
  const second = gate.begin();
  assert.equal(gate.isCurrent(first), false);
  assert.equal(gate.isCurrent(second), true);
  events.push("new-ready");
  completeOld();
  await stale;
  assert.deepEqual(events, ["new-ready"]);
});

test("switching Markmap to Mermaid destroys the old live map", () => {
  const gate = createDiagramRenderGate();
  const destroyed = [];
  const first = gate.begin();
  assert.equal(gate.track(first, { destroy() { destroyed.push("first"); } }), true);
  gate.begin();
  assert.deepEqual(destroyed, ["first"]);
});

test("late map creation cannot attach to a different graph request", () => {
  const gate = createDiagramRenderGate();
  const stale = gate.begin();
  const live = gate.begin();
  let staleDestroyed = 0, liveDestroyed = 0;
  assert.equal(gate.track(stale, {destroy() {++staleDestroyed;}}), false);
  assert.equal(gate.track(live, {destroy() {++liveDestroyed;}}), true);
  assert.equal(staleDestroyed, 1);
  assert.equal(liveDestroyed, 0);
  gate.clear();
  assert.equal(liveDestroyed, 1);
});

test("old failure does not supersede current status; disposal exceptions do not wedge rendering", () => {
  const gate = createDiagramRenderGate();
  const old = gate.begin();
  gate.track(old, {destroy() {throw Error("already destroyed");}});
  const current = gate.begin();
  assert.equal(gate.isCurrent(old), false);
  assert.equal(gate.isCurrent(current), true);
  gate.track(current, {destroy() {}});
  gate.clear();
});
