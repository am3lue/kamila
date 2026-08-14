const blessed = require('blessed');
const { theme } = require('./theme');
const LogPanel = require('./logs');
const TaskActionOverlay = require('./taskaction');
const ConfirmOverlay = require('./confirm');
const PermissionPanel = require('./permission');
const { stripTags, escapeBraces } = require('./markdown');
const { MessageStore } = require('./messages');
const { ChatRenderer } = require('./renderer');

// ─── Log Buffer ────────────────────────────────────────

class LogBuffer {
  constructor(maxSize = 500) {
    this.entries = [];
    this.maxSize = maxSize;
  }

  push(type, msg) {
    const time = new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    this.entries.push({ time, type, msg });
    if (this.entries.length > this.maxSize) {
      this.entries.splice(0, this.entries.length - this.maxSize);
    }
  }

  getAll() {
    return this.entries;
  }
}

const GAUGE_REFRESH_MS = 500;
const PANEL_REFRESH_MS = 2000;

// ─── Gauge Helpers ──────────────────────────────────────

function createGauge(opts) {
  const box = blessed.box({
    parent: opts.parent,
    top: opts.top,
    left: opts.left,
    width: opts.width,
    height: 5,
    label: opts.label || ' Gauge ',
    border: { type: 'line', fg: theme.subtle },
    style: {
      fg: theme.text,
      bg: theme.bg,
      border: { fg: theme.subtle },
      label: { fg: opts.color || theme.accent },
    },
    tags: true,
    mouse: true,
    color: opts.color || theme.accent,
  });
  box.color = opts.color || theme.accent;
  return box;
}

function updateGauge(gauge, percent, title, detail) {
  const w = gauge.width - 4;
  const barW = Math.max(1, w - 6);
  const filled = Math.round((percent / 100) * barW);
  const empty = barW - filled;
  const color = gauge.color || 'cyan';
  const bar = `{${color}-fg}${'▓'.repeat(filled)}{/}${'░'.repeat(empty)}`;
  const pct = String(Math.round(percent));
  gauge.setContent(
    ` ${bar} ${pct.padStart(2)}%\n` +
    ` ${pct.padStart(2)}%  ${title}\n` +
    ` ${detail}`
  );
}

// ─── KamilaApp ──────────────────────────────────────────

