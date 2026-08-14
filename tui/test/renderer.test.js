// renderer.test.js — ChatRenderer unit tests (node:test)
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { MessageStore } = require('../src/messages');
const { ChatRenderer } = require('../src/renderer');

function renderAll(store, r = new ChatRenderer(), width = 60) {
  return r.render(store, { width, time: () => '12:34' });
}

test('renders each message once and joins lines with newline', () => {
  const store = new MessageStore();
  store.add('user', 'hello');
  store.add('assistant', 'world');
  const { content, lineMap } = renderAll(store);
  assert.equal(lineMap.length, 2);
  assert.match(content, /<You>/);
  assert.match(content, /<Kamila>/);
});

test('lineMap maps every content line back to a message id', () => {
  const store = new MessageStore();
  const u = store.add('user', 'line1\nline2');
  const a = store.add('assistant', 'hello\nworld\nagain');
  const { lineMap } = renderAll(store);
  assert.ok(lineMap.length >= 5);
  assert.equal(store.find(lineMap[0]), u);
  assert.equal(store.find(lineMap[lineMap.length - 1]), a);
});

test('streaming message re-renders every pass (not cached frozen)', () => {
  const store = new MessageStore();
  const r = new ChatRenderer();
  store.add('user', 'hi');
  const s = store.beginStream('assistant');
  const c1 = renderAll(store, r).content;
  s.text += 'Hello';
  const c2 = renderAll(store, r).content;
  s.text += ' world';
  const c3 = renderAll(store, r).content;
  assert.match(c1, /<Kamila>:/);
  assert.match(c2, /Hello/);
  assert.match(c3, /Hello world/);
  assert.notEqual(c2, c3);
});

test('done message is cached — identical renders short-circuit', () => {
  const store = new MessageStore();
  const r = new ChatRenderer();
  store.add('user', 'hi');
  store.add('assistant', 'fixed answer');
  const a = renderAll(store, r).content;
  const b = renderAll(store, r).content;
  assert.equal(a, b);
  // Cache entries: user + assistant messages.
  assert.equal(r.cache.size, 2);
});

test('finish triggers re-render with elapsed tag', () => {
  const store = new MessageStore();
  const r = new ChatRenderer();
  store.add('user', 'hi');
  const s = store.beginStream('assistant');
  s.text += 'done text';
  const mid = renderAll(store, r).content;
  store.finish(s.id, { elapsed: '2.3s' });
  const fin = renderAll(store, r).content;
  assert.match(fin, /\(2\.3s\)/);
  assert.doesNotMatch(fin, /⟳/);
  assert.notEqual(mid, fin);
});

test('thinking collapsed vs expanded vs line mapping', () => {
  const store = new MessageStore();
  const r = new ChatRenderer();
  const th = store.add('assistant', 'deep reasoning', { kind: 'thinking' });
  const collapsed = renderAll(store, r).content;
  assert.match(collapsed, /Thinking…/);
  th.expanded = true;
  const expanded = renderAll(store, r).content;
  assert.match(expanded, /deep reasoning/);
  assert.doesNotMatch(expanded, /Thinking…/);
});

test('clear() resets the cache', () => {
  const store = new MessageStore();
  const r = new ChatRenderer();
  store.add('user', 'hi');
  renderAll(store, r);
  assert.equal(r.cache.size, 1);
  r.clear();
  assert.equal(r.cache.size, 0);
});

test('invalidate(id) drops only that message from the cache', () => {
  const store = new MessageStore();
  const r = new ChatRenderer();
  store.add('user', 'hi');
  const a = store.add('assistant', 'answer');
  renderAll(store, r);
  assert.equal(r.cache.size, 2);
  r.invalidate(a.id);
  assert.equal(r.cache.size, 1);
});
