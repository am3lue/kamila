const blessed = require('blessed');
const { theme, border, makeBorder, makeBottomBorder } = require('../../theme/TerminalTheme');

class InputEditorModal {
  constructor(screen, app) {
    this.screen = screen;
    this.app = app;
    this.visible = false;
    this.box = null;
    this.editor = null;
    this.onSave = null;
    this.onCancel = null;
    this.originalContent = '';
  }

  open(content = '', onSave, onCancel) {
    this.originalContent = content;
    this.onSave = onSave;
    this.onCancel = onCancel;
    this.visible = true;

    const width = Math.min(this.screen.width - 4, 100);
    const height = Math.min(this.screen.height - 4, 30);
    const top = Math.floor((this.screen.height - height) / 2);
    const left = Math.floor((this.screen.width - width) / 2);

    if (this.box) this.box.destroy();

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
      hidden: true,
      keys: true,
    });

    this.editor = blessed.textarea({
      parent: this.box,
      top: 1,
      left: 1,
      width: '100%-2',
      height: '100%-4',
      style: {
        fg: theme.text,
        bg: theme.bg,
        focus: { fg: theme.text, bg: theme.bg },
      },
      keys: true,
      mouse: true,
      inputOnFocus: true,
      scrollable: true,
      alwaysScroll: true,
      scrollbar: { style: { bg: theme.border } },
    });

    this.editor.setValue(content);
    this._bindKeys();
    this.visible = true;
    this.box.show();
    this.editor.focus();
    this.screen.render();
  }

  _bindKeys() {
    this.editor.key(['C-s'], () => this.save());
    this.editor.key(['C-enter'], () => this.save());
    this.editor.key(['escape'], () => this.cancel());
    this.editor.key(['C-c'], () => this.cancel());
  }

  save() {
    const content = this.editor.getValue();
    this.hide();
    if (this.onSave) this.onSave(content);
  }

  cancel() {
    this.hide();
    if (this.onCancel) this.onCancel(this.originalContent);
  }

  hide() {
    this.visible = false;
    if (this.box) {
      this.box.hide();
      this.box.destroy();
      this.box = null;
      this.editor = null;
    }
    this.screen.render();
  }
}

module.exports = { InputEditorModal };