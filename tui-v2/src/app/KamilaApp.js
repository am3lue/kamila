const blessed = require('blessed');
const { RegionManager } = require('../layout/RegionManager');
const { TerminalBox } = require('../components/TerminalBox');
const { HeaderBar } = require('../components/HeaderBar');
const { ChatLog } = require('../components/ChatLog');
const { ChatInput } = require('../components/ChatInput');
const { VoiceIndicator } = require('../components/VoiceIndicator');
const { InputEditorModal } = require('../components/overlays/InputEditorModal');
const { ConfirmOverlay } = require('../components/overlays/ConfirmOverlay');
const { LogPanel } = require('../components/overlays/LogPanel');
const { PermissionPanel } = require('../components/overlays/PermissionPanel');
const { CommandPalette } = require('../components/overlays/CommandPalette');
const { ContextMenu } = require('../components/overlays/ContextMenu');
const { MessageStore } = require('../store/MessageStore');
const { UIState } = require('../store/UIState');
const { Keybindings } = require('../input/Keybindings');
const { FocusManager } = require('../components/common/FocusManager');
const { theme } = require('../theme/TerminalTheme');
const Bridge = require('../bridge');

const GAUGE_REFRESH_MS = 500;
const PANEL_REFRESH_MS = 2000;
const DESKTOP_REFRESH_MS = 5000;

