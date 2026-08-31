const blessed = require('blessed');
const { theme, border, makeBorder, makeBottomBorder, translateTags } = require('../../theme/TerminalTheme');

class PermissionPanel {
  constructor(screen, bridge) {
    this.screen = screen;
    this.bridge = bridge;
    this.visible = false;
    this.box = null;
    this.input = null;
    this.policy = null;
  }

  create() {
    const width = Math.min(this.screen.width - 4, 90);
    const height = Math.min(this.screen.height - 4, 35);
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
      hidden: true,
      keys: true,
    });

    this.input = blessed.textbox({
      parent: this.box,
      bottom: 2,
      left: 2,
      width: '90%',
      height: 1,
      label: ' Allow command (pattern): ',
      border: { type: 'line', fg: theme.subtle },
      style: { fg: theme.text, bg: theme.surface, border: { fg: theme.subtle } },
      hidden: true,
      keys: true,
    });

    this.input.key(['escape'], () => this.input.hide());
    this.input.key('enter', () => {
      const cmd = this.input.getValue().trim();
      this.input.clearValue();
      this.input.hide();
      if (cmd) this.addAllowRule(cmd);
      else this.refresh();
      this.screen.render();
    });

    this.box.key(['escape'], () => this.hide());
    this.box.key(['a', 'A'], () => { this.input.show(); this.input.focus(); this.screen.render(); });
    this.box.key(['d', 'D'], () => this.toggleDefault());
    this.box.key(['r', 'R'], () => this.reset());

    return this;
  }

  async open() {
    if (!this.box) this.create();
    this.visible = true;
    this.box.show();
    this.screen.render();
    await this.refresh();
  }

  hide() {
    this.visible = false;
    if (this.box) this.box.hide();
    if (this.input) this.input.hide();
    this.screen.render();
  }

  async refresh() {
    this.box.setContent('{cyan-fg}Loading policy...{/}');
    this.screen.render();
    try {
      const pol = await this.bridge.permissionGet();
      const dec = await this.bridge.permissionDecisions(10);
      this.policy = pol.policy || {};
      this.render(this.policy, dec.decisions || []);
    } catch (e) {
      this.box.setContent(`{${theme.error}-fg}Failed to load policy: ${e.message}{/}`);
      this.screen.render();
    }
  }

  render(policy, decisions) {
    const rules = policy.rules || [];
    const def = policy.default_action || 'ask';
    const lines = ['{bold}Permission Policy{/}', '', '{bold}Rules:{/}'];
    if (rules.length === 0) {
      lines.push('  {textDim}(none){/}');
    } else {
      rules.forEach((r, i) => {
        const color = r.action === 'allow' ? theme.success : r.action === 'deny' ? theme.error : theme.warning;
        const scope = r.scope || 'pattern';
        lines.push(`  ${i + 1}. {${color}-fg}${r.action}{/} ${r.tool || '*'}:${r.match || '*'} (${scope})`);
      });
    }
    lines.push(
      '',
      `Default action: {bold}${def}{/}    Session remember: ${policy.session_remember ? 'on' : 'off'}`,
      '',
      '{bold}Recent decisions:{/}'
    );
    const decLines = decisions.map(d => {
      const color = d.action === 'allow' ? theme.success : d.action === 'deny' ? theme.error : theme.warning;
      return `  ${d.ts} {${color}-fg}${d.action}{/} ${d.tool} "${d.target}"`;
    });
    lines.push(...(decLines.length ? decLines : ['  {textDim}(none yet){/}']));
    lines.push(
      '',
      '{textDim}[A] Add allow  [D] Toggle default  [R] Reset  [Esc] Close{/}'
    );
    this.box.setContent(translateTags(lines.join('\n')));
    this.screen.render();
  }

  async addAllowRule(cmd) {
    try {
      const rules = [...(this.policy.rules || [])];
      rules.unshift({ tool: 'run_shell_command', match: cmd, action: 'allow', scope: 'pattern' });
      await this.bridge.permissionSet({ ...this.policy, rules });
    } catch (e) {
      this.box.setContent(`Failed to save policy: ${e.message}`);
      this.screen.render();
      return;
    }
    await this.refresh();
  }

  async toggleDefault() {
    try {
      const order = ['ask', 'allow', 'deny'];
      const cur = this.policy.default_action || 'ask';
      this.policy.default_action = order[(order.indexOf(cur) + 1) % order.length];
      await this.bridge.permissionSet(this.policy);
    } catch (e) {
      this.box.setContent(`Failed to save policy: ${e.message}`);
      this.screen.render();
      return;
    }
    await this.refresh();
  }

  async reset() {
    try {
      await this.bridge.permissionReset();
    } catch (e) {
      this.box.setContent(`Failed to reset policy: ${e.message}`);
      this.screen.render();
      return;
    }
    await this.refresh();
  }
}

module.exports = { PermissionPanel };