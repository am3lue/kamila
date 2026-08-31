const blessed = require('blessed');
const { theme, border, makeTitle, makeBorder, makeBottomBorder, translateTags } = require('../../theme/TerminalTheme');

const KIND_STYLE = {
  info: theme.accent,
  success: theme.success,
  warn: theme.warning,
  error: theme.error,
  notif: theme.accent,
};

class ToastStack {
  constructor(screen, app) {
    this.screen = screen;
    this.app = app;
    this.toasts = [];
    this.container = null;
    this.dismissTimers = new Map();
  }

  _ensureContainer() {
    if (this.container) return;
    this.container = blessed.box({
      parent: this.screen,
      bottom: 6,
      right: 1,
      width: 44,
      height: 1,
      tags: true,
      hidden: true,
      style: { fg: theme.text, bg: theme.bg },
    });
  }

  _reflow() {
    this._ensureContainer();
    const n = this.toasts.length;
    if (n === 0) {
      this.container.setContent('');
      this.container.hide();
      this.screen.render();
      return;
    }
    const height = Math.min(n * 3 + 1, this.screen.height - 4);
    this.container.height = height;
    this.container.setContent(this.toasts.map(t => translateTags(t.text)).join('\n'));
    this.container.show();
    this.screen.render();
  }

  _dismiss(id) {
    const idx = this.toasts.findIndex(t => t.id === id);
    if (idx === -1) return;
    const [removed] = this.toasts.splice(idx, 1);
    if (removed && removed.onDismiss) removed.onDismiss();
    this._reflow();
  }

  push(message, opts = {}) {
    this._ensureContainer();
    const kind = opts.kind || 'info';
    const color = KIND_STYLE[kind] || theme.accent;
    const seconds = opts.duration != null ? opts.duration : 4;
    const id = Date.now() + '-' + Math.random().toString(36).slice(2, 6);

    const lines = [];
    if (opts.title) lines.push(`{${color}-fg}${makeTitle(opts.title)}{/}`);
    const body = String(message).split('\n');
    lines.push(body.map(l => ` {${color}-fg}│{/} ${l}`).join('\n'));
    lines.push(` {textDim}${opts.hint || `dismiss: esc · auto ${seconds}s`}{/}`);

    const text = lines.join('\n');

    this.toasts.push({ id, text, onDismiss: opts.onDismiss });
    if (this.toasts.length > 4) {
      const dropped = this.toasts.shift();
      if (dropped && dropped.onDismiss) dropped.onDismiss();
    }

    const timer = setTimeout(() => {
      this.dismissTimers.delete(id);
      this._dismiss(id);
    }, seconds * 1000);
    this.dismissTimers.set(id, timer);

    this._reflow();
    return id;
  }

  dismiss(id) {
    const timer = this.dismissTimers.get(id);
    if (timer) {
      clearTimeout(timer);
      this.dismissTimers.delete(id);
    }
    this._dismiss(id);
  }

  clear() {
    for (const timer of this.dismissTimers.values()) clearTimeout(timer);
    this.dismissTimers.clear();
    this.toasts = [];
    this._reflow();
  }
}

module.exports = { ToastStack };