class KamilaApp {
  constructor(bridge, screen) {
    this.bridge = bridge;
    this.panelsVisible = true;
    this.gaugeInterval = null;
    this.panelInterval = null;
    this.logBuffer = new LogBuffer();
    this.prevNet = {};
    this.activeModel = null;
    this.currentMode = 'chat';
    this.selectionStart = null;
    this.pendingThinkingModel = null;
    this.messageStore = new MessageStore();
    this.chatRenderer = new ChatRenderer();
    this.lineMap = [];
    this.recallRing = [];
    this.recallIndex = -1;

    this.logBuffer.push('SYS', 'Kamila v0.2.0 starting');

    if (screen) {
      this.screen = screen;
    } else {
      // ─── Screen ───────────────────────────────────────
      this.screen = blessed.screen({
        smartCSR: true,
        title: 'Kamila v0.2.0',
        cursor: { artificial: true, blink: true, color: theme.accent },
        dockBorders: true,
        fullUnicode: true,
      });
      this.screen.enableMouse();
    }

    // ─── Top Bar ──────────────────────────────────────
    this.topBar = blessed.box({
      parent: this.screen,
      top: 0, left: 0, width: '100%', height: 1,
      style: { bg: theme.bg, fg: theme.accent },
      tags: true,
    });

    // ─── Status Bar ───────────────────────────────────
    this.statusBar = blessed.box({
      parent: this.screen,
      bottom: 0, left: 0, height: 1, width: '100%',
      style: { bg: theme.bg, fg: theme.textDim },
      tags: true,
    });

    // ─── Left Column ─────────────────────────────────
    this.cpuGauge = createGauge({
      parent: this.screen, top: 2, left: 1, width: '22%-2',
      label: ' CPU ', color: 'cyan',
    });
    this.cpuGauge.on('click', () => {
      this.logBuffer.push('SYS', 'CPU gauge clicked — refreshing');
      this.refreshAll();
    });

    this.diskGauge = createGauge({
      parent: this.screen, top: 8, left: 1, width: '22%-2',
      label: ' DISK ', color: 'green',
    });
    this.diskGauge.on('click', () => {
      this.logBuffer.push('SYS', 'Disk gauge clicked — refreshing');
      this.refreshAll();
    });

    this.tasksBox = blessed.box({
      parent: this.screen,
      top: 14, left: 1, width: '22%-2', bottom: 2,
      label: ' Tasks ',
      border: { type: 'line', fg: theme.subtle },
      style: { fg: theme.text, bg: theme.bg, border: { fg: theme.subtle }, label: { fg: theme.yellow } },
      tags: true, scrollable: true, alwaysScroll: true,
      scrollbar: { style: { bg: theme.subtle } },
      mouse: true,
    });
    this.tasksBox.on('click', (mouse) => this.handleTasksBoxClick(mouse));

    // ─── Center Panel (Chat) ──────────────────────────
    this.centerPanel = blessed.box({
      parent: this.screen,
      top: 1, left: '22%', width: '56%', bottom: 1,
      style: { bg: theme.bg },
    });

    this.chatLog = blessed.box({
      parent: this.centerPanel,
      top: 0, left: 0, width: '100%', bottom: 1,
      label: ' Chat ',
      border: { type: 'line', fg: theme.subtle },
      style: {
        fg: theme.text, bg: theme.surface,
        border: { fg: theme.subtle },
        label: { fg: theme.accent },
        focus: { border: { fg: theme.accent } },
      },
      tags: true, scrollable: true, alwaysScroll: true,
      scrollbar: { style: { bg: theme.subtle } },
      mouse: true,
      keys: true,
    });
    this.chatLog.key('C-c', () => this.copyLastResponse());
    this.chatLog.key('C-up', () => { this.chatLog.scroll(-1); this.screen.render(); });
    this.chatLog.key('C-down', () => { this.chatLog.scroll(1); this.screen.render(); });
    this.chatLog.on('mousedown', (mouse) => {
      this.selectionStart = { y: mouse.y, x: mouse.x, scroll: this.chatLog.getScroll() };
    });
    this.chatLog.on('mouseup', (mouse) => {
      if (!this.selectionStart) return;
      const start = this.selectionStart;
      this.selectionStart = null;
      const endY = mouse.y;
      const endX = mouse.x;
      if (start.y === endY && start.x === endX) {
        this.handleChatLogClick(mouse);
      } else {
        const text = this.extractRange(start, { y: endY, x: endX });
        if (text) {
          this.doCopy(text);
          this.statusBar.setContent(` {green-fg}✓ Copied selection{/}  ·  Tab:Focus  Enter:Send  Esc:Quit  F5:Refresh  F10:Logs  Click msg:Copy`);
          this.screen.render();
          setTimeout(() => { this.updateStatusBar(); this.screen.render(); }, 2000);
        }
      }
    });

    // ─── Chat Input ─────────────────────────────────
    this.chatInput = blessed.textarea({
      parent: this.centerPanel,
      bottom: 0, left: 0, width: '100%', height: 3,
      style: {
        fg: theme.text, bg: theme.surface,
        focus: { fg: theme.textBright, bg: theme.surface2 },
      },
      keys: true,
      mouse: true,
    });
    this.chatInput.on('focus', () => this.chatInput.readInput());

    // ─── Right Column ─────────────────────────────────
    this.statsBox = blessed.box({
      parent: this.screen,
      top: 2, right: 1, width: '22%-2', height: 7,
      label: ' Stats ',
      border: { type: 'line', fg: theme.subtle },
      style: { fg: theme.text, bg: theme.bg, border: { fg: theme.subtle }, label: { fg: theme.magenta } },
      tags: true,
    });

    this.goalsBox = blessed.box({
      parent: this.screen,
      top: 10, right: 1, width: '22%-2', bottom: 2,
      label: ' Goals ',
      border: { type: 'line', fg: theme.subtle },
      style: { fg: theme.text, bg: theme.bg, border: { fg: theme.subtle }, label: { fg: theme.green } },
      tags: true, scrollable: true, alwaysScroll: true,
      scrollbar: { style: { bg: theme.subtle } },
    });

    // ─── Loading Defaults ────────────────────────────
    updateGauge(this.cpuGauge, 0, 'CPU UTIL', '⟳ Measuring…');
    updateGauge(this.diskGauge, 0, 'FULL', '⟳ Measuring…');
    this.tasksBox.setContent('{#a8a8a8-fg}⟳ Loading tasks…{/}');
    this.statsBox.setContent('{#a8a8a8-fg}⟳ Collecting data…{/}');
    this.goalsBox.setContent('{#a8a8a8-fg}⟳ Loading…{/}');

    // ─── Side Widgets List (for toggle) ──────────────
    this.sideWidgets = [
      this.cpuGauge, this.diskGauge, this.tasksBox,
      this.statsBox, this.goalsBox,
    ];

    // ─── Log Panel ────────────────────────────────────
    this.logPanel = new LogPanel(this.screen, this.logBuffer);

    // ─── Permission Panel ─────────────────────────────
    this.permissionPanel = new PermissionPanel(this.screen, this.bridge);

    // ─── Task Action Overlay ─────────────────────────
    this.taskActionOverlay = new TaskActionOverlay(this.screen);
    this.cachedTasks = [];

    // ─── Confirm Overlay ─────────────────────────────
    this.confirmOverlay = new ConfirmOverlay(this.screen);
    this.confirmOverlay.onAnswer = (answer) => {
      this.bridge.respondConfirm(answer.id, answer.allow);
      if (answer.allow) {
        this.appendChat(`{yellow-fg}✓ Allowed shell command{/}`);
      } else {
        this.appendChat(`{red-fg}✗ Denied shell command{/}`);
      }
      this.screen.render();
    };
    this.bridge.onConfirmRequest = (msg) => {
      this.confirmOverlay.show(msg);
    };

    // ─── Key Bindings ────────────────────────────────
    this.screen.key(['escape'], () => {
      if (this.taskActionOverlay.visible) {
        this.taskActionOverlay.hide();
        return;
      }
      if (this.logPanel.visible) {
        this.logPanel.toggle();
        return;
      }
      this.bridge.stop();
      process.exit(0);
    });
    this.screen.key(['q', 'C-c'], () => {
      this.bridge.stop();
      process.exit(0);
    });

    this.screen.key('C-t', () => this.togglePanels());
    this.screen.key('f10', () => {
      this.logPanel.toggle();
      if (!this.logPanel.visible) this.screen.render();
    });
    this.screen.key('f11', () => {
      if (this.permissionPanel.visible) {
        this.permissionPanel.hide();
      } else {
        this.permissionPanel.open();
      }
    });
    this.screen.key('f5', () => this.refreshAll());

    this.chatInput.key('enter', () => this.handleSubmit());
    this.chatInput.on('submit', () => this.handleSubmit());
    this.chatInput.key('C-o', () => {
      const cur = this.chatInput.getValue();
      this.chatInput.setValue(cur + '\n');
      this.chatInput.focus();
      this.screen.render();
    });
    this.chatInput.key('up', () => this.recallHistory(-1));
    this.chatInput.key('C-p', () => this.recallHistory(-1));
    this.chatInput.key('down', () => this.recallHistory(1));
    this.chatInput.key('C-n', () => this.recallHistory(1));
    this.chatInput.on('keypress', (ch, key) => {
      if (key && ['up', 'down', 'C-p', 'C-n', 'enter', 'C-o'].includes(key.full)) return;
      this.recallIndex = -1;
    });
    this.screen.key('tab', () => { this.chatInput.focus(); this.screen.render(); });

    // ─── Init ─────────────────────────────────────────
    this.updateTopBar();
    this.updateStatusBar();
    this.appendChat('{#a8a8a8-fg}Kamila v0.2.0 ready — type /help for commands{/}');
    this.logBuffer.push('SYS', 'Ready — waiting for input');
    this.bridge.send('mode.get').then(r => {
      this.currentMode = r.mode || 'chat';
      this.updateTopBar();
      this.screen.render();
    }).catch(() => {});
    this.startRefresh();
    this.screen.render();
    this.hydrateFromBridge();
  }

