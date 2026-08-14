// markdown.test.js — renderMessage unit tests (node:test)
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { renderMessage, stripTags, escapeBraces, wrapTagged } = require('../src/markdown');

test('escapeBraces protects blessed tags in user text', () => {
  assert.equal(escapeBraces('a{b}c'), 'a\\{b\\}c');
  assert.equal(stripTags('{yellow-fg}hi{/}'), 'hi');
});

test('wrapTagged wraps a long line to width', () => {
  const long = 'word '.repeat(30).trim(); // ~150 chars
  const wrapped = wrapTagged(long, 40).split('\n');
  assert.ok(wrapped.length > 1);
  assert.ok(wrapped.every(l => l.length <= 40));
});

test('renderMessage user message has <You> header and escaped body', () => {
  const lines = renderMessage({ id: 1, role: 'user', label: 'You', text: 'hi {x}', status: 'done', expanded: false, kind: 'text' }, { time: '10:00', width: 60 });
  const content = lines.join('\n');
  assert.match(content, /\[10:00\]/);
  assert.match(content, /<You>:/);
  assert.match(content, /hi/);
  assert.match(content, /\\\{x\\\}/);
});

test('renderMessage assistant renders markdown and joins first line to header', () => {
  const msg = { id: 2, role: 'assistant', label: 'Kamila', text: '**bold**\nsecond', status: 'done', expanded: false, kind: 'text' };
  const lines = renderMessage(msg, { time: '10:00', width: 60 });
  assert.match(lines[0], /<Kamila>:/);
  assert.match(lines.join('\n'), /\{bold\}bold\{\/\}/);
  assert.equal(lines.length, 2);
});

test('renderMessage shows elapsed tag on completion and streaming cursor while streaming', () => {
  const base = { id: 3, role: 'assistant', label: 'Kamila', text: 'answer', expanded: false, kind: 'text' };
  const done = renderMessage(Object.assign({}, base, { status: 'done', elapsed: '1.5s' }), { width: 60 }).join('\n');
  assert.match(done, /\(1\.5s\)/);
  const streaming = renderMessage(Object.assign({}, base, { status: 'streaming' }), { width: 60 }).join('\n');
  assert.match(streaming, /⟳/);
});

test('renderMessage thinking collapsed shows header, expanded shows dimmed body', () => {
  const collapsed = renderMessage({ id: 4, role: 'assistant', label: 'Kamila', text: 'reasoning', kind: 'thinking', expanded: false, status: 'done' }, { time: '10:00', width: 60 });
  assert.match(collapsed.join('\n'), /🧠 Thinking…/);
  const expanded = renderMessage({ id: 4, role: 'assistant', label: 'Kamila', text: 'reasoning', kind: 'thinking', expanded: true, status: 'done' }, { time: '10:00', width: 60 });
  assert.match(expanded.join('\n'), /reasoning/);
  assert.doesNotMatch(expanded.join('\n'), /Thinking…/);
});

test('renderMessage system and tool messages render plainly', () => {
  const sys = renderMessage({ id: 5, role: 'system', label: 'System', text: 'note', kind: 'text', status: 'done', expanded: false }, { time: '10:00', width: 60 });
  assert.match(sys.join('\n'), /note/);
  const tool = renderMessage({ id: 6, role: 'tool', label: 'tool', text: '⚡ read_file', kind: 'tool', status: 'done', expanded: false }, { width: 60 });
  assert.match(tool.join('\n'), /⚡ read_file/);
});
