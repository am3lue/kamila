const blessed = require('blessed');
const { theme, border, makeBorder, makeBottomBorder, translateTags } = require('../../theme/TerminalTheme');

class TaskActionOverlay {
  constructor(screen) {
    this.screen = screen;
    this.visible = false;
    this.box = null;
    this.currentTask = null;
    this.callbacks = null;
  }

  show(task, callbacks) {
    this.currentTask = task;
    this.callbacks = callbacks;
    this.visible = true;

    const width = 50;
    const height = 12;
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

    const PRIORITY_LABELS = { 1: 'Low', 2: 'Medium', 3: 'High', 4: 'Critical' };
    const label = PRIORITY_LABELS[task.priority] || 'Unknown';

    this.box.setContent(
      translateTags(
        `{bold}${task.title}{/}\n` +
        `Priority: ${label}  |  Est: ${task.estimated_time || '?'}m\n\n` +
        `{bold}[1]{/} ✓ Mark Complete\n` +
        `{bold}[2]{/} ✗ Delete\n` +
        `{bold}[3]{/} Cancel`
      )
    );

    this._bindKeys();
    this.visible = true;
    this.box.show();
    this.box.focus();
    this.screen.render();
  }

  _bindKeys() {
    this.box.key(['1'], () => {
      if (!this.visible || !this.callbacks?.onComplete) return;
      const cb = this.callbacks.onComplete;
      this.hide();
      cb(this.currentTask);
    });
    this.box.key(['2'], () => {
      if (!this.visible || !this.callbacks?.onDelete) return;
      const cb = this.callbacks.onDelete;
      this.hide();
      cb(this.currentTask);
    });
    this.box.key(['3', 'escape'], () => {
      if (!this.visible) return;
      this.hide();
    });
  }

  hide() {
    this.visible = false;
    this.currentTask = null;
    this.callbacks = null;
    if (this.box) {
      this.box.hide();
      this.box.destroy();
      this.box = null;
    }
    this.screen.render();
  }
}

module.exports = { TaskActionOverlay };