  /** Load persisted chat history from the bridge and render it. */
  async hydrateFromBridge() {
    try {
      const r = await this.bridge.chatHistory('default');
      if (r && Array.isArray(r.messages) && r.messages.length) {
        this.messageStore.hydrate(r.messages);
        this.renderChat();
        this.screen.render();
      }
    } catch (e) {
      this.logBuffer.push('ERR', `History hydrate failed: ${e.message}`);
    }
  }

  togglePanels() {
    this.panelsVisible = !this.panelsVisible;
    for (const w of this.sideWidgets) {
      this.panelsVisible ? w.show() : w.hide();
    }
    if (this.panelsVisible) {
      this.centerPanel.left = '22%';
      this.centerPanel.width = '56%';
    } else {
      this.centerPanel.left = 0;
      this.centerPanel.width = '100%';
    }
    this.chatInput.focus();
    this.updateStatusBar();
    this.screen.render();
  }

  /** Cycle through previously submitted prompts (↑/↓ in the input). */
  recallHistory(dir) {
    if (!this.recallRing.length) return;
    let idx = this.recallIndex;
    idx = idx === -1 ? (dir < 0 ? this.recallRing.length - 1 : 0) : idx + dir;
    if (idx < 0 || idx >= this.recallRing.length) return;
    this.recallIndex = idx;
    this.chatInput.setValue(this.recallRing[idx]);
    this.chatInput.focus();
    this.screen.render();
  }

  async handleSubmit() {
    const text = this.chatInput.getValue().trim();
    if (!text) return;
    if (this.recallRing[this.recallRing.length - 1] !== text) {
      this.recallRing.push(text);
    }
    this.recallIndex = -1;
    this.chatInput.clearValue();
    this.chatInput.focus();

    this.messageStore.add('user', text);
    this.logBuffer.push('CHAT', `<You>: ${text}`);

    if (text.startsWith('/')) {
      this.logBuffer.push('CMD', text);
      await this.handleCommand(text);
      this.screen.render();
      return;
    }

    const modelLabel = this.activeModel ? `{#a8a8a8-fg}${this.activeModel}{/}` : '';
    this.statusMsg = this.messageStore.add('system', `⟳ Thinking... ${modelLabel}`, { kind: 'status' });
    this.renderChat();
    this.screen.render();
    const startTime = Date.now();

    // Active streaming message (assistant response) + pending thinking text.
    this.activeStreaming = null;

    const handlers = this.setupStreamHandlers();

    try {
      const response = await this.bridge.aiQuery(text, { task_type: 'chat', mode: this.currentMode }, handlers);
      const elapsed = ((Date.now() - startTime) / 1000).toFixed(1);
      const model = response.model || this.activeModel || '';
      if (this.activeStreaming) {
        this.activeStreaming.elapsed = `${elapsed}s`;
        this.activeStreaming.model = model;
        this.finishStreaming();
      } else {
        // No chunks came — collapse the status message and show empty response.
        this.messageStore.remove(this.statusMsg.id);
        this.activeStreaming = this.messageStore.add('assistant', '', { elapsed: `${elapsed}s`, model });
        this.finishStreaming();
      }
      this.logBuffer.push('CHAT', `<Kamila>: ${(response.text || '').slice(0, 120)}${(response.text || '').length > 120 ? '…' : ''}`);
    } catch (e) {
      if (this.statusMsg) this.messageStore.remove(this.statusMsg.id);
      this.messageStore.add('error', `Error: ${e.message}`, { kind: 'error' });
      this.logBuffer.push('ERR', `AI query failed: ${e.message}`);
    }
    this.statusMsg = null;
    this.renderChat();
    this.screen.render();
  }

