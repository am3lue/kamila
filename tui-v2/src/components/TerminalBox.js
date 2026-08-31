const blessed = require('blessed');
const { theme, border, makeTitle, styleFor, translateTags } = require('../theme/TerminalTheme');

class TerminalBox {
  constructor(opts = {}) {
    this.opts = {
      parent: opts.parent,
      title: opts.title || '',
      role: opts.role || 'panel',
      top: opts.top || 0,
      left: opts.left || 0,
      width: opts.width || '100%',
      height: opts.height || '100%',
      content: opts.content || '',
      tags: opts.tags !== false,
      mouse: opts.mouse !== false,
      keys: opts.keys || false,
      scrollable: opts.scrollable || false,
      alwaysScroll: opts.alwaysScroll || false,
      scrollbar: opts.scrollbar || { style: { bg: theme.border } },
      style: styleFor(opts.role),
      border: { type: opts.borderType || 'line', fg: theme.border },
      hidden: opts.hidden || false,
      padding: opts.padding || 0,
    };

    this.box = null;
    this._contentLines = [];
    this._renderedTitle = '';
    this._baseBorderFg = theme.border;
    this._borderType = this.opts.border.type || 'line';
  }

  create() {
    const style = { ...this.opts.style };
    if (this.opts.role === 'header') {
      style.fg = theme.bg;
      style.bg = theme.accent;
    }

    const borderOpts = { ...this.opts.border };
    const styleOpts = { ...style };
    if (this.opts.role === 'header' || this.opts.role === 'status') {
      borderOpts.type = 'line';
      borderOpts.fg = theme.bg;
      styleOpts.padding = { left: 1, right: 1 };
      styleOpts.border = undefined;
    }

    const labelOpts = {};
    if (this.opts.title) {
      labelOpts.label = {
        text: makeTitle(this.opts.title),
        side: 'left',
        style: { fg: theme.accent },
      };
    }

    const boxOpts = {
      parent: this.opts.parent,
      top: this.opts.top,
      left: this.opts.left,
      width: this.opts.width,
      height: this.opts.height,
      content: this.opts.content,
      tags: this.opts.tags,
      mouse: this.opts.mouse,
      keys: this.opts.keys,
      scrollable: this.opts.scrollable,
      alwaysScroll: this.opts.alwaysScroll,
      scrollbar: this.opts.scrollbar,
      padding: this.opts.padding,
      style: styleOpts,
      ...labelOpts,
      hidden: this.opts.hidden,
    };
    if (this.opts.role === 'header' || this.opts.role === 'status') {
      boxOpts.border = false;
    } else {
      boxOpts.border = borderOpts;
    }

    this.box = blessed.box(boxOpts);

    this.box.on('resize', () => this._updateBorder());
    this._updateBorder();
    return this.box;
  }

  setFocusBorder(focused) {
    if (!this.box) return;
    const fg = focused ? theme.accent : this._baseBorderFg;
    this.box.style.border.fg = fg;
    this.box.border.type = focused ? 'double' : this._borderType;
    this.box.screen.render();
  }

  setBorderType(type) {
    this._borderType = type;
    if (this.box) this.box.border.type = type;
  }

  _updateBorder() {
    if (!this.box) return;
    const w = this.box.width || this.opts.width;
    const title = this.opts.title;
    if (typeof w === 'number' && w > 4) {
      this._renderedTitle = title;
    }
  }

  setTitle(title) {
    this.opts.title = title;
    this._updateBorder();
    this.render();
  }

  setContent(content) {
    if (this.box) this.box.setContent(translateTags(content));
  }

  getContent() {
    return this.box ? this.box.getContent() : '';
  }

  show() {
    if (this.box) this.box.show();
  }

  hide() {
    if (this.box) this.box.hide();
  }

  focus() {
    if (this.box) this.box.focus();
  }

  on(event, handler) {
    if (this.box) this.box.on(event, handler);
  }

  render() {
    if (this.box) this.box.render();
  }

  getScreen() {
    return this.box ? this.box.screen : null;
  }

  get width() {
    return this.box ? this.box.width : 0;
  }

  get height() {
    return this.box ? this.box.height : 0;
  }

  get top() {
    return this.box ? this.box.top : 0;
  }

  get left() {
    return this.box ? this.box.left : 0;
  }
}

module.exports = { TerminalBox };