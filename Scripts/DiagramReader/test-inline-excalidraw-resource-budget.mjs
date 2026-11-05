import test from 'node:test';
import assert from 'node:assert/strict';
import {
  inlineExcalidrawResourceBudget,
  MAX_INLINE_EXCALIDRAW_DOCUMENT_PIXELS as MAX_PIXELS,
  MAX_INLINE_EXCALIDRAW_DOCUMENT_URL_CHARS as MAX_CHARS
} from './inline-excalidraw-resource-budget.mjs';
const bitmap = (width, height, encodedChars = 100) =>
  ({width, height, href: 'x'.repeat(encodedChars)});

test('same drawing repeated in separate Markdown fences shares one memory quota', () => {
  const document = inlineExcalidrawResourceBudget();
  assert.equal(document.reserve(bitmap(3000, 3000)), true);
  assert.equal(document.reserve(bitmap(3000, 3000)), false,
    'a second otherwise valid 9 MP decoded bitmap exceeds a 16 MP document');
  assert.equal(document.reserve(bitmap(2000, 2000)), true);
  assert.equal(document.pixels, 13_000_000);
  assert.equal(document.characters, 200);
});

test('many small sprites across Markdown fences cannot exceed total encoded byte cap', () => {
  const document = inlineExcalidrawResourceBudget();
  for (let index = 0; index < 8; index++)
    assert.equal(document.reserve(bitmap(1, 1, 500_000)), true);
  assert.equal(document.reserve(bitmap(1, 1, 1)), false);
  assert.equal(document.characters, MAX_CHARS);
  assert.equal(document.pixels, 8);
});

test('limits are inclusive and rejected images do not consume quota', () => {
  const document = inlineExcalidrawResourceBudget();
  for (const invalid of [null, {}, {width:0,height:8,href:'a'},
    {width:Infinity,height:1,href:'a'}, {width:1,height:1},
    {width:1,height:1,href:''},
    {width:1.5,height:2,href:'a'},
    {width:Number.MAX_SAFE_INTEGER,height:10,href:'x'}]) {
    assert.equal(document.reserve(invalid),false);
  }
  assert.equal(document.pixels, 0);
  assert.equal(document.characters, 0);
  assert.equal(document.reserve(bitmap(4000,4000)),true);
  assert.equal(document.pixels, MAX_PIXELS);
  assert.equal(document.reserve(bitmap(1,1)),false);
});

test('each independent document render starts with a fresh per-document budget', () => {
  const oldDocument = inlineExcalidrawResourceBudget();
  assert.equal(oldDocument.reserve(bitmap(4000,4000)),true);
  const newDocument = inlineExcalidrawResourceBudget();
  assert.equal(newDocument.pixels,0);
  assert.equal(newDocument.reserve(bitmap(1280,720)),true);
});