  setupStreamHandlers() {
    const handlers = {
      firstChunk: true,
      onChunk: (chunk) => {
        if (!chunk) return;
        if (handlers.firstChunk) {
          handlers.firstChunk = false;
          // First content chunk: the "Thinking…" status is done.
          // If we have a thinking message, keep it as a collapsible block and
          // start a fresh assistant message for the actual response.
          if (this.statusMsg) this.messageStore.remove(this.statusMsg.id);
          this.statusMsg = null;

          if (this.activeStreaming && this.activeStreaming.kind === 'thinking') {
            // Keep thinking message, start new response message
            this.activeStreaming = this.messageStore.beginStream('assistant');
          } else if (!this.activeStreaming) {
            // No thinking happened; start response message
            this.activeStreaming = this.messageStore.beginStream('assistant');
          }
        }
        if (this.activeStreaming) {
          this.activeStreaming.text += chunk;
          this.renderChat();
        }
        this.screen.render();
      },
      onThinking: (chunk) => {
        if (!chunk) return;
        if (!this.activeStreaming || this.activeStreaming.kind !== 'thinking') {
          // Start/continue a thinking block
          if (this.activeStreaming && this.activeStreaming.kind !== 'thinking') {
            // Already started response; ignore late thinking
          } else {
            if (this.statusMsg) {
              this.messageStore.remove(this.statusMsg.id);
              this.statusMsg = null;
            }
            if (!this.activeStreaming || this.activeStreaming.kind !== 'thinking') {
              this.activeStreaming = this.messageStore.beginStream('assistant', { kind: 'thinking' });
            }
            this.activeStreaming.text += chunk;
            this.renderChat();
          }
        } else {
          this.activeStreaming.text += chunk;
          this.renderChat();
        }
        this.screen.render();
      },
      onToolCall: (ev) => {
        this.messageStore.add('tool', ev.name || 'tool', { kind: 'tool' });
        this.renderChat();
        this.screen.render();
      },
      onToolResult: (ev) => {
        const preview = (ev.result || '').slice(0, 80);
        this.messageStore.add('tool', `→ ${preview}`, { kind: 'toolresult' });
        this.renderChat();
        this.screen.render();
      },
    };
    return handlers;
  }

  finishStreaming() {
    if (!this.activeStreaming) return;
    const id = this.activeStreaming.id;
    this.messageStore.finish(id, { model: this.activeStreaming.model });
    this.activeStreaming = null;
    this.chatRenderer.invalidate(id);
  }

  async handleCommand(text) {
    const parts = text.split(' ');
    const cmd = parts[0].toLowerCase();

    switch (cmd) {
      case '/help':
        this.appendChat('{yellow-fg}Commands:{/} /help /clear /reset /copy /mode /status /tasks /models /agent /model /task (add|done|rm|list)');
        break;
      case '/clear':
        this.messageStore.clear();
        this.chatRenderer.clear();
        this.renderChat();
        break;
      case '/reset':
        this.messageStore.clear();
        this.chatRenderer.clear();
        try { await this.bridge.send('chat.reset', {}); } catch (e) {}
        this.appendChat('{yellow-fg}Chat history cleared.{/}');
        break;
      case '/copy':
        this.copyLastResponse();
        break;
      case '/mode': {
        const modeArg = parts[1];
        if (!modeArg) {
          this.appendChat(`{cyan-fg}Current mode: {bold}${this.currentMode}{/}  Available: chat, plan, test, execute{/}`);
          break;
        }
        const valid = ['chat', 'plan', 'test', 'execute'];
        if (!valid.includes(modeArg)) {
          this.appendChat(`{red-fg}Invalid mode. Available: ${valid.join(', ')}{/}`);
          break;
        }
        try {
          const r = await this.bridge.send('mode.set', { mode: modeArg });
          this.currentMode = r.mode;
          this.messageStore.clear();
          this.chatRenderer.clear();
          this.updateTopBar();
          this.appendChat(`{green-fg}Switched to {bold}${r.mode}{/} mode. History cleared.{/}`);
          this.logBuffer.push('CMD', `Mode → ${r.mode}`);
        } catch (e) {
          this.appendChat(`{red-fg}Failed to switch mode: ${e.message}{/}`);
        }
        break;
      }
      case '/status':
        try {
          const s = await this.bridge.systemStatus();
          this.appendChat(`{cyan-fg}CPU: ${s.cpu?.usage_percent != null ? s.cpu.usage_percent + '%' : 'unavailable'} | Mem: ${s.memory?.used_percent || '?'}% | Disk: ${s.disk?.root?.use_percent || '?'}% | Uptime: ${s.uptime?.formatted || '?'}{/}`);
        } catch (e) {
          this.appendChat(`{red-fg}Status error: ${e.message}{/}`);
          this.logBuffer.push('ERR', `Status error: ${e.message}`);
        }
        break;
      case '/task':
      case '/tasks':
        await this.handleTaskCommand(parts.slice(1));
        break;
      case '/model':
      case '/models':
        await this.handleModelCommand(parts.slice(1));
        break;
      case '/agent': {
        const prompt = parts.slice(1).join(' ');
        if (!prompt) { this.appendChat('{red-fg}Usage: /agent <prompt>{/}'); return; }
        this.statusMsg = this.messageStore.add('system', '⟳ Agent running...', { kind: 'status' });
        this.renderChat();
        this.screen.render();
        const handlers = this.setupStreamHandlers();
        try {
          const result = await this.bridge.agentQuery(prompt, {}, handlers);
          if (this.activeStreaming) {
            this.finishStreaming();
          } else {
            this.messageStore.remove(this.statusMsg.id);
            this.messageStore.add('assistant', '');
          }
          this.logBuffer.push('CHAT', `<Agent>: ${result.text.slice(0, 120)}${result.text.length > 120 ? '…' : ''}`);
        } catch (e) {
          if (this.statusMsg) this.messageStore.remove(this.statusMsg.id);
          this.messageStore.add('error', `Agent error: ${e.message}`, { kind: 'error' });
          this.logBuffer.push('ERR', `Agent error: ${e.message}`);
        }
        this.statusMsg = null;
        this.renderChat();
        this.screen.render();
        break;
      }
      default:
        this.appendChat(`{red-fg}Unknown: ${cmd}. Type /help{/}`);
    }
  }

