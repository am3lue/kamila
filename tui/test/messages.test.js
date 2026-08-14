// messages.test.js — MessageStore unit tests (node:test)
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { MessageStore } = require('../src/messages');

test('add appends messages with stable ids and labels', () => {
  const store = new MessageStore();
  const u = store.add('user', 'hi');
  const a = store.add('assistant', 'hello');
  assert.equal(u.id, 1);
  assert.equal(a.id, 2);
  assert.equal(u.label, 'You');
  assert.equal(a.label, 'Kamila');
  assert.equal(store.count(), 2);
});

test('find returns the message or undefined', () => {
  const store = new MessageStore();
  const u = store.add('user', 'hi');
  assert.equal(store.find(u.id), u);
  assert.equal(store.find(999), undefined);
});

test('remove splices the message out', () => {
  const store = new MessageStore();
  const u = store.add('user', 'hi');
  store.add('assistant', 'hello');
  store.remove(u.id);
  assert.equal(store.count(), 1);
  assert.equal(store.find(u.id), undefined);
});

test('clear empties the store', () => {
  const store = new MessageStore();
  store.add('user', 'a');
  store.add('assistant', 'b');
  store.clear();
  assert.equal(store.count(), 0);
});

test('beginStream marks a message as streaming', () => {
  const store = new MessageStore();
  const s = store.beginStream('assistant');
  assert.equal(s.status, 'streaming');
  store.appendText(s.id, 'part1');
  store.appendText(s.id, 'part2');
  assert.equal(s.text, 'part1part2');
});

test('finish transitions streaming -> done and sets elapsed/model', () => {
  const store = new MessageStore();
  const s = store.beginStream('assistant');
  store.finish(s.id, { elapsed: '1.2s', model: 'kamila1' });
  assert.equal(s.status, 'done');
  assert.equal(s.elapsed, '1.2s');
  assert.equal(s.model, 'kamila1');
});

test('finish can flag an error', () => {
  const store = new MessageStore();
  const s = store.beginStream('assistant');
  store.finish(s.id, { error: 'boom' });
  assert.equal(s.status, 'error');
  assert.equal(s.error, 'boom');
});

test('last / lastOfRole', () => {
  const store = new MessageStore();
  store.add('user', 'a');
  const a = store.add('assistant', 'b');
  assert.equal(store.last(), a);
  assert.equal(store.lastOfRole('user').text, 'a');
  assert.equal(store.lastOfRole(['assistant']), a);
});

test('toggleThinking flips expansion only on thinking messages', () => {
  const store = new MessageStore();
  const th = store.add('assistant', 'think', { kind: 'thinking' });
  const txt = store.add('assistant', 'answer');
  store.toggleThinking(th.id);
  assert.equal(th.expanded, true);
  store.toggleThinking(th.id);
  assert.equal(th.expanded, false);
  store.toggleThinking(txt.id);
  assert.equal(txt.expanded, false);
});

test('hydrate imports role/content/created_at rows', () => {
  const store = new MessageStore();
  store.hydrate([
    { role: 'user', content: 'q', created_at: '2026-01-01T00:00:00Z' },
    { role: 'assistant', content: 'a', created_at: '' },
    { role: 'system', content: 'ignored-role', created_at: '' },
  ]);
  assert.equal(store.count(), 3);
  assert.equal(store.list()[0].role, 'user');
  assert.equal(store.list()[0].text, 'q');
  assert.equal(store.list()[2].role, 'user'); // non assistant/user -> user
});
