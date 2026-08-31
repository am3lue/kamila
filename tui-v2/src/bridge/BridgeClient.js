const { spawn } = require('child_process');
const EventEmitter = require('events');

class BridgeClient extends EventEmitter {
  constructor() {
    super();
    this.pending = new Map();
    this.nextId = 1;
    this.buffer = '';
    this.ready = false;
    this.readyCallbacks = [];
    this.proc = null;
    this.handlers = {
      onChunk: null,
      onThinking: null,
      onToolCall: null,
      onToolResult: null,
      onConfirmRequest: null,
      onDesktopActivity: null,
      onPermissionChanged: null,
      onNotification: null,
    };
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
        this._processBuffer();
      });

      this.proc.stderr.on('data', (data) => {
        this.emit('stderr', data.toString());
      });

      this.proc.on('close', (code) => {
        if (!this.ready) {
          reject(new Error(`Julia process exited with code ${code} before ready`));
        }
        this.ready = false;
        for (const { reject } of this.pending.values()) {
          reject(new Error('Bridge disconnected'));
        }
        this.pending.clear();
        this.emit('close', code);
      });

      this.proc.on('error', (err) => {
        if (!this.ready) reject(err);
        this.emit('error', err);
      });

      this.onReady(() => resolve());
    });
  }

  onReady(cb) {
    if (this.ready) cb();
    else this.readyCallbacks.push(cb);
  }

  _processBuffer() {
    const lines = this.buffer.split('\n');
    this.buffer = lines.pop() || '';
    for (const line of lines) {
      if (!line.trim()) continue;
      try {
        const msg = JSON.parse(line);
        this._handleMessage(msg);
      } catch (e) {
        this.emit('parseError', e, line);
      }
    }
  }

  _handleMessage(msg) {
    if (msg.type === 'ready') {
      this.ready = true;
      for (const cb of this.readyCallbacks) cb();
      this.readyCallbacks = [];
      return;
    }

    if (msg.type === 'confirm_request') {
      if (this.handlers.onConfirmRequest) this.handlers.onConfirmRequest(msg);
      return;
    }

    if (msg.type === 'desktop_activity') {
      if (this.handlers.onDesktopActivity) this.handlers.onDesktopActivity(msg);
      return;
    }

    if (msg.type === 'permission_changed') {
      if (this.handlers.onPermissionChanged) this.handlers.onPermissionChanged(msg);
      return;
    }

    if (msg.type === 'notification') {
      if (this.handlers.onNotification) this.handlers.onNotification(msg);
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
      if (msg.kind === 'thinking') {
        if (handler.onThinking) handler.onThinking(msg.chunk);
        else if (this.handlers.onThinking) this.handlers.onThinking(msg.chunk);
      } else {
        if (handler.onChunk) handler.onChunk(msg.chunk);
        else if (this.handlers.onChunk) this.handlers.onChunk(msg.chunk);
      }
    } else if (msg.type === 'tool_call') {
      if (handler.onToolCall) handler.onToolCall({ name: msg.name, args: msg.args, thought: msg.thought });
      else if (this.handlers.onToolCall) this.handlers.onToolCall({ name: msg.name, args: msg.args, thought: msg.thought });
    } else if (msg.type === 'tool_result') {
      if (handler.onToolResult) handler.onToolResult({ name: msg.name, result: msg.result });
      else if (this.handlers.onToolResult) this.handlers.onToolResult({ name: msg.name, result: msg.result });
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
        onChunk: (chunk) => {
          chunks.push(chunk);
          if (cb.onChunk) cb.onChunk(chunk);
          else if (this.handlers.onChunk) this.handlers.onChunk(chunk);
        },
        onThinking: (chunk) => {
          if (cb.onThinking) cb.onThinking(chunk);
          else if (this.handlers.onThinking) this.handlers.onThinking(chunk);
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

  on(event, handler) {
    if (Object.prototype.hasOwnProperty.call(this.handlers, event)) {
      this.handlers[event] = handler;
    } else {
      super.on(event, handler);
    }
  }

  stop() {
    if (this.proc) {
      this.proc.stdin.end();
      this.proc.kill();
      this.proc = null;
    }
  }
}

module.exports = { BridgeClient };