const blessed = require('blessed');
const { TerminalBox } = require('./TerminalBox');
const { theme } = require('../theme/TerminalTheme');

class HeaderBar {
  constructor(screen, regionManager, app) {
    this.screen = screen;
    this.regionManager = regionManager;
    this.app = app;
    this.box = null;
    this.mode = 'chat';
  }

  create() {
    const region = this.regionManager.get('header');
    if (!region) return;

    this.box = new TerminalBox({
      parent: this.screen,
      top: region.y,
      left: region.x,
      width: region.width,
      height: region.height,
      role: 'header',
      title: '',
      tags: true,
    }).create();

    this.render();
    return this.box;
  }

  setMode(mode) {
    this.mode = mode;
    this.render();
  }

  render() {
    if (!this.box) return;
    const modeColors = { chat: 'green', plan: 'yellow', test: 'magenta', execute: 'red' };
    const color = modeColors[this.mode] || 'green';
    const modeStr = this.mode.toUpperCase();
    const left = ` KAMILA v0.2.0 ─ {${color}-fg}●{/} {bold}${modeStr} `;
    const right = ` Ctrl+P:Palette  F5:Refresh  F10:Logs  F11:Perms  Ctrl+T:Panels `;
    const padding = ' '.repeat(Math.max(1, this.box.width - left.length - right.length));
    this.box.setContent(`${left}${padding}${right}`);
    this.screen.render();
  }

  onResize() {
    this.render();
  }
}

module.exports = { HeaderBar };