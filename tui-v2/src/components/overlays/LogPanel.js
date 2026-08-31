const blessed = require('blessed');
const { theme, border, makeBorder, makeBottomBorder, translateTags } = require('../../theme/TerminalTheme');

const LEVEL_COLORS = { debug: 'textDim', info: 'cyan', warn: 'yellow', error: 'red', fatal: 'red' };
const FILTERS = ['all', 'error', 'warn', 'info', 'debug'];

class LogPanel {
  constructor(screen, logBuffer) {
    this.screen = screen;
    this.logBuffer = logBuffer;
    this.visible = false;
    this.box = null;
    this.helpLine = null;
    this.filter = 'all';
  }

  create() {
    const width = Math.min(this.screen.width - 4, 110);
    const height = Math.min(this.screen.height - 4, 30);
    const top = Math.floor((this.screen.height - height) / 2);
    const left = Math.floor((this.screen.width - width) / 2);

    this.box = blessed.box({
      parent: this.screen,
      top,
      left,
      width,
      height,
      border: { type: 'line', fg: theme.accent },
      style: {
        fg: theme.text,
        bg: theme.surface,
        border: { fg: theme.accent },
      },
      tags: true,
      scrollable: true,
      alwaysScroll: true,
      mouse: true,
      scrollbar: { style: { bg: theme.border } },
      hidden: true,
    });

    this.helpLine = blessed.box({
      parent: this.screen,
      bottom: top + height + 1,
      left: left,
      width,
      height: 1,
      align: 'center',
      style: { fg: theme.textMuted, bg: theme.bg },
      content: 'F10:Toggle  Esc:Close  ↑↓:Scroll  F:Filter',
      hidden: true,
    });

    this.box.key(['escape'], () => this.hide());
    this.box.key(['f', 'F'], () => this._cycleFilter());
    return this;
  }

  _cycleFilter() {
    const idx = FILTERS.indexOf(this.filter);
    this.filter = FILTERS[(idx + 1) % FILTERS.length];
    this.refresh();
  }

  toggle() {
    this.visible = !this.visible;
    if (this.visible) {
      if (!this.box) this.create();
      this.refresh();
      this.box.show();
      this.helpLine.show();
    } else {
      this.box.hide();
      this.helpLine.hide();
    }
    this.screen.render();
  }

  hide() {
    this.visible = false;
    if (this.box) this.box.hide();
    if (this.helpLine) this.helpLine.hide();
    this.screen.render();
  }

  refresh() {
    if (!this.box) return;
    const entries = this.logBuffer.getAll();
    if (entries.length === 0) {
      this.box.setContent('{#a8a8a8-fg}No log entries yet.{/}');
    } else {
      const lines = entries
        .filter(e => this.filter === 'all' || e.level === this.filter)
        .map(e => {
          const c = LEVEL_COLORS[e.level] || 'white';
          const lvl = (e.level || 'info').toUpperCase().padEnd(5);
          return `{${c}-fg}[${e.time}] [${lvl}]{/} {textDim}[${e.origin || '?'}:${e.kind || 'log'}]{/} ${e.msg}`;
        });
      const header = `Filter: {accent-fg}${this.filter}{/}`;
      this.box.setContent(translateTags(`${header}\n${lines.join('\n')}`));
      this.box.setScrollPerc(100);
    }
    this.screen.render();
  }
}

module.exports = { LogPanel };