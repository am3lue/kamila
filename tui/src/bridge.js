const { spawn } = require('child_process');

class KamilaBridge {
  constructor() {
    this.pending = new Map();
    this.nextId = 1;
    this.buffer = '';
    this.ready = false;
    this.readyCallbacks = [];
    this.proc = null;
    this.onChunk = null;
    this.onThinking = null;
    this.onToolCall = null;
    this.onToolResult = null;
    this.onConfirmRequest = null;
  }

  start(juliaProjectDir) {
    return new Promise((resolve, reject) => {
      const juliaPath = process.env.JULIA_PATH || 'julia';
      this.proc = spawn(juliaPath, [
        `--project=${juliaProjectDir}`,
        '-e',
        `include("src/Kamila.jl"); using .Kamila; Kamila.KamilaBridge.run_bridge(; read_timeout=86400.0)`
      ], {
        cwd: juliaProjectDir,
        stdio: ['pipe', 'pipe', 'pipe']
      });

      this.proc.stdout.on('data', (data) => {
        this.buffer += data.toString();
        this.processBuffer();
      });

      this.proc.stderr.on('data', () => {});

      this.proc.on('close', (code) => {
        if (!this.ready) {
          reject(new Error(`Julia process exited with code ${code} before ready`));
        }
        this.ready = false;
        for (const { reject } of this.pending.values()) {
          reject(new Error('Bridge disconnected'));
        }
        this.pending.clear();
      });

      this.proc.on('error', (err) => {
        if (!this.ready) reject(err);
      });

      this.onReady(() => resolve());
    });
  }

  onReady(cb) {
    if (this.ready) {
      cb();
    } else {
      this.readyCallbacks.push(cb);
    }
  }

  processBuffer() {
    const lines = this.buffer.split('\n');
    this.buffer = lines.pop() || '';

    for (const line of lines) {
      if (!line.trim()) continue;
      try {
        const msg = JSON.parse(line);
        this.handleMessage(msg);
      } catch (e) {}
    }
  }

  handleMessage(msg) {
    if (msg.type === 'ready') {
      this.ready = true;
      for (const cb of this.readyCallbacks) cb();
      this.readyCallbacks = [];
      return;
    }

    // Confirmation requests are keyed by their own id, not a pending request,
    // so they must be handled before the pending-map lookup below.
    if (msg.type === 'confirm_request') {
      if (this.onConfirmRequest) this.onConfirmRequest(msg);
      return;
    }

    const { id } = msg;
    const handler = this.pending.get(id);
    if (!handler) return;

    if (msg.type === 'response') {
      handler.resolve(msg.result);
      this.pending.delete(id);
    } else if (msg.type === 'error') {
      handler.reject(new Error(msg.error));
      this.pending.delete(id);
    } else if (msg.type === 'stream') {
      handler.onStream(msg.chunk, { kind: msg.kind });
    } else if (msg.type === 'tool_call') {
      if (handler.onToolCall) {
        handler.onToolCall({ name: msg.name, args: msg.args, thought: msg.thought });
      } else if (this.onToolCall) {
        this.onToolCall({ name: msg.name, args: msg.args, thought: msg.thought });
      }
    } else if (msg.type === 'tool_result') {
      if (handler.onToolResult) {
        handler.onToolResult({ name: msg.name, result: msg.result });
      } else if (this.onToolResult) {
        this.onToolResult({ name: msg.name, result: msg.result });
      }
    } else if (msg.type === 'stream_end') {
      handler.resolveStream({ model: msg.model });
      this.pending.delete(id);
    }
  }

  send(method, params = {}) {
    return new Promise((resolve, reject) => {
      const id = String(this.nextId++);
      this.pending.set(id, { resolve, reject });
      const req = JSON.stringify({ type: 'request', id, method, params }) + '\n';
      this.proc.stdin.write(req);
    });
  }

  sendStream(method, params = {}, cb = {}) {
    return new Promise((resolve, reject) => {
      const id = String(this.nextId++);
      const chunks = [];
      let streamModel = '';
      this.pending.set(id, {
        resolve,
        reject,
        onStream: (chunk, meta = {}) => {
          if (meta.kind === 'thinking') {
            if (cb.onThinking) cb.onThinking(chunk);
            else if (this.onThinking) this.onThinking(chunk);
            return;
          }
          chunks.push(chunk);
          if (cb.onChunk) cb.onChunk(chunk);
          else if (this.onChunk) this.onChunk(chunk);
        },
        onToolCall: cb.onToolCall,
        onToolResult: cb.onToolResult,
        resolveStream: (meta = {}) => {
          if (meta.model) streamModel = meta.model;
          resolve({ text: chunks.join(''), model: streamModel });
        }
      });
      const req = JSON.stringify({ type: 'request', id, method, params }) + '\n';
      this.proc.stdin.write(req);
    });
  }

  // ─── System ────────────────────────────────────────

  async systemStatus() {
    return this.send('system.status');
  }

  async systemInfo() {
    return this.send('system.info');
  }

