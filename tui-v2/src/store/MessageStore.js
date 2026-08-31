const EventEmitter = require('events');

const ROLE_LABELS = {
  user: 'user@local:~$',
  assistant: 'kamila@sys:~$',
  agent: 'kamila@sys:~$',
  system: 'system',
  tool: 'tool',
};

const KIND_STYLES = {
  text: '',
  thinking: '🧠 ',
  tool: '⚡ ',
  toolresult: '→ ',
  status: '⟳ ',
  error: '✗ ',
};

class Message {
  constructor(id, role, text = '', meta = {}) {
    this.id = id;
    this.role = role;
    this.text = String(text);
    this.status = meta.status || 'done';
    this.model = meta.model || '';
    this.startedAt = meta.startedAt || null;
    this.elapsed = meta.elapsed || null;
    this.error = meta.error || null;
    this.kind = meta.kind || 'text';
    this.expanded = meta.expanded || false;
    this.label = ROLE_LABELS[role] || role;
  }

  clone(overrides = {}) {
    const m = new Message(this.id, this.role, this.text, {
      status: this.status,
      model: this.model,
      startedAt: this.startedAt,
      elapsed: this.elapsed,
      error: this.error,
      kind: this.kind,
      expanded: this.expanded,
    });
    Object.assign(m, overrides);
    return m;
  }
}

class MessageStore extends EventEmitter {
  constructor() {
    super();
    this.messages = new Map();
    this.order = [];
    this.nextId = 1;
    this.streamingId = null;
    this.thinkingId = null;
  }

  add(role, text = '', meta = {}) {
    const id = this.nextId++;
    const msg = new Message(id, role, text, meta);
    this.messages.set(id, msg);
    this.order.push(id);
    this.emit('add', msg);
    this.emit('change');
    return msg;
  }

  addSystem(text = '', meta = {}) {
    return this.add('system', text, meta);
  }

  beginStream(role, meta = {}) {
    const msg = this.add(role, '', { ...meta, status: 'streaming' });
    if (meta.kind === 'thinking') this.thinkingId = msg.id;
    else this.streamingId = msg.id;
    return msg;
  }

  find(id) {
    return this.messages.get(id);
  }

  remove(id) {
    const msg = this.messages.get(id);
    if (!msg) return null;
    this.messages.delete(id);
    this.order = this.order.filter(o => o !== id);
    if (this.streamingId === id) this.streamingId = null;
    if (this.thinkingId === id) this.thinkingId = null;
    this.emit('remove', msg);
    this.emit('change');
    return msg;
  }

  appendText(id, part) {
    const msg = this.messages.get(id);
    if (msg) {
      msg.text += String(part);
      this.emit('append', msg);
      this.emit('change');
    }
    return msg;
  }

  finish(id, meta = {}) {
    const msg = this.messages.get(id);
    if (!msg) return null;
    msg.status = meta.error ? 'error' : 'done';
    if (meta.model) msg.model = meta.model;
    if (meta.elapsed != null) msg.elapsed = meta.elapsed;
    if (meta.error) msg.error = meta.error;
    if (this.streamingId === id) this.streamingId = null;
    if (this.thinkingId === id) this.thinkingId = null;
    this.emit('finish', msg);
    this.emit('change');
    return msg;
  }

  toggleThinking(id) {
    const msg = this.messages.get(id);
    if (msg && msg.kind === 'thinking') {
      msg.expanded = !msg.expanded;
      this.emit('change');
    }
    return msg;
  }

  getStreaming() {
    return this.streamingId ? this.messages.get(this.streamingId) : null;
  }

  getThinking() {
    return this.thinkingId ? this.messages.get(this.thinkingId) : null;
  }

  getVisibleMessages() {
    return this.order.map(id => this.messages.get(id)).filter(Boolean);
  }

  getLastAssistant() {
    for (let i = this.order.length - 1; i >= 0; i--) {
      const msg = this.messages.get(this.order[i]);
      if (msg && (msg.role === 'assistant' || msg.role === 'agent')) return msg;
    }
    return null;
  }

  last() {
    return this.order.length ? this.messages.get(this.order[this.order.length - 1]) : null;
  }

  clear() {
    this.messages.clear();
    this.order = [];
    this.streamingId = null;
    this.thinkingId = null;
    this.nextId = 1;
    this.emit('clear');
    this.emit('change');
  }

  hydrate(rows) {
    for (const row of rows || []) {
      const role = row.role === 'assistant' ? 'assistant' : 'user';
      this.add(role, String(row.content != null ? row.content : ''), {
        startedAt: row.created_at || null,
        kind: 'text',
      });
    }
  }

  list() {
    return this.order.map(id => this.messages.get(id)).filter(Boolean);
  }

  count() {
    return this.order.length;
  }

  toJSON() {
    return this.list().map(m => ({
      id: m.id,
      role: m.role,
      text: m.text,
      status: m.status,
      model: m.model,
      startedAt: m.startedAt,
      elapsed: m.elapsed,
      error: m.error,
      kind: m.kind,
      expanded: m.expanded,
    }));
  }
}

module.exports = { MessageStore, Message };