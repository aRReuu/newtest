"use strict";

// Offline, dependency-free contract tests for the JavaScript that actually
// executes inside DeepSeek's WKWebView. These do not claim live-site E2E PASS.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const source = fs.readFileSync(path.join(__dirname, "../../aReuImpress-iPhone/VC/SubVCs/ImWebVC/ImWebViewController.swift"), "utf8");
function body(named) {
  const startToken = "static let " + named + ' = #"""';
  const start = source.indexOf(startToken);
  assert.ok(start >= 0, "missing bridge body " + named);
  const first = start + startToken.length;
  const end = source.indexOf('"""#', first);
  assert.ok(end > first, "unterminated bridge " + named);
  return source.slice(first, end);
}
const insert = body("insert");
const send = body("send");
assert.ok(!insert.includes("fetch(") && !insert.includes("form.submit("),
  "insertion must never send a message");
assert.ok(!send.includes("fetch("), "sending must click an existing UI control");

function fakeEnvironment(options = {}) {
  let clicks = 0;
  const events = [];
  class MockEvent { constructor(type) { this.type = type; } }
  class MockInputEvent extends MockEvent {}
  class MockTextArea {
    constructor() {
      this._value = "";
      this.tagName = "TEXTAREA";
      this.isContentEditable = false;
      this.parentElement = null;
    }
    get value() { return this._value; }
    set value(v) { this._value = v; }
    getBoundingClientRect() { return { width: 300, height: 64, bottom: 720 }; }
    closest() { return null; }
    getAttribute() { return null; }
    dispatchEvent(e) { events.push(e.type); return true; }
    focus() {}
    querySelectorAll() { return []; }
  }
  class MockInput {}
  const editor = options.editableDiv ? {
    tagName: "DIV", isContentEditable: true, innerText: "", textContent: "",
    getBoundingClientRect: () => ({ width: 300, height: 64, bottom: 720 }),
    closest: () => null, focus() {},
    querySelectorAll: () => []
  } : new MockTextArea();
  const button = {
    disabled: !!options.disabled, getAttribute: () => null,
    getBoundingClientRect: () => ({ width: 40, height: 40, bottom: 720 }),
    matches: selector => selector === 'button[type="submit"]',
    click: () => { clicks++; }
  };
  const container = {
    parentElement: null,
    querySelectorAll: () => options.noSendButton ? [] : [button]
  };
  editor.parentElement = container;
  const document = {
    querySelectorAll: () => options.noEditor ? [] : [editor],
    createRange: () => ({ selectNodeContents() {} }),
    execCommand: (_command, _ui, value) => {
      editor.innerText = value;
      return true;
    }
  };
  const context = {
    payload: "", append: false,
    document, HTMLTextAreaElement: MockTextArea, HTMLInputElement: MockInput,
    location: { protocol: "https:", hostname: options.hostname || "chat.deepseek.com" },
    getComputedStyle: () => ({ display: "block", visibility: "visible" }),
    InputEvent: MockInputEvent, Event: MockEvent,
    window: { getSelection: () => ({ removeAllRanges() {}, addRange() {} }) }
  };
  return { context, editor, events, countClicks: () => clicks };
}
function run(jsBody, environment, args = {}) {
  Object.assign(environment.context, args);
  return vm.runInNewContext("(function() {" + jsBody + "\n})()", environment.context,
    { timeout: 500 });
}
let env = fakeEnvironment();
let result = run(insert, env, { payload: "第一段", append: false });
assert.equal(result.ok, true);
assert.equal(env.editor.value, "第一段");
assert.deepEqual(env.events, ["input", "change"]);
assert.equal(env.countClicks(), 0, "write must not send");
result = run(insert, env, { payload: "Second paragraph", append: true });
assert.equal(result.ok, true);
assert.equal(env.editor.value, "第一段\nSecond paragraph");
assert.equal(env.countClicks(), 0);
result = run(send, env);
assert.equal(result.ok, true);
assert.equal(env.countClicks(), 1, "one explicit send must cause one click");

env = fakeEnvironment({ disabled: true });
run(insert, env, { payload: "draft", append: false });
assert.equal(run(send, env).ok, false);
assert.equal(env.countClicks(), 0);

env = fakeEnvironment({ noEditor: true });
assert.equal(run(insert, env, { payload: "draft" }).ok, false);
assert.equal(run(send, env).ok, false);

env = fakeEnvironment({ hostname: "phishing.example" });
assert.equal(run(insert, env, { payload: "private" }).reason, "untrusted_origin");
assert.equal(run(send, env).reason, "untrusted_origin");

env = fakeEnvironment({ noSendButton: true });
run(insert, env, { payload: "draft" });
assert.equal(run(send, env).reason, "send_control_not_found");

env = fakeEnvironment({ editableDiv: true });
result = run(insert, env, { payload: "contenteditable draft", append: false });
assert.equal(result.ok, true);
assert.equal(env.editor.innerText, "contenteditable draft");
assert.equal(env.countClicks(), 0);

console.log("DeepSeek bridge offline tests PASS: React setter, append, explicit send, origin, disabled, missing editor, contenteditable");
