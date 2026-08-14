const blessed = require('blessed');
const { theme } = require('./theme');

class LogPanel {
  constructor(screen, logBuffer) {
    this.screen = screen;
    this.logBuffer = logBuffer;
    this.visible = false;

    this.box = blessed.box({
      parent: screen,
      top: 'center',
      left: 'center',
      width: '70%',
      height: '70%',
      label: ' Kamila Logs ',
      border: { type: 'line', fg: theme.accent },
      style: {
        fg: theme.text,
        bg: theme.bg,
        border: { fg: theme.accent },
        label: { fg: theme.accent, bold: true },
      },
      tags: true,
      scrollable: true,
      alwaysScroll: true,
      mouse: true,
      scrollbar: { style: { bg: theme.subtle } },
      content: '',
      hidden: true,
    });

    this.helpLine = blessed.box({
      parent: screen,
      bottom: 3,
      left: 'center',
      width: '30%',
      height: 1,
      align: 'center',
      style: { fg: theme.textDim, bg: theme.bg },
      content: 'F10:Toggle  Esc:Close  ↑↓:Scroll',
      hidden: true,
    });
  }

  toggle() {
    this.visible = !this.visible;
    if (this.visible) {
      this.refresh();
    }
    this.box[this.visible ? 'show' : 'hide']();
    this.helpLine[this.visible ? 'show' : 'hide']();
    this.screen.render();
  }

  refresh() {
    const entries = this.logBuffer.getAll();
    if (entries.length === 0) {
      this.box.setContent('{#a8a8a8-fg}No log entries yet.{/}');
    } else {
      const lines = entries.map(e => {
        const colorMap = { CHAT: 'cyan', CMD: 'yellow', ERR: 'red', SYS: '#a8a8a8' };
        const c = colorMap[e.type] || 'white';
        return `{${c}-fg}[${e.time}] [${e.type}]{/} ${e.msg}`;
      });
      this.box.setContent(lines.join('\n'));
      this.box.setScrollPerc(100);
    }
  }
}

module.exports = LogPanel;
