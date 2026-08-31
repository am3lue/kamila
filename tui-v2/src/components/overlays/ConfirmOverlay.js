const blessed = require('blessed');
const { theme, border, makeBorder, makeBottomBorder, translateTags } = require('../../theme/TerminalTheme');

class ConfirmOverlay {
  constructor(screen) {
    this.screen = screen;
    this.visible = false;
    this.box = null;
    this.pending = null;
    this.onAnswer = null;
  }

  static show(screen, opts) {
    const overlay = new ConfirmOverlay(screen);
    overlay.show(opts);
    return overlay;
  }

  show({ message, command, description, rule, onConfirm }) {
    this.pending = { message, command, description, rule };
    this.onAnswer = onConfirm;
    this.visible = true;

    const width = 76;
    const height = 13;
    const top = Math.floor((this.screen.height - height) / 2);
    const left = Math.floor((this.screen.width - width) / 2);

    if (this.box) this.box.destroy();

    this.box = blessed.box({
      parent: this.screen,
      top,
      left,
      width,
      height,
      border: { type: 'line', fg: theme.warning },
      style: {
        fg: theme.text,
        bg: theme.surface,
        border: { fg: theme.warning },
      },
      tags: true,
      hidden: true,
      keys: true,
    });

    const lines = [
      '  The agent wants to run a shell command:',
      '',
      `    {bold}${this.pending.command}{/}`,
    ];
    if (this.pending.description) {
      lines.push('', `    Purpose: ${this.pending.description}`);
    }
    if (this.pending.rule) {
      lines.push('', `    Policy: ${this.pending.rule}`);
    }
    lines.push('', '  {yellow-fg}[Y]es  [N]o  [!] Force  [Esc] Cancel{/}');

    this.box.setContent(translateTags(lines.join('\n')));
    this._bindKeys();
    this.visible = true;
    this.box.show();
    this.box.focus();
    this.screen.render();
  }

  _bindKeys() {
    this.box.key(['y', 'Y'], () => this.respond(true));
    this.box.key(['n', 'N'], () => this.respond(false));
    this.box.key(['!'], () => this.respond(true, true));
    this.box.key(['escape'], () => this.respond(false));
  }

  respond(allow, force = false) {
    const cb = this.onAnswer;
    this.hide();
    if (cb) cb({ allow, force });
  }

  hide() {
    this.visible = false;
    this.pending = null;
    if (this.box) {
      this.box.hide();
      this.box.destroy();
      this.box = null;
    }
    this.screen.render();
  }
}

module.exports = { ConfirmOverlay };