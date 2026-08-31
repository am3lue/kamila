const blessed = require('blessed');
const { theme, border, makeBorder, makeBottomBorder, translateTags } = require('../../theme/TerminalTheme');

const COMMANDS = [
  { category: 'System', cmd: '/help', desc: 'Show all commands', action: 'help' },
  { category: 'System', cmd: '/clear', desc: 'Clear chat history', action: 'clear' },
  { category: 'System', cmd: '/reset', desc: 'Reset chat + bridge', action: 'reset' },
  { category: 'System', cmd: '/copy', desc: 'Copy last response', action: 'copy' },
  { category: 'System', cmd: '/status', desc: 'Show system status', action: 'status' },
  { category: 'System', cmd: '/mode [chat|plan|test|execute]', desc: 'Switch mode', action: 'mode' },
  
  { category: 'Tasks', cmd: '/task add "title" [--priority N] [--desc "text"] [--time N]', desc: 'Add task', action: 'task_add' },
  { category: 'Tasks', cmd: '/task done <id>', desc: 'Complete task', action: 'task_done' },
  { category: 'Tasks', cmd: '/task rm <id>', desc: 'Delete task', action: 'task_rm' },
  { category: 'Tasks', cmd: '/tasks', desc: 'List tasks', action: 'task_list' },
  
  { category: 'Models', cmd: '/model list', desc: 'List models', action: 'model_list' },
  { category: 'Models', cmd: '/model select <name>', desc: 'Switch model', action: 'model_select' },
  
  { category: 'Desktop', cmd: '/context', desc: 'Show desktop context', action: 'context' },
  { category: 'Desktop', cmd: '/watch [on|off]', desc: 'Toggle desktop watch', action: 'watch' },
  { category: 'Desktop', cmd: '/shot', desc: 'Screenshot + describe', action: 'shot' },
  
  { category: 'Voice', cmd: '/record [seconds]', desc: 'Record voice (default 5s)', action: 'record' },
  { category: 'Voice', cmd: '/transcribe <file>', desc: 'Transcribe audio file', action: 'transcribe' },
  
  { category: 'Permissions', cmd: '/perm', desc: 'Open permission panel', action: 'perm' },
  
  { category: 'Agent', cmd: '/agent <prompt>', desc: 'Run agent query', action: 'agent' },
];

class CommandPalette {
  constructor(screen, app) {
    this.screen = screen;
    this.app = app;
    this.visible = false;
    this.box = null;
    this.input = null;
    this.list = null;
    this.filtered = COMMANDS;
    this.selectedIndex = 0;
  }

  create() {
    const width = Math.min(this.screen.width - 4, 80);
    const height = Math.min(this.screen.height - 4, 25);
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
      top: 1,
      left: 1,
      width: '100%-2',
      height: 1,
      label: ' Search: ',
      border: { type: 'line', fg: theme.subtle },
      style: { fg: theme.text, bg: theme.surface, border: { fg: theme.subtle } },
      keys: true,
      inputOnFocus: true,
    });

    this.list = blessed.list({
      parent: this.box,
      top: 3,
      left: 1,
      width: '100%-2',
      height: '100%-5',
      style: {
        fg: theme.text,
        bg: theme.surface,
        selected: { bg: theme.accent, fg: theme.bg, bold: true },
      },
      keys: true,
      vi: true,
      mouse: true,
      tags: true,
    });

    this._bindKeys();
    return this;
  }

  _bindKeys() {
    this.input.on('keypress', () => {
      const q = this.input.getValue().toLowerCase();
      this.filtered = COMMANDS.filter(c => 
        c.cmd.toLowerCase().includes(q) || c.desc.toLowerCase().includes(q) || c.category.toLowerCase().includes(q)
      );
      this.selectedIndex = 0;
      this._renderList();
    });

    this.list.on('select', (item, index) => {
      this._execute(this.filtered[index]);
    });

    this.box.key(['escape'], () => this.hide());
    this.box.key(['C-c'], () => this.hide());
  }

  _renderList() {
    const grouped = {};
    for (const cmd of this.filtered) {
      if (!grouped[cmd.category]) grouped[cmd.category] = [];
      grouped[cmd.category].push(cmd);
    }
    const items = [];
    for (const [cat, cmds] of Object.entries(grouped)) {
      items.push(`{bold}{cyan-fg}${cat}{/}`);
      for (const cmd of cmds) {
        items.push(`  {${cmd.action === this.filtered[this.selectedIndex]?.action ? 'black-fg}{cyan-bg}' : ''} ${cmd.cmd}  {textDim}— ${cmd.desc}{/}`);
      }
    }
    this.list.setItems(items.map(i => translateTags(i)));
    this.list.select(this.selectedIndex);
    this.screen.render();
  }

  _execute(cmd) {
    this.hide();
    if (this.app && this.app.executeCommand) {
      this.app.executeCommand(cmd.cmd);
    }
  }

  open() {
    if (!this.box) this.create();
    this.visible = true;
    this.input.clearValue();
    this.filtered = COMMANDS;
    this.selectedIndex = 0;
    this._renderList();
    this.box.show();
    this.input.focus();
    this.screen.render();
  }

  hide() {
    this.visible = false;
    if (this.box) this.box.hide();
    this.screen.render();
  }
}

module.exports = { CommandPalette };