  async handleTaskCommand(args) {
    const sub = args[0]?.toLowerCase();

    if (!sub || sub === 'list') {
      try {
        const tasks = await this.bridge.tasksList();
        if (!tasks.length) {
          this.appendChat('{green-fg}No pending tasks.{/}');
        } else {
          tasks.forEach(t => {
            const labels = { 1: 'Low', 2: 'Medium', 3: 'High', 4: 'Critical' };
            this.appendChat(`{yellow-fg}#${t.id}{/} ${escapeBraces(t.title)} {textDim}(${labels[t.priority] || t.priority}){/}`);
          });
        }
      } catch (e) {
        this.appendChat(`{red-fg}Tasks error: ${e.message}{/}`);
        this.logBuffer.push('ERR', `Tasks error: ${e.message}`);
      }
      return;
    }

    if (sub === 'add') {
      // Parse: /task add "title" or /task add title --priority N --desc "..." --time N
      let title = '';
      let priority = 2;
      let description = '';
      let estimated_time = 30;

      const remaining = args.slice(1).join(' ');
      const titleMatch = remaining.match(/^"([^"]+)"|^(\S+)/);
      if (titleMatch) {
        title = titleMatch[1] || titleMatch[2];
      }

      const prioMatch = remaining.match(/--priority\s+(\d+)/i);
      if (prioMatch) priority = Math.min(4, Math.max(1, parseInt(prioMatch[1])));

      const descMatch = remaining.match(/--desc\s+"([^"]+)"/i);
      if (descMatch) description = descMatch[1];

      const timeMatch = remaining.match(/--time\s+(\d+)/i);
      if (timeMatch) estimated_time = parseInt(timeMatch[1]);

      if (!title) {
        this.appendChat('{red-fg}Usage: /task add "<title>" [--priority N] [--desc "text"] [--time N]{/}');
        return;
      }

