const blessed = require('blessed');
const { theme } = require('./theme');

/**
 * PermissionPanel — modal for viewing/editing the tool permission policy
 * (02.2). Shows the current rules, the default action, and the last few
 * permission decisions. Lets the user add an "allow <command>" pattern rule or
 * reset to the starter policy.
 */
class PermissionPanel {
  constructor(screen, bridge) {
    this.screen = screen;
    this.bridge = bridge;
    this.visible = false;
    this.loading = false;

    this.box = blessed.box({
      parent: screen,
      top: 'center',
      left: 'center',
      width: '80%',
      height: '78%',
      label: ' Permission Policy ',
      border: { type: 'line', fg: theme.accent },
      style: {
        fg: theme.text,
        bg: theme.bg,
        border: { fg: theme.accent },
        label: { fg: theme.accent, bold: true },
      },
      tags: true,
      content: 'Loading…',
      keys: true,
      hidden: true,
    });

    this.input = blessed.textbox({
      parent: this.box,
      top: '87%',
      left: 2,
      width: '90%',
      height: 1,
      inputOnFocus: true,
      label: ' Allow command (e.g. "cat"): ',
      border: { type: 'line', fg: theme.subtle },
      style: {
        fg: theme.text,
        bg: theme.surface,
        border: { fg: theme.subtle },
        label: { fg: theme.textDim },
      },
      hidden: true,
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
    this.box.key('a', () => {
      this.input.show();
      this.input.focus();
      this.screen.render();
    });
    this.box.key('r', () => this.reset());
    this.box.key('d', () => this.toggleDefault());
  }

  async open() {
    this.visible = true;
    this.box.show();
    this.screen.render();
    await this.refresh();
  }

  hide() {
    this.visible = false;
    this.box.hide();
    this.input.hide();
    this.screen.render();
  }

  async refresh() {
    this.loading = true;
    this.setContent('Loading policy…');
    this.screen.render();
    try {
      const pol = await this.bridge.permissionGet();
      const dec = await this.bridge.permissionDecisions(8);
      this.render(pol.policy || {}, dec.decisions || []);
    } catch (e) {
      this.setContent(`{${theme.error}-fg}Failed to load policy: ${e.message}{/}`);
    } finally {
      this.loading = false;
      this.screen.render();
    }
  }

  render(policy, decisions) {
    const rules = policy.rules || [];
    const def = policy.default_action || 'ask';
    const lines = [
      '{bold}Rules:{/}',
    ];
    if (rules.length === 0) {
      lines.push('  {#a8a8a8-fg}(none){/}');
    }
    rules.forEach((r, i) => {
      const color = r.action === 'allow' ? theme.success : r.action === 'deny' ? theme.error : theme.warning;
      const scope = r.scope || 'pattern';
      lines.push(`  ${i + 1}. {${color}-fg}${r.action}{/} ${r.tool || '*'}:${r.match || '*'} (${scope})`);
    });
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
    lines.push(...(decLines.length ? decLines : ['  {#a8a8a8-fg}(none yet){/}']));
    lines.push(
      '',
      '{#a8a8a8-fg}[a] Allow command   [d] Toggle default   [r] Reset to starter   [Esc] Close{/}'
    );
    this.setContent(lines.join('\n'));
  }

  setContent(content) {
    this.box.setContent(content);
    this.box.scrollTo(0);
  }

  async addAllowRule(cmd) {
    try {
      const pol = await this.bridge.permissionGet();
      const policy = pol.policy || {};
      const rules = policy.rules || [];
      rules.unshift({
        tool: 'run_shell_command',
        match: cmd,
        action: 'allow',
        scope: 'pattern',
      });
      await this.bridge.permissionSet({ ...policy, rules });
    } catch (e) {
      this.setContent(`Failed to save policy: ${e.message}`);
      this.screen.render();
      return;
    }
    await this.refresh();
  }

  async toggleDefault() {
    try {
      const pol = await this.bridge.permissionGet();
      const policy = pol.policy || {};
      const order = ['ask', 'allow', 'deny'];
      const cur = policy.default_action || 'ask';
      policy.default_action = order[(order.indexOf(cur) + 1) % order.length];
      await this.bridge.permissionSet(policy);
    } catch (e) {
      this.setContent(`Failed to save policy: ${e.message}`);
      this.screen.render();
      return;
    }
    await this.refresh();
  }

  async reset() {
    try {
      await this.bridge.permissionReset();
    } catch (e) {
      this.setContent(`Failed to reset policy: ${e.message}`);
      this.screen.render();
      return;
    }
    await this.refresh();
  }
}

module.exports = PermissionPanel;
