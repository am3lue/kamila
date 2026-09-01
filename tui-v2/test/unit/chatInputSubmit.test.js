const test = require('node:test');
const assert = require('node:assert');
const { ChatInput } = require('../../src/components/ChatInput');

function makeInput() {
  const input = Object.create(ChatInput.prototype);
  input.value = '';
  input.cursor = 0;
  input.recallRing = [];
  input.recallIndex = -1;
  input.active = true;
  input.hint = '';
  input.screen = { render() {} };
  input.app = {};
  // Stub rendering/deps so _onKey can run without a blessed screen.
  input._render = () => {};
  input._afterEdit = () => {};
  input._maybeGrow = () => {};
  input.focus = () => {};
  input.clearValue = () => { input.value = ''; input.cursor = 0; };
  input._insert = (text) => {
    input.value = input.value.slice(0, input.cursor) + text + input.value.slice(input.cursor);
    input.cursor += text.length;
  };
  input._submit = () => { input.submitted = input.value; };
  return input;
}

const key = (name, extra = {}) => ({
  name,
  full: '',
  ctrl: false,
  meta: false,
  shift: false,
  ...extra,
});

test('plain Enter submits the current value', () => {
  const input = makeInput();
  input.value = 'hello world';
  input.cursor = input.value.length;
  input._onKey(null, key('enter'));
  assert.strictEqual(input.submitted, 'hello world', 'onSubmit path called with value');
});

test('plain return submits too', () => {
  const input = makeInput();
  input.value = 'hi';
  input.cursor = 2;
  input._onKey(null, key('return'));
  assert.strictEqual(input.submitted, 'hi');
});

test('Shift-Enter inserts a newline and does not submit', () => {
  const input = makeInput();
  input.value = 'line';
  input.cursor = 4;
  input._onKey(null, key('enter', { shift: true }));
  assert.strictEqual(input.value, 'line\n', 'newline inserted');
  assert.strictEqual(input.submitted, undefined, 'not submitted');
});

test('Ctrl-Enter inserts a newline (kept as multiline escape)', () => {
  const input = makeInput();
  input.value = 'a';
  input.cursor = 1;
  input._onKey(null, key('enter', { ctrl: true }));
  assert.strictEqual(input.value, 'a\n');
  assert.strictEqual(input.submitted, undefined);
});

test('Alt-Enter inserts a newline', () => {
  const input = makeInput();
  input.value = 'x';
  input.cursor = 1;
  input._onKey(null, key('enter', { meta: true }));
  assert.strictEqual(input.value, 'x\n');
});

test('typing ordinary characters inserts them', () => {
  const input = makeInput();
  input._onKey('k', key('k'));
  assert.strictEqual(input.value, 'k');
});

test('C-c with a value clears instead of quitting', () => {
  const input = makeInput();
  input.value = 'abc';
  input.cursor = 3;
  let quit = false;
  input.app.quitApp = () => { quit = true; };
  input._onKey(null, key('c', { ctrl: true, full: 'C-c' }));
  assert.strictEqual(input.value, '');
  assert.strictEqual(quit, false);
});