      try {
        const result = await this.bridge.tasksAdd(title, { priority, description, estimated_time });
        this.appendChat(`{green-fg}✓ Task #${result.id} added: ${escapeBraces(result.title)}{/}`);
        this.logBuffer.push('SYS', `Task #${result.id} added: ${result.title}`);
        this.refreshTasks();
      } catch (e) {
        this.appendChat(`{red-fg}Add task error: ${e.message}{/}`);
        this.logBuffer.push('ERR', `Add task error: ${e.message}`);
      }
      return;
    }

    if (sub === 'done' || sub === 'complete') {
      const id = parseInt(args[1]);
      if (isNaN(id)) {
        this.appendChat('{red-fg}Usage: /task done <task_id>{/}');
        return;
      }
      try {
        await this.bridge.tasksComplete(id);
        this.appendChat(`{green-fg}✓ Task #${id} completed{/}`);
        this.logBuffer.push('SYS', `Task #${id} completed`);
        this.refreshTasks();
      } catch (e) {
        this.appendChat(`{red-fg}Complete error: ${e.message}{/}`);
        this.logBuffer.push('ERR', `Complete error: ${e.message}`);
      }
      return;
    }

    if (sub === 'rm' || sub === 'delete') {
      const id = parseInt(args[1]);
      if (isNaN(id)) {
        this.appendChat('{red-fg}Usage: /task rm <task_id>{/}');
        return;
      }
      try {
        await this.bridge.tasksDelete(id);
        this.appendChat(`{yellow-fg}✗ Task #${id} deleted{/}`);
        this.logBuffer.push('SYS', `Task #${id} deleted`);
        this.refreshTasks();
      } catch (e) {
        this.appendChat(`{red-fg}Delete error: ${e.message}{/}`);
        this.logBuffer.push('ERR', `Delete error: ${e.message}`);
      }
      return;
    }

    this.appendChat(`{red-fg}Unknown subcommand: ${sub}. Use: add, done, rm, list{/}`);
  }

  async handleModelCommand(args) {
    const sub = args[0]?.toLowerCase();

    if (!sub || sub === 'list') {
      try {
        const m = await this.bridge.modelList();
        this.activeModel = m.active;
        this.appendChat(`{cyan-fg}Active: ${m.active}{/}`);
        if (Array.isArray(m.available) && m.available.length) {
          this.appendChat('{textDim}Available:{/}');
          m.available.forEach(n => this.appendChat(`  {textDim}${escapeBraces(n.name || n)}{/}`));
        }
      } catch (e) {
        this.appendChat(`{red-fg}Model list error: ${e.message}{/}`);
        this.logBuffer.push('ERR', `Model list error: ${e.message}`);
      }
      return;
    }

    if (sub === 'select') {
      const name = args.slice(1).join(' ');
      if (!name) {
        this.appendChat('{red-fg}Usage: /model select <model_name>{/}');
        return;
      }
      try {
        const result = await this.bridge.modelSelect(name);
        this.activeModel = result.active;
        this.appendChat(`{green-fg}✓ Switched to: ${escapeBraces(result.active)}{/}`);
        this.logBuffer.push('SYS', `Model switched to ${result.active}`);
      } catch (e) {
        this.appendChat(`{red-fg}Model select error: ${e.message}{/}`);
        this.logBuffer.push('ERR', `Model select error: ${e.message}`);
      }
      return;
    }

    this.appendChat(`{red-fg}Unknown: ${sub}. Use: /model list, /model select <name>{/}`);
  }

  handleTasksBoxClick(mouse) {
    if (!this.cachedTasks.length) return;

    const boxTop = (this.tasksBox.atop || 0) + 1;
    if (mouse.y < boxTop) return;
    const scrollIndex = this.tasksBox.getScroll();
    const clickedIndex = mouse.y - boxTop + scrollIndex;

    if (clickedIndex >= 0 && clickedIndex < this.cachedTasks.length) {
      const task = this.cachedTasks[clickedIndex];
      this.taskActionOverlay.show(task, {
        onComplete: async (t) => {
          try {
            await this.bridge.tasksComplete(t.id);
            this.appendChat(`{green-fg}✓ Task #${t.id} completed: ${escapeBraces(t.title)}{/}`);
            this.logBuffer.push('SYS', `Task #${t.id} completed via overlay`);
            this.refreshTasks();
          } catch (e) {
            this.appendChat(`{red-fg}Complete error: ${e.message}{/}`);
          }
        },
        onDelete: async (t) => {
          try {
            await this.bridge.tasksDelete(t.id);
            this.appendChat(`{yellow-fg}✗ Task #${t.id} deleted: ${escapeBraces(t.title)}{/}`);
            this.logBuffer.push('SYS', `Task #${t.id} deleted via overlay`);
            this.refreshTasks();
          } catch (e) {
            this.appendChat(`{red-fg}Delete error: ${e.message}{/}`);
          }
        },
      });
    }
  }

  async refreshTasks() {
    const [tasks, taskStats] = await Promise.all([
      this.bridge.tasksList().catch(() => []),
      this.bridge.tasksStats().catch(() => null),
    ]);

    if (Array.isArray(tasks)) {
      this.cachedTasks = tasks;
      this.tasksBox.setContent(
        tasks.length === 0
          ? '{green-fg}✓ No pending tasks{/}'
          : tasks.map(t => {
              const icon = t.priority >= 3 ? '!' : t.priority === 2 ? '→' : '✓';
              const color = t.priority >= 3 ? 'red' : t.priority === 2 ? 'yellow' : 'green';
              return `{${color}-fg}[${icon}] #${t.id}{/} ${escapeBraces(t.title)}`;
            }).join('\n')
        );
      }

      if (taskStats) {
      const completed = taskStats.completed_today || 0;
      const rate = taskStats.completion_rate || 0;
      // Update wins line in stats box (rebuild only the wins line portion)
      const cur = this.statsBox.getContent();
      const lines = cur.split('\n');
      for (let i = 0; i < lines.length; i++) {
        if (lines[i].includes('Wins:')) {
          lines[i] = `Wins: ${completed} (${rate}%)`;
          break;
        }
      }
      this.statsBox.setContent(lines.join('\n'));
    }

    if (this.logPanel.visible) this.logPanel.refresh();
    this.screen.render();
  }

  doCopy(text) {
    const fs = require('fs');
    const exec = require('child_process').execSync;
    const tmpFile = `/tmp/kamila_copy_${process.pid}_${Date.now()}.txt`;
    let wrote = false;
    try {
      fs.writeFileSync(tmpFile, text, 'utf8');
      wrote = true;
    } catch (e) {}
    try {
      exec(`xclip -selection clipboard < ${tmpFile} 2>/dev/null`, { stdio: 'ignore' });
      return true;
    } catch (e) {}
    try {
      exec(`xsel -ib < ${tmpFile} 2>/dev/null`, { stdio: 'ignore' });
      return true;
    } catch (e) {}
    try { this.screen.copyToClipboard(text); return true; } catch (e) {}
    return wrote;
  }

  copyLastResponse() {
    const messages = this.messageStore.list();
    // Find the last assistant/agent message (including thinking)
    let lastMsg = null;
    for (let i = messages.length - 1; i >= 0; i--) {
      const m = messages[i];
      if (m.role === 'assistant' || m.role === 'agent') {
        lastMsg = m;
        break;
      }
    }
    if (!lastMsg) {
      this.statusBar.setContent(` {red-fg}No response to copy{/}  ·  Tab:Focus  Enter:Send  Esc:Quit  F5:Refresh  F10:Logs  Click msg:Copy`);
    } else {
      this.doCopy(lastMsg.text);
      this.statusBar.setContent(` {green-fg}✓ Copied last response{/}  ·  Tab:Focus  Enter:Send  Esc:Quit  F5:Refresh  F10:Logs  Click msg:Copy`);
    }
    this.screen.render();
    setTimeout(() => { this.updateStatusBar(); this.screen.render(); }, 2000);
  }

  extractRange(start, end) {
    const y1 = start.y, x1 = start.x, s1 = start.scroll;
    const y2 = end.y, x2 = end.x, s2 = this.chatLog.getScroll();
    const contentTop = (this.chatLog.atop || 0) + 1;
    let lineStart = y1 - contentTop + s1;
    let lineEnd = y2 - contentTop + s2;
    let charStart = Math.max(0, x1 - 1);
    let charEnd = Math.max(0, x2 - 1);
    if (lineStart > lineEnd || (lineStart === lineEnd && charStart > charEnd)) {
      [lineStart, lineEnd] = [lineEnd, lineStart];
      [charStart, charEnd] = [charEnd, charStart];
    }
    if (lineStart < 0) lineStart = 0;
    const parts = [];
    for (let l = lineStart; l <= lineEnd; l++) {
      const raw = this.chatLog.getLine(l);
      if (!raw) continue;
      const clean = stripTags(raw);
      if (l === lineStart && l === lineEnd) {
        parts.push(clean.slice(charStart, charEnd));
      } else if (l === lineStart) {
        parts.push(clean.slice(charStart));
      } else if (l === lineEnd) {
        parts.push(clean.slice(0, charEnd));
      } else {
        parts.push(clean);
      }
    }
    return parts.join('\n');
  }

  /** Get the effective content width of the chat log in characters. */
  getChatWidth() {
    const w = this.chatLog.width;
    if (typeof w === 'number') return w;
    if (typeof w === 'string' && w.endsWith('%') && this.screen.width) {
      return Math.floor(this.screen.width * parseFloat(w) / 100);
    }
    return 80;
  }

  /** Render the chat using the incremental renderer + store. */
  renderChat() {
    const width = this.getChatWidth();
    const timeOf = (id) => {
      const msg = this.messageStore.find(id);
      return msg && msg.startedAt ? new Date(msg.startedAt).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) : '';
    };
    const { content, lineMap } = this.chatRenderer.render(this.messageStore, { width, time: timeOf });
    this.chatLog.setContent(content);
    this.lineMap = lineMap;
    this.chatLog.setScrollPerc(100);
  }

  toggleThinkingBlock(msg) {
    msg.expanded = !msg.expanded;
    this.renderChat();
    this.screen.render();
  }

  handleChatLogClick(mouse) {
    const scroll = this.chatLog.getScroll();
    const contentTop = (this.chatLog.atop || 0) + 1;
    const lineIdx = mouse.y - contentTop + scroll;
    if (lineIdx < 0 || lineIdx >= this.lineMap.length) return;
    const msgId = this.lineMap[lineIdx];
    if (!msgId) return;
    const msg = this.messageStore.find(msgId);
    if (!msg) return;
    if (msg.kind === 'thinking') {
      this.toggleThinkingBlock(msg);
      return;
    }
    // Click on a regular message → copy its text
    this.doCopy(msg.text);
    this.statusBar.setContent(` {green-fg}✓ Copied{/}  ·  Tab:Focus  Enter:Send  Esc:Quit  F5:Refresh  F10:Logs  Click msg:Copy`);
    this.screen.render();
    setTimeout(() => { this.updateStatusBar(); this.screen.render(); }, 2000);
  }

  appendChat(text) {
    this.messageStore.add('system', text, { kind: 'text' });
    this.renderChat();
    this.screen.render();
  }

  appendChatSafe(text) {
    this.appendChat(escapeBraces(text));
  }

  // ─── Data Refresh ─────────────────────────────────

  startRefresh() {
    this.refreshAll();
    // Gauges (CPU/Disk) update quickly for responsiveness.
    this.gaugeInterval = setInterval(() => this.refreshGauges(), GAUGE_REFRESH_MS);
    // Lower-frequency panels (tasks, goals, stats, latency).
    this.panelInterval = setInterval(() => this.refreshAll(), PANEL_REFRESH_MS);
  }

  stopRefresh() {
    if (this.gaugeInterval) {
      clearInterval(this.gaugeInterval);
      this.gaugeInterval = null;
    }
    if (this.panelInterval) {
      clearInterval(this.panelInterval);
      this.panelInterval = null;
    }
  }

  async refreshGauges() {
    try {
      const sys = await this.bridge.systemStatus().catch(() => null);
      if (sys) this.updateGaugesFromSys(sys);
      this.screen.render();
    } catch (e) {
      this.logBuffer.push('ERR', `Gauge refresh error: ${e.message}`);
    }
  }

  destroy() {
    this.stopRefresh();
    if (this.bridge && typeof this.bridge.stop === 'function') this.bridge.stop();
    if (this.screen && typeof this.screen.destroy === 'function') {
      try { this.screen.destroy(); } catch (e) {}
    }
  }

  // Calculate network speed from byte deltas
  calcNetSpeed(currentNet) {
    if (!Array.isArray(currentNet) || currentNet.length === 0) return { tx_speed: 0, rx_speed: 0 };
    const now = Date.now();
    let totalTx = 0, totalRx = 0;
    for (const iface of currentNet) {
      totalTx += iface.tx_bytes || 0;
      totalRx += iface.rx_bytes || 0;
    }
    let txSpeed = 0, rxSpeed = 0;
    if (this.prevNet.time) {
      const dt = (now - this.prevNet.time) / 1000; // seconds
      if (dt > 0) {
        txSpeed = Math.round((totalTx - this.prevNet.tx) / dt);
        rxSpeed = Math.round((totalRx - this.prevNet.rx) / dt);
      }
    }
    this.prevNet = { tx: totalTx, rx: totalRx, time: now };
    return { tx_speed: Math.max(0, txSpeed), rx_speed: Math.max(0, rxSpeed) };
  }

  formatBytes(bytes) {
    if (bytes >= 1_000_000) return (bytes / 1_000_000).toFixed(1) + ' MB/s';
    if (bytes >= 1_000) return (bytes / 1_000).toFixed(1) + ' KB/s';
    return bytes + ' B/s';
  }

  updateGaugesFromSys(sys) {
    if (!sys) return;
    // ── CPU Gauge ──
    const cpuVal = sys.cpu?.usage_percent;
    const cpuPct = Math.round(Math.min(100, Math.max(0, (cpuVal == null ? 0 : cpuVal))));
    const cores = sys.cpu?.threads || '?';
    updateGauge(this.cpuGauge, cpuPct, 'CPU UTIL', `${cores} Cores`);

    // ── Disk Gauge ──
    const disk = sys.disk?.root || {};
    const diskPct = Math.round(Math.min(100, Math.max(0, parseFloat(disk.use_percent) || 0)));
    const totalGb = disk.total_gb || 0;
    const usedGb = disk.used_gb || 0;
    const freeGb = disk.free_gb || 0;
    updateGauge(this.diskGauge, diskPct, 'FULL', `${usedGb.toFixed(1)} / ${totalGb.toFixed(1)} TB (${freeGb.toFixed(1)} TB free)`);
  }

  async refreshAll() {
    try {
      const [sys, tasks, mem, taskStats, lat] = await Promise.all([
        this.bridge.systemStatus().catch(() => null),
        this.bridge.tasksList().catch(() => []),
        this.bridge.memoryStats().catch(() => null),
        this.bridge.tasksStats().catch(() => null),
        this.bridge.systemLatency().catch(() => null),
      ]);

      if (sys) {
        this.updateGaugesFromSys(sys);

        // ── Stats Box ──
        const memInfo = sys.memory || {};
        const net = this.calcNetSpeed(sys.network);
        const netStr = `Net ↑ ${this.formatBytes(net.tx_speed)} ↓ ${this.formatBytes(net.rx_speed)}`;
        const health = sys.health || {};

        let latStr = '';
        if (lat) {
          const o = lat.ollama_ms > 0 ? `${lat.ollama_ms}ms` : 'unavailable';
          const i = lat.internet_ms > 0 ? `${lat.internet_ms}ms` : 'unavailable';
          latStr = `Ollama: ${o}  Internet: ${i}`;
        } else {
          latStr = 'Lat: measuring…';
        }

        let winsStr = '';
        if (taskStats) {
          const completed = taskStats.completed_today || 0;
          const rate = taskStats.completion_rate || 0;
          winsStr = `Wins: ${completed} (${rate}%)`;
        } else {
          winsStr = 'Wins: N/A';
        }

        this.statsBox.setContent(
          `Memory: ${memInfo.used_gb || '?'} GB (${memInfo.used_percent || '?'}%)\n` +
          `${netStr}\n` +
          `${latStr}\n` +
          `${winsStr}\n` +
          `Health: ${health.status || 'ok'} (${health.score || '?'}/100)`
        );

        this.updateTopBar(sys);
      }

      // ── Tasks Box ──
      if (Array.isArray(tasks)) {
        this.cachedTasks = tasks;
        this.tasksBox.setContent(
          tasks.length === 0
            ? '{green-fg}✓ No pending tasks{/}'
            : tasks.map(t => {
                const icon = t.priority >= 3 ? '!' : t.priority === 2 ? '→' : '✓';
                const color = t.priority >= 3 ? 'red' : t.priority === 2 ? 'yellow' : 'green';
              return `{${color}-fg}[${icon}] #${t.id}{/} ${escapeBraces(t.title)}`;
            }).join('\n')
        );
      }

      // ── Goals Box ──
      if (mem && Array.isArray(mem.goals)) {
        this.goalsBox.setContent(
          mem.goals.length === 0
            ? '{textDim}No goals set{/}'
            : mem.goals.map(g => {
                const icon = g.priority >= 2 ? '→' : '✓';
                const color = g.priority >= 2 ? 'yellow' : 'green';
                return `{${color}-fg}[${icon}]{/} ${g.goal}`;
              }).join('\n')
        );
      }

      // ── Update log panel if visible ──
      if (this.logPanel.visible) this.logPanel.refresh();

    } catch (e) {
      this.logBuffer.push('ERR', `Refresh error: ${e.message}`);
    }
    this.screen.render();
  }

  updateTopBar(sys) {
    const uptime = sys?.uptime?.formatted || 'N/A';
    const modeColors = { chat: 'cyan', plan: 'yellow', test: 'magenta', execute: 'green' };
    const color = modeColors[this.currentMode] || 'cyan';
    this.topBar.setContent(
      ` {#a8a8a8-fg}Kamila v0.2.0{/}  {${color}-fg}{bold}${this.currentMode}{/}{#a8a8a8-fg}UP: ${uptime}{/}`
    );
  }

  updateStatusBar() {
    const mode = this.panelsVisible
      ? '{cyan-fg}Panels{/}'
      : '{yellow-fg}Typing{/}';
    this.statusBar.setContent(
      ` ${mode}  ·  Tab:Focus  Enter:Send  Esc:Quit  F5:Refresh  F10:Logs  Click msg:Copy`
    );
  }
}

module.exports = KamilaApp;
