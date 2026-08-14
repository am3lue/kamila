const blessed = require('blessed');
const { theme } = require('./theme');

const PRIORITY_LABELS = { 1: 'Low', 2: 'Medium', 3: 'High', 4: 'Critical' };

class TaskActionOverlay {
  constructor(screen) {
    this.screen = screen;
    this.visible = false;
    this.callbacks = null;
    this.currentTask = null;

    this.box = blessed.box({
      parent: screen,
      top: 'center',
      left: 'center',
      width: 50,
      height: 11,
      label: ' Task Action ',
      border: { type: 'line', fg: theme.accent },
      style: {
        fg: theme.text,
        bg: theme.bg,
        border: { fg: theme.accent },
        label: { fg: theme.accent, bold: true },
      },
      tags: true,
      content: '',
      hidden: true,
    });

    screen.key(['1'], () => {
      if (!this.visible || !this.callbacks?.onComplete) return;
      const cb = this.callbacks.onComplete;
      this.hide();
      cb(this.currentTask);
    });

    screen.key(['2'], () => {
      if (!this.visible || !this.callbacks?.onDelete) return;
      const cb = this.callbacks.onDelete;
      this.hide();
      cb(this.currentTask);
    });

    screen.key(['3'], () => {
      if (!this.visible) return;
      this.hide();
    });
  }

  show(task, callbacks) {
    this.currentTask = task;
    this.callbacks = callbacks;
    this.visible = true;

    const label = PRIORITY_LABELS[task.priority] || 'Unknown';
    this.box.setContent(
      `{bold}${task.title}{/}\n` +
      `Priority: ${label}  |  Est: ${task.estimated_time || '?'}m\n\n` +
      `{bold}[1]{/} ✓ Mark Complete\n` +
      `{bold}[2]{/} ✗ Delete\n` +
      `{bold}[3]{/} Cancel`
    );
    this.box.show();
    this.screen.render();
  }

  hide() {
    this.visible = false;
    this.currentTask = null;
    this.callbacks = null;
    this.box.hide();
    this.screen.render();
  }
}

module.exports = TaskActionOverlay;
