const blessed = require('blessed');
const { TerminalBox } = require('../TerminalBox');
const { theme } = require('../../theme/TerminalTheme');

class InspectorPanel {
  constructor(screen, regionManager, app) {
    this.screen = screen;
    this.regionManager = regionManager;
    this.app = app;
    this.box = null;
    this.tasks = [];
    this.cpu = 0;
    this.ram = 0;
    this.stats = {};
    this.desktopContext = null;
    this.lineMap = [];
    this.lastRenderKey = '';
  }

  create() {
    const region = this.regionManager.get('inspector');
    if (!region) return;

    this.box = new TerminalBox({
      parent: this.screen,
      top: region.y,
      left: region.x,
      width: region.width,
      height: region.height,
      role: 'panel',
      title: ' INSPECTOR ',
      tags: true,
      scrollable: true,
      alwaysScroll: true,
      scrollbar: { style: { bg: theme.border } },
    }).create();

    this._render();
    return this.box;
  }

  _render() {
    if (!this.box) return;
    const lines = [];
    const map = [];
    const add = (line, meta = null) => { lines.push(line); map.push(meta); };
    const w = Math.max(10, this.box.width - 4);

    const bar = (label, pct, color) => {
      const inner = Math.max(1, w - 10);
      const filled = Math.max(0, Math.min(inner, Math.round(inner * pct / 100)));
      return `${label} [${'{' + color + '-fg}'}${'.'.repeat(filled)}{/}{textDim}${'.'.repeat(inner - filled)}{/}] ${pct}%`;
    };

    // ── SYSTEM ──
    add('{bold}SYSTEM{/}');
    add(bar('CPU ', this.cpu, 'green'));
    add(bar('RAM ', this.ram, 'yellow'));
    const st = this.stats;
    const mem = st.memory || {};
    const net = (st.network || [])[0] || {};
    const fmt = (b) => b >= 1e6 ? (b / 1e6).toFixed(1) + 'MB/s' : b >= 1e3 ? (b / 1e3).toFixed(1) + 'KB/s' : (b || 0) + 'B/s';
    if (mem.used_gb != null || mem.used_percent != null) {
      add(`MEM  ${mem.used_gb ?? '?'}GB (${mem.used_percent ?? '?'}%)`);
    }
    if (net.tx_speed != null || net.rx_speed != null) {
      add(`NET  ↑${fmt(net.tx_speed)} ↓${fmt(net.rx_speed)}`);
    }
    if (st.health) {
      add(`HEALTH ${st.health.status || 'ok'} (${st.health.score ?? '?'}/100)`);
    }
    const wins = st.tasks?.completed_today;
    const rate = st.tasks?.completion_rate;
    if (wins != null) add(`WINS ${wins} (${rate ?? 0}%)`);
    if (st.uptime?.formatted) add(`UP  ${st.uptime.formatted}`);
    add('');

    // ── CONTEXT ──
    add('{bold}CONTEXT{/}');
    if (this.desktopContext) {
      const ctx = this.desktopContext;
      add('> ACTIVE_WINDOW');
      add(`  ${ctx.active_window || '— unavailable'}`);
      const clip = ctx.clipboard || '— unavailable';
      const clipDisplay = clip.length > w - 4 ? clip.slice(0, w - 4) + '…' : clip;
      add('> CLIPBOARD {textDim}(4KB, redacted){/}');
      add(`  {textDim}${clipDisplay}{/}`);
      add('> CWD');
      add(`  ${ctx.cwd || '— unavailable'}`);
      add(`> WATCH ${ctx.watch_enabled ? '{green-fg}● ACTIVE{/}' : '{yellow-fg}○ OFF{/}'} {textDim}[click]{/}`, { action: 'watch' });
    } else {
      add('{textDim}Loading desktop context...{/}');
    }
    add('');

    // ── TASKS ──
    add('{bold}TASKS{/}');
    if (!this.tasks.length) {
      add('{textDim}No pending tasks{/}');
    } else {
      this.tasks.forEach((task, i) => {
        const icon = task.priority >= 3 ? '!' : task.priority === 2 ? '→' : '✓';
        const color = task.priority >= 3 ? 'red' : task.priority === 2 ? 'yellow' : 'green';
        add(`{${color}-fg}[${icon}] #${task.id}{/} ${task.title}`, { action: 'task', index: i });
      });
    }

    const content = lines.join('\n');
    this.box.setContent(content);
    this.lineMap = map;
    this.screen.render();
  }

  setGauges(cpu, ram) {
    this.cpu = cpu || 0;
    this.ram = ram || 0;
    this._render();
  }

  setStats(stats) {
    this.stats = { ...this.stats, ...(stats || {}) };
    this._render();
  }

  setTasks(tasks) {
    this.tasks = tasks || [];
    this._render();
  }

  setDesktopContext(ctx) {
    this.desktopContext = ctx;
    this._render();
  }

  onResize() {
    if (this.box) {
      const region = this.regionManager.get('inspector');
      if (region) {
        this.box.top = region.y;
        this.box.left = region.x;
        this.box.width = region.width;
        this.box.height = region.height;
      }
    }
    this._render();
  }

  handleClick(mouse) {
    const boxTop = (this.box.atop || 0) + 1;
    const scrollIndex = this.box.getScroll();
    const clickedIndex = mouse.y - boxTop + scrollIndex;
    if (clickedIndex < 0 || clickedIndex >= this.lineMap.length) return;
    const meta = this.lineMap[clickedIndex];
    if (!meta) return;
    if (meta.action === 'watch') {
      this.app.toggleDesktopWatch();
    } else if (meta.action === 'task' && this.tasks[meta.index]) {
      this.app.showTaskAction(this.tasks[meta.index]);
    }
  }
}

module.exports = { InspectorPanel };