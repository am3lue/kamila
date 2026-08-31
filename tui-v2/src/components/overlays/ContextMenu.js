const blessed = require('blessed');
const { theme, border, makeBorder, makeBottomBorder, translateTags } = require('../../theme/TerminalTheme');

class ContextMenu {
  constructor(screen) {
    this.screen = screen;
    this.box = null;
    this.visible = false;
    this.items = [];
    this.selectedIndex = 0;
    this.callback = null;
  }

  show(x, y, items, callback) {
    this.items = items;
    this.callback = callback;
    this.selectedIndex = 0;

    const maxWidth = Math.max(...items.map(i => i.label.length)) + 8;
    const width = Math.min(maxWidth, 50);
    const height = items.length + 4;

    if (this.box) this.box.destroy();

    this.box = blessed.box({
      parent: this.screen,
      top: Math.min(y, this.screen.height - height - 2),
      left: Math.min(x, this.screen.width - width - 2),
      width,
      height,
      border: { type: 'line', fg: theme.accent },
      style: {
        fg: theme.text,
        bg: theme.surface,
        border: { fg: theme.accent },
        selected: { bg: theme.accent, fg: theme.bg, bold: true },
      },
      tags: true,
      hidden: true,
      keys: true,
      vi: true,
    });

    this._render();
    this._bindKeys();
    this.visible = true;
    this.box.show();
    this.box.focus();
    this.screen.render();
  }

  _render() {
    if (!this.box) return;
    let content = '';
    this.items.forEach((item, i) => {
      const prefix = i === this.selectedIndex ? '► ' : '  ';
      const shortcut = item.shortcut ? ` {textDim}(${item.shortcut}){/}` : '';
      const style = i === this.selectedIndex ? '{black-fg}{cyan-bg}' : '';
      const endStyle = i === this.selectedIndex ? '{/}' : '';
      content += `${style}${prefix}${item.label}${shortcut}${endStyle}\n`;
    });
    this.box.setContent(translateTags(content.trim()));
  }

  _bindKeys() {
    if (!this.box) return;
    this.box.key(['up', 'k'], () => {
      this.selectedIndex = (this.selectedIndex - 1 + this.items.length) % this.items.length;
      this._render();
      this.screen.render();
    });
    this.box.key(['down', 'j'], () => {
      this.selectedIndex = (this.selectedIndex + 1) % this.items.length;
      this._render();
      this.screen.render();
    });
    this.box.key(['enter', ' '], () => {
      const item = this.items[this.selectedIndex];
      this.hide();
      if (item.action) item.action();
      if (this.callback) this.callback(item);
    });
    this.box.key(['escape', 'q', 'C-c'], () => this.hide());
  }

  hide() {
    if (this.box) {
      this.visible = false;
      this.box.hide();
      this.box.destroy();
      this.box = null;
      this.items = [];
      this.callback = null;
      this.screen.render();
    }
  }

  static show(screen, x, y, items, callback) {
    const menu = new ContextMenu(screen);
    menu.show(x, y, items, callback);
    return menu;
  }
}

module.exports = { ContextMenu };