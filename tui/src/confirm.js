const blessed = require('blessed');
const { theme } = require('./theme');

/**
 * ConfirmOverlay — modal shown when the bridge emits a `confirm_request`
 * (the agent wants to run a shell command). User answers y/N (or ! to force);
 * the answer is sent back to the bridge as a `confirm_response`.
 */
class ConfirmOverlay {
  constructor(screen) {
    this.screen = screen;
    this.visible = false;
    this.pending = null;
    this.onAnswer = null;

    this.box = blessed.box({
      parent: screen,
      top: 'center',
      left: 'center',
      width: 76,
      height: 11,
      label: ' Confirmation Required ',
      border: { type: 'line', fg: theme.yellow },
      style: {
        fg: theme.text,
        bg: theme.bg,
        border: { fg: theme.yellow },
        label: { fg: theme.yellow, bold: true },
      },
      tags: true,
      content: '',
      hidden: true,
      keys: true,
      inputOnFocus: false,
    });

    this.box.key(['y', 'Y'], () => {
      if (!this.visible || !this.pending) return;
      this.respond(true);
    });

    this.box.key(['n', 'N'], () => {
      if (!this.visible || !this.pending) return;
      this.respond(false);
    });

    this.box.key(['!'], () => {
      if (!this.visible || !this.pending) return;
      this.respond(true, true);
    });

    this.box.key(['escape'], () => {
      if (!this.visible || !this.pending) return;
      this.respond(false);
    });
  }

  show(msg) {
    this.pending = { id: msg.id, command: msg.command, description: msg.description, rule: msg.rule };
    const lines = [
      'The agent wants to run a shell command:',
      '',
      `  {bold}${this.pending.command}{/}`,
    ];
    if (this.pending.description) {
      lines.push('', `  Purpose: ${this.pending.description}`);
    }
    if (this.pending.rule) {
      lines.push('', `  Policy: ${this.pending.rule}`);
    }
    lines.push('', '{yellow-fg}Allow? [y]es / [N]o / [!] force{/}');
    this.box.setContent(lines.join('\n'));
    this.visible = true;
    this.box.show();
    this.box.focus();
    this.screen.render();
  }

  respond(allow, force = false) {
    const cb = this.pending;
    this.hide();
    this.onAnswer && this.onAnswer({ id: cb.id, allow, force });
  }

  hide() {
    this.visible = false;
    this.pending = null;
    this.box.hide();
  }
}

module.exports = ConfirmOverlay;
