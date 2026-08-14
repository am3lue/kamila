const blessed = require('blessed');
const path = require('path');
const KamilaBridge = require('./src/bridge');
const SplashScreen = require('./src/splash');
const KamilaApp = require('./src/app');

const JULIA_PROJECT_DIR = path.resolve(__dirname, '..');

async function main() {
  const bridge = new KamilaBridge();

  // Create screen with splash
  const screen = blessed.screen({
    smartCSR: true,
    title: 'Kamila v0.2.0',
    cursor: { artificial: true, blink: true, color: '#33b1ff' },
    dockBorders: true,
    fullUnicode: true,
  });
  screen.enableMouse();

  const splash = new SplashScreen(screen);
  splash.show('Starting Julia backend…');

  const t1 = setTimeout(() => splash.updateStatus('Compiling modules…'), 800);
  const t2 = setTimeout(() => splash.updateStatus('Connecting…'), 2500);

  try {
    await bridge.start(JULIA_PROJECT_DIR);
    clearTimeout(t1);
    clearTimeout(t2);
    splash.updateStatus('Ready!');
  } catch (e) {
    clearTimeout(t1);
    clearTimeout(t2);
    splash.updateStatus(`Failed: ${e.message}`);
    setTimeout(() => process.exit(1), 2500);
    return;
  }

  const app = new KamilaApp(bridge, screen);
  setTimeout(() => splash.hide(), 400);

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