class KamilaApp {
  constructor(bridge, screen) {
    this.bridge = bridge;
    this.screen = screen;
    this.regionManager = new RegionManager(screen);
    this.messageStore = new MessageStore();
    this.uiState = new UIState();
    this._voiceCancelled = false;
    this.focusManager = new FocusManager();
    this.keybindings = new Keybindings(screen, this.focusManager);
    const os = require('os');
    const path = require('path');
    const fs = require('fs');
    const tuiLogDir = path.join(process.env.KAMILA_HOME || path.join(os.homedir(), '.kamila'), 'logs');
    const tuiLogFile = path.join(tuiLogDir, 'tui.log');
    try { fs.mkdirSync(tuiLogDir, { recursive: true }); } catch (e) {}
    this.logBuffer = {
      entries: [],
      push: (level, origin, kind, msg) => {
        const entry = { time: new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' }), level, origin, kind, msg: String(msg) };
        this.logBuffer.entries.push(entry);
        if (this.logBuffer.entries.length > 1000) this.logBuffer.entries.shift();
        try {
          fs.appendFileSync(tuiLogFile, JSON.stringify({ ts: new Date().toISOString(), level, origin, kind, msg: String(msg) }) + '\n');
        } catch (e) {}
      },
      getAll: () => this.logBuffer.entries,
      clear: () => { this.logBuffer.entries = []; },
    };
    this.gaugeInterval = null;
    this.panelInterval = null;
    this.desktopInterval = null;
    this.prevNet = { tx: 0, rx: 0, time: Date.now() };
    this.currentMode = 'chat';
    this.recallRing = [];
    this.recallIndex = -1;
    this.activeStreaming = null;
    this.statusMsg = null;

    this._defineRegions();
    this._createComponents();
    this._setupBridgeHandlers();
    this._setupKeybindings();
    this._startRefreshLoops();
    this.chatInput.focus();

    this.regionManager.on('change', () => this._onResize());
    this.uiState.on('change', (key, val) => this._onUIStateChange(key, val));
  }

  _defineRegions() {
    const rm = this.regionManager;
    rm.define('header', { x: 0, y: 0, width: '100%', height: 1 });
    rm.define('input', { x: 0, y: '100%-4', width: '100%', height: 4, minHeight: 4 });
    rm.define('inspector', { x: '100%-28%', y: 1, width: '28%', height: 'above:input', minWidth: 24 });
    rm.define('chat', { x: 0, y: 1, width: 0, height: 'above:input', fillTo: 'inspector' });
    rm.calculate();
  }

  _createComponents() {
    const InspectorPanel = require('../components/panels/InspectorPanel').InspectorPanel;
    this.headerBar = new HeaderBar(this.screen, this.regionManager, this);
    this.chatLog = new ChatLog(this.screen, this.regionManager, this.messageStore, this);
    this.chatInput = new ChatInput(this.screen, this.regionManager, this);
    this.voiceIndicator = new VoiceIndicator(this.screen, this.regionManager, this);
    this.inspectorPanel = new InspectorPanel(this.screen, this.regionManager, this);
    this.inputEditorModal = new InputEditorModal(this.screen, this);
    this.logPanel = new LogPanel(this.screen, this.logBuffer);
    this.permissionPanel = new PermissionPanel(this.screen, this.bridge);
    this.commandPalette = new CommandPalette(this.screen, this);
    this.toastStack = new (require('../components/overlays/ToastStack').ToastStack)(this.screen, this);
    this.logPanel.create();
    this.permissionPanel.create();

    this.headerBar.create();
    this.chatLog.create();
    this.chatInput.create();
    this.voiceIndicator.create();
    this.inspectorPanel.create();

    this.chatInput.onSubmit = (text) => this._handleSubmit(text);
    this.chatInput.onKeyPress = (ch, key) => this._onInputKeyPress(ch, key);
    this.focusManager.register('chatInput', this.chatInput.input, { type: 'input' });
    this.focusManager.register('chatLog', this.chatLog.logBox, { type: 'chat' });
    this.focusManager.register('inspector', this.inspectorPanel.box, { type: 'inspector' });

    this.inspectorPanel.box.on('click', (mouse) => this.inspectorPanel.handleClick(mouse));

    this.focusManager.on('focusChange', (name) => this._applyFocusBorders(name));
    this._applyFocusBorders(this.focusManager.getFocus());
  }

  _setupBridgeHandlers() {
    this.bridge.on('confirm_request', (msg) => {
      ConfirmOverlay.show(this.screen, {
        command: msg.command,
        description: msg.description,
        rule: msg.rule,
        onConfirm: (answer) => this.bridge.respondConfirm(msg.id, answer.allow, answer.force),
      });
    });

    this.bridge.on('desktop_activity', (msg) => {
      this._fetchDesktopContext();
    });

    this.bridge.on('permission_changed', () => {
      if (this.permissionPanel.visible) this.permissionPanel.refresh();
    });

    this.bridge.on('notification', (msg) => {
      const kind = msg.kind === 'health.alert' ? 'warn' : (msg.kind === 'file.created' || msg.kind === 'file.updated' ? 'info' : 'info');
      this.toastStack.push(msg.body || msg.title || 'Notification', {
        title: msg.source || msg.title || 'Kamila',
        kind,
        duration: 5,
        hint: `${msg.kind} · esc to dismiss`,
      });
      this.logBuffer.push('warn', 'system', msg.kind, `${msg.title}: ${msg.body}`);
    });
  }

  _streamHandlers() {
    return {
      onThinking: (chunk) => {
        if (!this.activeStreaming || this.activeStreaming.kind !== 'thinking') {
          if (this.statusMsg) { this.messageStore.remove(this.statusMsg.id); this.statusMsg = null; }
          this.activeStreaming = this.messageStore.beginStream('assistant', { kind: 'thinking' });
        }
        this.activeStreaming.text += chunk;
        this.chatLog.render();
        this.screen.render();
      },
      onChunk: (chunk) => {
        if (!this.activeStreaming || this.activeStreaming.kind === 'thinking') {
          if (this.statusMsg) { this.messageStore.remove(this.statusMsg.id); this.statusMsg = null; }
          this.activeStreaming = this.messageStore.beginStream('assistant');
        }
        this.activeStreaming.text += chunk;
        this.chatLog.render();
        this.screen.render();
      },
      onToolCall: (ev) => {
        this.messageStore.add('tool', ev.name, { kind: 'tool' });
        this.chatLog.render();
        this.screen.render();
      },
      onToolResult: (ev) => {
        const preview = (ev.result || '').slice(0, 80);
        this.messageStore.add('tool', `→ ${preview}`, { kind: 'toolresult' });
        this.chatLog.render();
        this.screen.render();
      },
    };
  }

  _setupKeybindings() {
    this.keybindings.on('refresh.all', () => this.refreshAll());
    this.keybindings.on('logs.toggle', () => this.logPanel.toggle());
    this.keybindings.on('permissions.toggle', () => { if (this.permissionPanel.visible) this.permissionPanel.hide(); else this.permissionPanel.open(); });
    this.keybindings.on('sidebar.toggle', () => this._togglePanels());
    this.keybindings.on('palette.open', () => this.commandPalette.open());
    this.keybindings.on('voice.recordQuick', () => this._startVoiceRecord(5));
    this.keybindings.on('editor.open', () => this.openInputEditor(this.chatInput.getValue()));
    this.keybindings.on('delete.contextual', () => this._contextualDelete());
    this.keybindings.on('input.focus', () => this.chatInput.focus());
    this.keybindings.on('overlay.dismiss', () => this._dismissOverlays());
    this.keybindings.on('app.quit', () => this.quitApp());

    this.screen.key(['escape'], () => this._dismissOverlays());
    this.screen.key(['tab'], () => this.chatInput.focus());
  }

  _startRefreshLoops() {
    this.gaugeInterval = setInterval(() => this.refreshGauges(), GAUGE_REFRESH_MS);
    this.panelInterval = setInterval(() => this.refreshAll(), PANEL_REFRESH_MS);
    this.desktopInterval = setInterval(() => this._fetchDesktopContext(), DESKTOP_REFRESH_MS);
    this.refreshAll();
  }

  async _hydrateHistory() {
    try {
      const r = await Bridge.memory.history(this.bridge);
      if (r && Array.isArray(r.messages) && r.messages.length) {
        this.messageStore.hydrate(r.messages);
        this.chatLog.render();
        this.screen.render();
      }
    } catch (e) {
      this.logBuffer.push('error', 'memory', 'history', `History hydrate failed: ${e.message}`);
    }
  }

  onBackendReady() {
    this.setStatusHint('');
    this.refreshAll();
    this._hydrateHistory();
    this.logBuffer.push('info', 'bridge', 'lifecycle', 'Julia backend ready');
  }

  onBackendError(e) {
    this.setStatusHint(`{red-fg}Backend failed: ${e.message}{/}`);
    this.logBuffer.push('error', 'bridge', 'lifecycle', `Julia backend failed: ${e.message}`);
  }

  quitApp() {
    // Never kill the app mid-capture; treat an accidental quit like Esc (cancel).
    if (this.uiState.get('voiceRecording')) {
      this._cancelVoiceRecord();
      return;
    }
    this.bridge.stop();
    process.exit(0);
  }

  _onResize() {
    this.regionManager.calculate();
    this.headerBar.onResize();
    this.chatLog.onResize();
    this.chatInput.onResize();
    this.voiceIndicator.onResize();
    this.inspectorPanel.onResize();
    this.screen.render();
  }

  _onUIStateChange(key, val) {
    switch (key) {
      case 'currentMode': this.headerBar.setMode(val); this.currentMode = val; break;
      case 'panelsVisible': break;
      case 'statusHint': this.chatInput.setHint(val); break;
      case 'voiceRecording': this.uiState.set('voiceRecording', val); break;
    }
  }

  _applyFocusBorders(name) {
    const targets = [
      ['chat', this.chatLog && this.chatLog.box],
      ['inspector', this.inspectorPanel && this.inspectorPanel.box],
    ];
    for (const [n, box] of targets) {
      if (box && typeof box.setFocusBorder === 'function') box.setFocusBorder(name === n);
    }
  }

  resizeInputTo(lines) {
    const maxH = Math.max(4, Math.floor(this.screen.height * 0.3));
    const h = Math.max(4, Math.min(3 + lines, maxH));
    this.regionManager.define('input', { x: 0, y: `100%-${h}`, width: '100%', height: h, minHeight: 4 });
    this.regionManager.calculate();
    this._onResize();
  }

  _togglePanels() {
    const visible = !this.uiState.get('panelsVisible');
    this.uiState.set('panelsVisible', visible);
    this.regionManager.define('inspector', visible
      ? { x: '100%-28%', y: 1, width: '28%', height: 'above:input', minWidth: 24 }
      : { x: '100%', y: 1, width: 0, height: 'above:input', minWidth: 0 });
    this.regionManager.calculate();
    this._onResize();
    if (this.inspectorPanel.box) visible ? this.inspectorPanel.box.show() : this.inspectorPanel.box.hide();
    this.screen.render();
  }

  _dismissOverlays() {
    // Esc while voice is recording cancels the capture, never quits the app.
    // Otherwise an accidental Esc mid-capture kills the app + in-flight promise.
    if (this.uiState.get('voiceRecording')) {
      this._cancelVoiceRecord();
      return;
    }
    // While composing in the input, Esc only dismisses overlays. It must never
    // fall through to exit: terminals can decode a modifier+Enter (e.g. a
    // Shift+Enter that sends "\x1b\r") as an escape key, which would otherwise
    // quit the app mid-composition.
    if (this.chatInput && this.chatInput.active) {
      if (this.commandPalette.visible) { this.commandPalette.hide(); this.screen.render(); return; }
      if (this.logPanel.visible) { this.logPanel.hide(); this.screen.render(); return; }
      if (this.permissionPanel.visible) { this.permissionPanel.hide(); this.screen.render(); return; }
      if (this.inputEditorModal.visible) { this.inputEditorModal.hide(); this.screen.render(); return; }
      if (this.taskActionOverlay?.visible) { this.taskActionOverlay.hide(); this.screen.render(); return; }
      if (this.toastStack && this.toastStack.toasts.length) { this.toastStack.clear(); this.screen.render(); }
      return;
    }
    if (this.commandPalette.visible) { this.commandPalette.hide(); return; }
    if (this.logPanel.visible) { this.logPanel.hide(); return; }
    if (this.permissionPanel.visible) { this.permissionPanel.hide(); return; }
    if (this.inputEditorModal.visible) { this.inputEditorModal.hide(); return; }
    if (this.taskActionOverlay?.visible) { this.taskActionOverlay.hide(); return; }
    if (this.toastStack && this.toastStack.toasts.length) { this.toastStack.clear(); return; }
    this.bridge.stop();
    process.exit(0);
  }

  _cancelVoiceRecord() {
    this._voiceCancelled = true;
    this.voiceIndicator.cancel();
    this.uiState.set('voiceRecording', false);
    this.uiState.set('voiceSeconds', 0);
    this.chatInput.setHint('');
    this._appendChat('{textDim}Voice recording cancelled.{/}');
    this.chatInput.focus();
    this.screen.render();
  }

  _contextualDelete() {
    const focus = this.focusManager.getFocus();
    switch (focus) {
      case 'inspector':
        if (this.inspectorPanel.tasks.length) this._confirmDeleteTask(this.inspectorPanel.tasks[0]);
        break;
      case 'chat': {
        const msg = this.messageStore.getLastAssistant();
        if (msg) this._confirmDeleteMessage(msg);
        break;
      }
      case 'input':
        if (this.chatInput.getValue()) {
          ConfirmOverlay.show(this.screen, { message: 'Clear input?', onConfirm: (a) => { if (a.allow) { this.chatInput.clearValue(); this.screen.render(); } } });
        }
        break;
      default:
        this.setStatusHint('{textDim}Nothing to delete{/}');
    }
  }

  _confirmDeleteMessage(msg) {
    ConfirmOverlay.show(this.screen, { message: `Delete message #${msg.id}?`, onConfirm: (a) => { if (a.allow) { this.messageStore.remove(msg.id); this.chatLog.render(); this.screen.render(); } } });
  }

  _confirmDeleteTask(task) {
    ConfirmOverlay.show(this.screen, { message: `Delete task #${task.id}: ${task.title}?`, onConfirm: async (a) => { if (a.allow) { await Bridge.tasks.delete(this.bridge, task.id); this.refreshTasks(); } } });
  }

  async _handleSubmit(text) {
    if (!text) return;
    if (!this.bridge.ready) {
      this._appendChat('{yellow-fg}Backend still starting — please wait a moment…{/}');
      return;
    }
    if (text.startsWith('/')) {
      this.logBuffer.push('info', 'tui', 'command', text);
      await this._handleCommand(text);
      this.screen.render();
      return;
    }

    this.messageStore.add('user', text);
    this.logBuffer.push('info', 'tui', 'chat', `<You>: ${text}`);
    this.chatLog.render();
    this.screen.render();

    this.statusMsg = this.messageStore.add('system', '⟳ Thinking...', { kind: 'status' });
    this.chatLog.render();
    this.screen.render();

    const handlers = this._streamHandlers();

    try {
      const startTime = Date.now();
      const response = await Bridge.ai.query(this.bridge, text, { task_type: 'chat', mode: this.currentMode }, handlers);
      const elapsed = ((Date.now() - startTime) / 1000).toFixed(1);
      if (this.activeStreaming) {
        this.activeStreaming.elapsed = `${elapsed}s`;
        this.activeStreaming.model = response.model || '';
        this.messageStore.finish(this.activeStreaming.id, { model: response.model, elapsed: `${elapsed}s` });
        this.activeStreaming = null;
      }
      this.chatInput.setModel(response.model || '');
      this.logBuffer.push('info', 'tui', 'chat', `<Kamila>: ${(response.text || '').slice(0, 120)}`);
    } catch (e) {
      if (this.statusMsg) this.messageStore.remove(this.statusMsg.id);
      this.messageStore.add('error', `Error: ${e.message}`, { kind: 'error' });
      this.logBuffer.push('error', 'ai', 'error', `AI query failed: ${e.message}`);
    }
    this.statusMsg = null;
    this.chatLog.render();
    this.screen.render();
  }

  async _handleCommand(text) {
    const parts = text.split(' ');
    const cmd = parts[0].toLowerCase();

    switch (cmd) {
      case '/help':
        this._showHelp();
        break;
      case '/clear':
        this.messageStore.clear();
        this.chatLog.render();
        break;
      case '/reset':
        this.messageStore.clear();
        this.chatLog.render();
        try { await this.bridge.send('chat.reset', {}); } catch (e) {}
        this._appendChat('{yellow-fg}Chat history cleared.{/}');
        break;
      case '/copy':
        this._copyLastResponse();
        break;
      case '/mode': {
        const modeArg = parts[1];
        if (!modeArg) { this._appendChat(`{cyan-fg}Current mode: {bold}${this.currentMode}{/}  Available: chat, plan, test, execute{/}`); break; }
        const valid = ['chat', 'plan', 'test', 'execute'];
        if (!valid.includes(modeArg)) { this._appendChat(`{red-fg}Invalid mode. Available: ${valid.join(', ')}{/}`); break; }
        try {
          const r = await this.bridge.send('mode.set', { mode: modeArg });
          this.uiState.set('currentMode', r.mode);
          this.messageStore.clear();
          this.chatLog.render();
          this._appendChat(`{green-fg}Switched to {bold}${r.mode}{/} mode. History cleared.{/}`);
        } catch (e) { this._appendChat(`{red-fg}Failed to switch mode: ${e.message}{/}`); }
        break;
      }
      case '/status': {
        try {
          const s = await Bridge.system.status(this.bridge);
          this._appendChat(`{cyan-fg}CPU: ${s.cpu?.usage_percent != null ? s.cpu.usage_percent + '%' : 'unavailable'} | Mem: ${s.memory?.used_percent || '?'}% | Disk: ${s.disk?.root?.use_percent || '?'}% | Uptime: ${s.uptime?.formatted || '?'}{/}`);
        } catch (e) { this._appendChat(`{red-fg}Status error: ${e.message}{/}`); }
        break;
      }
      case '/task':
      case '/tasks':
        await this._handleTaskCommand(parts.slice(1));
        break;
      case '/model':
      case '/models':
        await this._handleModelCommand(parts.slice(1));
        break;
      case '/agent': {
        const prompt = parts.slice(1).join(' ');
        if (!prompt) { this._appendChat('{red-fg}Usage: /agent <prompt>{/}'); return; }
        this._runAgent(prompt);
        break;
      }
      case '/context':
        await this._fetchDesktopContext(true);
        break;
      case '/watch': {
        const arg = parts[1];
        let enable = arg === 'on' || arg === '1' || arg === 'true';
        if (arg === 'off' || arg === '0' || arg === 'false') enable = false;
        if (arg === undefined) enable = null;
        try {
          if (enable === null) {
            const current = await Bridge.desktop.status(this.bridge);
            enable = !current.watch_enabled;
          }
          const r = await Bridge.desktop.watch(this.bridge, enable);
          this._appendChat(r.watch_enabled ? '{green-fg}✓ Desktop watcher ON{/}' : '{yellow-fg}Desktop watcher OFF{/}');
          this._fetchDesktopContext();
        } catch (e) { this._appendChat(`{red-fg}Watch toggle failed: ${e.message}{/}`); }
        break;
      }
      case '/shot':
        this._takeScreenshot();
        break;
      case '/record': {
        const seconds = parseInt(parts[1], 10) || 5;
        this._startVoiceRecord(seconds);
        break;
      }
      case '/transcribe': {
        const file = parts.slice(1).join(' ');
        if (!file) { this._appendChat('{red-fg}Usage: /transcribe <file>{/}'); break; }
        this._transcribeFile(file);
        break;
      }
      case '/perm':
        if (this.permissionPanel.visible) this.permissionPanel.hide(); else this.permissionPanel.open();
        break;
      default:
        this._appendChat(`{red-fg}Unknown: ${cmd}. Type /help{/}`);
    }
  }

  _showHelp() {
    this._appendChat('{yellow-fg}Commands:{/}');
    this._appendChat('  /help  /clear  /reset  /copy  /status  /mode [chat|plan|test|execute]');
    this._appendChat('  /task add "title" [--priority N] [--desc "text"] [--time N]  /task done <id>  /task rm <id>  /tasks');
    this._appendChat('  /model list  /model select <name>');
    this._appendChat('  /agent <prompt>');
    this._appendChat('  /context  /watch [on|off]  /shot');
    this._appendChat('  /record [seconds]  /transcribe <file>');
    this._appendChat('  /perm');
    this._appendChat('  {textDim}Keys: F5/C-S-R refresh | F10/C-S-L logs | F11/C-A-P perms | C-T panels | C-P palette | C-R voice | C-O editor | C-D delete | Tab focus{/}');
  }

  async _handleTaskCommand(args) {
    const sub = args[0]?.toLowerCase();
    if (!sub || sub === 'list') { await this.refreshTasks(); return; }
    if (sub === 'add') {
      let title = '', priority = 2, description = '', estimated_time = 30;
      const remaining = args.slice(1).join(' ');
      const titleMatch = remaining.match(/^"([^"]+)"|^(\S+)/);
      if (titleMatch) title = titleMatch[1] || titleMatch[2];
      const prioMatch = remaining.match(/--priority\s+(\d+)/i);
      if (prioMatch) priority = Math.min(4, Math.max(1, parseInt(prioMatch[1])));
      const descMatch = remaining.match(/--desc\s+"([^"]+)"/i);
      if (descMatch) description = descMatch[1];
      const timeMatch = remaining.match(/--time\s+(\d+)/i);
      if (timeMatch) estimated_time = parseInt(timeMatch[1]);
      if (!title) { this._appendChat('{red-fg}Usage: /task add "<title>" [--priority N] [--desc "text"] [--time N]{/}'); return; }
      try {
        const result = await Bridge.tasks.add(this.bridge, title, { priority, description, estimated_time });
        this._appendChat(`{green-fg}✓ Task #${result.id} added: ${result.title}{/}`);
        this.refreshTasks();
      } catch (e) { this._appendChat(`{red-fg}Add task error: ${e.message}{/}`); }
      return;
    }
    if (sub === 'done' || sub === 'complete') {
      const id = parseInt(args[1]);
      if (isNaN(id)) { this._appendChat('{red-fg}Usage: /task done <task_id>{/}'); return; }
      try { await Bridge.tasks.complete(this.bridge, id); this._appendChat(`{green-fg}✓ Task #${id} completed{/}`); this.refreshTasks(); }
      catch (e) { this._appendChat(`{red-fg}Complete error: ${e.message}{/}`); }
      return;
    }
    if (sub === 'rm' || sub === 'delete') {
      const id = parseInt(args[1]);
      if (isNaN(id)) { this._appendChat('{red-fg}Usage: /task rm <task_id>{/}'); return; }
      try { await Bridge.tasks.delete(this.bridge, id); this._appendChat(`{yellow-fg}✗ Task #${id} deleted{/}`); this.refreshTasks(); }
      catch (e) { this._appendChat(`{red-fg}Delete error: ${e.message}{/}`); }
      return;
    }
    this._appendChat(`{red-fg}Unknown subcommand: ${sub}. Use: add, done, rm, list{/}`);
  }

  async _handleModelCommand(args) {
    const sub = args[0]?.toLowerCase();
    if (!sub || sub === 'list') {
      try {
        const m = await Bridge.models.list(this.bridge);
        this._appendChat(`{cyan-fg}Active: ${m.active}{/}`);
        if (Array.isArray(m.available) && m.available.length) {
          this._appendChat('{textDim}Available:{/}');
          m.available.forEach(n => this._appendChat(`  {textDim}${n.name || n}{/}`));
        }
      } catch (e) { this._appendChat(`{red-fg}Model list error: ${e.message}{/}`); }
      return;
    }
    if (sub === 'select') {
      const name = args.slice(1).join(' ');
      if (!name) { this._appendChat('{red-fg}Usage: /model select <model_name>{/}'); return; }
      try { const r = await Bridge.models.select(this.bridge, name); this._appendChat(`{green-fg}✓ Switched to: ${r.active}{/}`); }
      catch (e) { this._appendChat(`{red-fg}Model select error: ${e.message}{/}`); }
      return;
    }
    this._appendChat(`{red-fg}Unknown: ${sub}. Use: /model list, /model select <name>{/}`);
  }

  async _runAgent(prompt) {
    this.statusMsg = this.messageStore.add('system', '⟳ Agent running...', { kind: 'status' });
    this.chatLog.render(); this.screen.render();
    try {
      const response = await Bridge.ai.agentQuery(this.bridge, prompt, {}, this._streamHandlers());
      if (this.activeStreaming) { this.messageStore.finish(this.activeStreaming.id, { model: response.model }); this.activeStreaming = null; }
      else { this.messageStore.remove(this.statusMsg.id); this.messageStore.add('assistant', ''); }
      this.chatInput.setModel(response.model || '');
      this.logBuffer.push('info', 'tui', 'chat', `<Agent>: ${response.text.slice(0, 120)}`);
    } catch (e) {
      if (this.statusMsg) this.messageStore.remove(this.statusMsg.id);
      this.messageStore.add('error', `Agent error: ${e.message}`, { kind: 'error' });
      this.logBuffer.push('error', 'ai', 'error', `Agent error: ${e.message}`);
    }
    this.statusMsg = null;
    this.chatLog.render(); this.screen.render();
  }

  async _fetchDesktopContext(showInChat = false) {
    if (!this.bridge.ready) return;
    if (showInChat) {
      const status = this.messageStore.add('system', '⟳ Reading desktop context...', { kind: 'status' });
      this.chatLog.render(); this.screen.render();
      try {
        const ctx = await Bridge.desktop.status(this.bridge);
        this.inspectorPanel.setDesktopContext(ctx);
        this.messageStore.remove(status.id);
        this._appendChat('{cyan-fg}Desktop context:{/}');
        this._appendChat(`{yellow-fg}  Session:{/} ${ctx.session || 'unknown'}`);
        this._appendChat(`{yellow-fg}  Active window:{/} ${ctx.active_window || '— unavailable'}`);
        this._appendChat(`{yellow-fg}  CWD:{/} ${ctx.cwd || '— unavailable'}`);
        this._appendChat(`{yellow-fg}  Watch:{/} ${ctx.watch_enabled ? '{green-fg}on{/}' : 'off'}`);
        const clip = ctx.clipboard || '— unavailable';
        this._appendChat(`{yellow-fg}  Clipboard:{/} ${clip.length > 120 ? clip.slice(0, 120) + '…' : clip}`);
      } catch (e) {
        this.messageStore.remove(status.id);
        this._appendChat(`{red-fg}Context error: ${e.message}{/}`);
      }
    } else {
      try {
        const ctx = await Bridge.desktop.status(this.bridge);
        this.inspectorPanel.setDesktopContext(ctx);
      } catch (e) {}
    }
  }

  async _takeScreenshot() {
    const status = this.messageStore.add('system', '⟳ Capturing & describing screen...', { kind: 'status' });
    this.chatLog.render(); this.screen.render();
    try {
      const r = await Bridge.desktop.screenshot(this.bridge);
      this.messageStore.remove(status.id);
      this._appendChat('{cyan-fg}Screen description:{/}');
      this._appendChat(r.description || '{red-fg}No description returned.{/}');
    } catch (e) {
      this.messageStore.remove(status.id);
      this._appendChat(`{red-fg}Screenshot failed: ${e.message}{/}`);
    }
  }

  _startVoiceRecord(seconds) {
    this._voiceCancelled = false;
    this.uiState.set('voiceRecording', true);
    this.uiState.set('voiceSeconds', 0);
    this.uiState.set('voiceTotalSeconds', seconds);
    this.voiceIndicator.start(seconds);
    this.chatInput.setHint('{yellow-fg}🎤 Recording... Press Esc to cancel{/}');
    this.screen.render();

    Bridge.audio.record(this.bridge, seconds)
      .then(rec => {
        if (this._voiceCancelled) return;  // user cancelled via Esc; ignore late result
        this.voiceIndicator.stop();
        this.uiState.set('voiceRecording', false);
        const text = (rec && rec.text) || '';
        this.voiceIndicator.cancel();
        this.chatInput.setHint('');
        if (!text) { this._appendChat('{red-fg}No speech recognized{/}'); return; }
        this.chatInput.setValue(text);
        this.chatInput.focus();
        this._appendChat(`{cyan-fg}🎤 Draft (edit then Enter to send):{/}`);
        this._appendChat(`{yellow-fg}  ${text}{/}`);
        this.logBuffer.push('info', 'audio', 'voice', `Draft: ${text}`);
      })
      .catch(e => {
        if (this._voiceCancelled) return;
        this.voiceIndicator.stop();
        this.uiState.set('voiceRecording', false);
        this.voiceIndicator.cancel();
        this.chatInput.setHint('');
        this._appendChat(`{red-fg}Recording failed: ${e.message}{/}`);
        this.logBuffer.push('error', 'audio', 'voice', `Record failed: ${e.message}`);
      });
  }

  async _transcribeFile(file) {
    const status = this.messageStore.add('system', '⟳ Transcribing...', { kind: 'status' });
    this.chatLog.render(); this.screen.render();
    try {
      const r = await Bridge.audio.transcribe(this.bridge, file);
      this.messageStore.remove(status.id);
      this._appendChat('{cyan-fg}Transcription:{/}');
      this._appendChat(r.text || '{red-fg}No text returned.{/}');
    } catch (e) {
      this.messageStore.remove(status.id);
      this._appendChat(`{red-fg}Transcribe failed: ${e.message}{/}`);
    }
  }

  async refreshGauges() {
    if (!this.bridge.ready) return;
    try {
      const sys = await Bridge.system.status(this.bridge);
      if (sys) {
        const cpu = sys.cpu?.usage_percent || 0;
        const ram = sys.memory?.used_percent || 0;
        this.inspectorPanel.setGauges(cpu, ram);
        this.inspectorPanel.setStats(sys);
        this.uiState.set('cpu', cpu);
        this.uiState.set('ram', ram);
      }
    } catch (e) {
      this.logBuffer.push('error', 'system', 'monitor', `Gauge refresh error: ${e.message}`);
    }
  }

  async refreshTasks() {
    if (!this.bridge.ready) return;
    try {
      const [tasks, taskStats] = await Promise.all([
        Bridge.tasks.list(this.bridge).catch(() => []),
        Bridge.tasks.stats(this.bridge).catch(() => null),
      ]);
      this.inspectorPanel.setTasks(tasks);
      if (taskStats) this.inspectorPanel.setStats({ tasks: taskStats });
    } catch (e) {
      this.logBuffer.push('error', 'tasks', 'system', `Tasks refresh error: ${e.message}`);
    }
  }

  async refreshAll() {
    await this.refreshGauges();
    await this.refreshTasks();
    await this._fetchDesktopContext();
  }

  showTaskAction(task) {
    if (!this.taskActionOverlay) {
      this.taskActionOverlay = new (require('../components/overlays/TaskActionOverlay').TaskActionOverlay)(this.screen);
    }
    this.taskActionOverlay.show(task, {
      onComplete: async (t) => {
        try { await Bridge.tasks.complete(this.bridge, t.id); this._appendChat(`{green-fg}✓ Task #${t.id} completed{/}`); this.refreshTasks(); }
        catch (e) { this._appendChat(`{red-fg}Complete error: ${e.message}{/}`); }
      },
      onDelete: async (t) => {
        try { await Bridge.tasks.delete(this.bridge, t.id); this._appendChat(`{yellow-fg}✗ Task #${t.id} deleted{/}`); this.refreshTasks(); }
        catch (e) { this._appendChat(`{red-fg}Delete error: ${e.message}{/}`); }
      },
    });
  }

  toggleDesktopWatch() {
    const current = this.inspectorPanel.desktopContext?.watch_enabled;
    Bridge.desktop.watch(this.bridge, !current).then(r => {
      this._appendChat(r.watch_enabled ? '{green-fg}✓ Desktop watcher ON{/}' : '{yellow-fg}Desktop watcher OFF{/}');
      this._fetchDesktopContext();
    });
  }

  openInputEditor(content) {
    this.inputEditorModal.open(content,
      (saved) => { this.chatInput.setValue(saved); this.chatInput.focus(); },
      (original) => { this.chatInput.setValue(original); this.chatInput.focus(); }
    );
  }

  executeCommand(cmd) {
    this.chatInput.setValue(cmd);
    this._handleSubmit(cmd);
  }

  setInputValue(val) { this.chatInput.setValue(val); }
  focusInput() { this.chatInput.focus(); }
  setStatusHint(hint) { this.chatInput.setHint(hint); }
  getCPU() { return this.uiState.get('cpu') || 0; }
  getRAM() { return this.uiState.get('ram') || 0; }

  _appendChat(text) {
    this.messageStore.add('system', text, { kind: 'text' });
    this.chatLog.render();
    this.screen.render();
  }

  _copyLastResponse() {
    const msg = this.messageStore.getLastAssistant();
    if (!msg) { this.setStatusHint('{red-fg}No response to copy{/}'); return; }
    this._doCopy(msg.text);
  }

  _doCopy(text) {
    const fs = require('fs');
    const { execSync } = require('child_process');
    const tmpFile = `/tmp/kamila_copy_${process.pid}_${Date.now()}.txt`;
    let wrote = false;
    try { fs.writeFileSync(tmpFile, text, 'utf8'); wrote = true; } catch (e) {}
    try { execSync(`xclip -selection clipboard < ${tmpFile} 2>/dev/null`, { stdio: 'ignore' }); this.toastStack.push('Copied to clipboard', { kind: 'success', duration: 2 }); return true; } catch (e) {}
    try { execSync(`xsel -ib < ${tmpFile} 2>/dev/null`, { stdio: 'ignore' }); this.toastStack.push('Copied to clipboard', { kind: 'success', duration: 2 }); return true; } catch (e) {}
    try { this.screen.copyToClipboard(text); this.toastStack.push('Copied to clipboard', { kind: 'success', duration: 2 }); return true; } catch (e) {}
    if (wrote) this.toastStack.push('Saved to temp file (clipboard unavailable)', { kind: 'warn', duration: 3 });
    return wrote;
  }

  _onInputKeyPress(ch, key) {
    // Reserved for future input-driven actions; editing keys are handled by ChatInput.
  }

  destroy() {
    if (this.gaugeInterval) clearInterval(this.gaugeInterval);
    if (this.panelInterval) clearInterval(this.panelInterval);
    if (this.desktopInterval) clearInterval(this.desktopInterval);
    this.bridge.stop();
  }
}

module.exports = { KamilaApp };