  async systemLatency() {
    return this.send('system.latency');
  }

  // ─── Tasks ─────────────────────────────────────────

  async tasksList() {
    return this.send('tasks.list');
  }

  async tasksStats() {
    return this.send('tasks.stats');
  }

  async tasksAdd(title, params = {}) {
    return this.send('tasks.add', { title, ...params });
  }

  async tasksComplete(taskId) {
    return this.send('tasks.complete', { task_id: taskId });
  }

  async tasksDelete(taskId) {
    return this.send('tasks.delete', { task_id: taskId });
  }

  // ─── AI ────────────────────────────────────────────

  async aiStatus() {
    return this.send('ai.status');
  }

  async aiModels() {
    return this.send('ai.models');
  }

  async aiQuery(prompt, opts = {}, cb = {}) {
    return this.sendStream('ai.query', { prompt, ...opts }, cb);
  }

  async agentQuery(prompt, opts = {}, cb = {}) {
    return this.sendStream('ai.agent_query', { prompt, ...opts }, cb);
  }

  async aiTestConnection() {
    return this.send('ai.test_connection');
  }

  async aiSetupModel() {
    return this.send('ai.setup_model');
  }

  async aiExplainFile(filePath, content) {
    return this.send('ai.explain_file', { path: filePath, content });
  }

  // ─── Memory ────────────────────────────────────────

  async memoryStats() {
    return this.send('memory.stats');
  }

  // ─── Chat history ───────────────────────────────────────

  async chatHistory(session = 'default') {
    return this.send('chat.history', { session });
  }

  async memoryAddGoal(goal, category = 'general', priority = 1) {
    return this.send('memory.add_goal', { goal, category, priority });
  }

  async memoryCompleteGoal(goalId) {
    return this.send('memory.complete_goal', { goal_id: goalId });
  }

  async memoryGoals() {
    return this.send('memory.goals');
  }

  // ─── File ──────────────────────────────────────────

  async fileList(dirPath) {
    return this.send('file.list', { path: dirPath || '.' });
  }

  // ─── Models ────────────────────────────────────────

  async modelList() {
    return this.send('model.list');
  }

  async modelSelect(name) {
    return this.send('model.select', { name });
  }

  async modelConfigure(action, data = {}) {
    return this.send('model.configure', { action, ...data });
  }

  // ─── Desktop ───────────────────────────────────────

  async desktopStats() {
    return this.send('desktop.stats');
  }

  async desktopOrganize(createFolders = true, moveFiles = false) {
    return this.send('desktop.organize', { create_folders: createFolders, move_files: moveFiles });
  }

  async desktopClean(daysOld = 30) {
    return this.send('desktop.clean', { days_old: daysOld });
  }

  async desktopSuggest() {
    return this.send('desktop.suggest');
  }

  async desktopHealth() {
    return this.send('desktop.health');
  }

  // ─── Auth ──────────────────────────────────────────

  async authStatus() {
    return this.send('auth.status');
  }

  async authSetup(password) {
    return this.send('auth.setup', { password });
  }

  async authChangePassword(current, newpw) {
    return this.send('auth.change_password', { current, new: newpw });
  }

  async authReset() {
    return this.send('auth.reset');
  }

  async authVerify(password) {
    return this.send('auth.verify', { password });
  }

  // ─── Code Tracker ──────────────────────────────────

  async codeTrackerStatus(dirPath) {
    return this.send('code_tracker.status', { path: dirPath || '.' });
  }

  async codeTrackerInit(dirPath) {
    return this.send('code_tracker.init', { path: dirPath || '.' });
  }

  async codeTrackerScan(dirPath) {
    return this.send('code_tracker.scan', { path: dirPath || '.' });
  }

  // ─── TTS ───────────────────────────────────────────

  async ttsSpeak(text) {
    return this.send('tts.speak', { text });
  }

  // ─── STT / Voice (08.2) ────────────────────────────

  async audioTranscribe(filePath) {
    return this.send('audio.transcribe', { file_path: filePath });
  }

  async audioRecord(seconds = 3) {
    return this.send('audio.record', { seconds });
  }

  // ─── Desktop Context (08.3) ─────────────────────────

  async desktopStatus() {
    return this.send('desktop.status', {});
  }

  async desktopScreenshot() {
    return this.send('desktop.screenshot', {});
  }

  async desktopWatch(enable) {
    return this.send('desktop.watch', { enable });
  }

  // ─── Permission ───────────────────────────────────────

  async permissionGet() {
    return this.send('permission.get');
  }

  async permissionSet(policy) {
    return this.send('permission.set', { policy });
  }

  async permissionReset() {
    return this.send('permission.reset');
  }

  async permissionDecisions(limit = 50) {
    return this.send('permission.decisions', { limit });
  }

  // ─── Lifecycle ─────────────────────────────────────

  stop() {
    if (this.proc) {
      this.proc.stdin.end();
      this.proc.kill();
      this.proc = null;
    }
  }
}

module.exports = KamilaBridge;
