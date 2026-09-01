const test = require('node:test');
const assert = require('node:assert');
const { KamilaApp } = require('../../src/app/KamilaApp');

function makeApp() {
  const app = Object.create(KamilaApp.prototype);
  app.uiState = {
    state: { voiceRecording: false },
    get(k) { return this.state[k]; },
    set(k, v) { this.state[k] = v; },
  };
  app.voiceIndicator = {
    cancelled: false,
    cancel() { this.cancelled = true; },
  };
  app.chatInput = {
    active: false,
    focused: false,
    hintValue: null,
    setHint(h) { this.hintValue = h; },
    focus() { this.focused = true; },
  };
  app.screen = { rendered: false, render() { this.rendered = true; } };
  app._appendChat = (m) => { app.lastAppend = m; };
  app.commandPalette = { visible: false, hide() { app.hidden = 'palette'; } };
  app.logPanel = { visible: false, hide() { app.hidden = 'log'; } };
  app.permissionPanel = { visible: false, hide() { app.hidden = 'perm'; } };
  app.inputEditorModal = { visible: false, hide() { app.hidden = 'editor'; } };
  app.taskActionOverlay = { visible: false, hide() { app.hidden = 'task'; } };
  app.toastStack = { toasts: [], clear() { app.hidden = 'toast'; } };
  app.bridge = { stopped: false, stop() { app.bridge.stopped = true; } };
  return app;
}

test('Esc while voice is recording cancels, does NOT quit', () => {
  const app = makeApp();
  app.uiState.set('voiceRecording', true);
  const realExit = process.exit;
  let exited = false;
  process.exit = () => { exited = true; };
  try {
    app._dismissOverlays();
  } finally {
    process.exit = realExit;
  }
  assert.strictEqual(exited, false, 'must not call process.exit');
  assert.strictEqual(app.voiceIndicator.cancelled, true, 'indicator cancelled');
  assert.strictEqual(app.bridge.stopped, false, 'bridge must not stop');
  assert.strictEqual(app._voiceCancelled, true, 'late promise result ignored');
  assert.strictEqual(app.uiState.get('voiceRecording'), false);
});

test('cancel sets the flag that gates late promise results', () => {
  const app = makeApp();
  app._voiceCancelled = false;
  app._cancelVoiceRecord();
  assert.strictEqual(app._voiceCancelled, true, '_voiceCancelled set');
  assert.strictEqual(app.voiceIndicator.cancelled, true);
  assert.strictEqual(app.uiState.get('voiceRecording'), false);
  assert.strictEqual(app.chatInput.focused, true, 'focus returned to input');
});

test('Esc with no recording still quits (existing behavior preserved)', () => {
  const app = makeApp();
  app.uiState.set('voiceRecording', false);
  const realExit = process.exit;
  let exited = false;
  process.exit = () => { exited = true; };
  try {
    app._dismissOverlays();
  } finally {
    process.exit = realExit;
  }
  assert.strictEqual(exited, true, 'quit path preserved');
});

test('Esc while composing in the input never quits (guards Shift+Enter crash)', () => {
  const app = makeApp();
  app.uiState.set('voiceRecording', false);
  app.chatInput.active = true;  // user is typing in the input
  const realExit = process.exit;
  let exited = false;
  process.exit = () => { exited = true; };
  try {
    app._dismissOverlays();
  } finally {
    process.exit = realExit;
  }
  assert.strictEqual(exited, false, 'must not quit while input active');
  assert.strictEqual(app.bridge.stopped, false, 'bridge not stopped');
});

test('Esc while input active still dismisses open overlays', () => {
  const app = makeApp();
  app.chatInput.active = true;
  app.commandPalette.visible = true;
  const realExit = process.exit;
  let exited = false;
  process.exit = () => { exited = true; };
  try {
    app._dismissOverlays();
  } finally {
    process.exit = realExit;
  }
  assert.strictEqual(app.hidden, 'palette', 'palette dismissed');
  assert.strictEqual(exited, false);
});

test('quitApp cancels recording instead of quitting', () => {
  const app = makeApp();
  app.uiState.set('voiceRecording', true);
  const realExit = process.exit;
  let exited = false;
  process.exit = () => { exited = true; };
  try {
    app.quitApp();
  } finally {
    process.exit = realExit;
  }
  assert.strictEqual(exited, false, 'must not quit mid-recording');
  assert.strictEqual(app._voiceCancelled, true, 'recording cancelled');
  assert.strictEqual(app.bridge.stopped, false, 'bridge not stopped');
});

test('quitApp quits when not recording', () => {
  const app = makeApp();
  app.uiState.set('voiceRecording', false);
  const realExit = process.exit;
  let exited = false;
  process.exit = () => { exited = true; };
  try {
    app.quitApp();
  } finally {
    process.exit = realExit;
  }
  assert.strictEqual(exited, true, 'quits when idle');
  assert.strictEqual(app.bridge.stopped, true);
});
