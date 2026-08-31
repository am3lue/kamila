const blessed = require('blessed');
const path = require('path');
const { BridgeClient } = require('./bridge/BridgeClient');
const { KamilaApp } = require('./app/KamilaApp');

const JULIA_PROJECT_DIR = path.resolve(__dirname, '..', '..');

async function main() {
  const bridge = new BridgeClient();

  const screen = blessed.screen({
    smartCSR: true,
    title: 'Kamila v0.2.0',
    cursor: { artificial: true, blink: true, color: '#00d7ff' },
    dockBorders: true,
    fullUnicode: true,
  });
  screen.enableMouse();

  // Build the full UI immediately; the backend connects in the background.
  const app = new KamilaApp(bridge, screen);
  app.setStatusHint('{yellow-fg}Starting Julia backend…{/}');
  screen.render();

  bridge.start(JULIA_PROJECT_DIR)
    .then(() => app.onBackendReady())
    .catch((e) => app.onBackendError(e));

  process.on('SIGINT', () => {
    bridge.stop();
    process.exit(0);
  });

  process.on('SIGTERM', () => {
    bridge.stop();
    process.exit(0);
  });
}

main().catch((e) => {
  console.error('Fatal error:', e);
  process.exit(1);
});