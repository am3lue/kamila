// messages.js — Message model + store for the chat surface.
//
// Messages are first-class objects with stable integer ids. The store owns all
// mutation so the renderer never has to re-derive message boundaries by
// scanning for `<You>` / `<Kamila>` substrings in rendered text.

const ROLE_LABELS = { user: 'You', assistant: 'Kamila', agent: 'Agent', system: 'System' };

class Message {
  constructor(id, role, text = '', meta = {}) {
    this.id = id;
    this.role = role;
    this.text = String(text);
    this.status = 'done';       // 'streaming' | 'done' | 'error'
    this.model = meta.model || '';
    this.startedAt = meta.startedAt || null;
    this.elapsed = meta.elapsed || null;
    this.error = meta.error || null;
    this.kind = meta.kind || 'text'; // 'text' | 'thinking' | 'tool'
    this.expanded = meta.expanded || false; // thinking blocks
    this.label = ROLE_LABELS[role] || role;
  }
}

class MessageStore {
  constructor() {
    this.messages = [];
    this.nextId = 1;
  }

  add(role, text = '', meta = {}) {
    const msg = new Message(this.nextId++, role, text, meta);
    this.messages.push(msg);
    return msg;
  }

  addSystem(text = '', meta = {}) {
    return this.add('system', text, meta);
  }

  beginStream(role, meta = {}) {
    const msg = this.add(role, '', Object.assign({}, meta, { status: 'streaming' }));
    msg.status = 'streaming';
    return msg;
  }

  find(id) {
    return this.messages.find(m => m.id === id);
  }

  remove(id) {
    const idx = this.messages.findIndex(m => m.id === id);
    if (idx === -1) return null;
    return this.messages.splice(idx, 1)[0];
  }

  appendText(id, part) {
    const msg = this.find(id);
    if (msg) msg.text += String(part);
    return msg;
  }

  finish(id, meta = {}) {
    const msg = this.find(id);
    if (!msg) return null;
    msg.status = 'done';
    if (meta.model) msg.model = meta.model;
    if (meta.elapsed != null) msg.elapsed = meta.elapsed;
    if (meta.error) {
      msg.status = 'error';
      msg.error = meta.error;
    }
    return msg;
  }

  last() {
    return this.messages.length ? this.messages[this.messages.length - 1] : null;
  }

  lastOfRole(roles) {
    const allowed = Array.isArray(roles) ? roles : [roles];
    for (let i = this.messages.length - 1; i >= 0; i--) {
      if (allowed.includes(this.messages[i].role)) return this.messages[i];
    }
    return null;
  }

  toggleThinking(id) {
    const msg = this.find(id);
    if (msg && msg.kind === 'thinking') msg.expanded = !msg.expanded;
    return msg;
  }

  clear() {
    this.messages = [];
  }

  hydrate(rows) {
    // rows: [{role, content, created_at}] from chat.history
    for (const row of rows || []) {
      const role = row.role === 'assistant' ? 'assistant' : 'user';
      this.add(role, String(row.content != null ? row.content : ''), {
        startedAt: row.created_at || null,
        kind: 'text',
      });
    }
  }

  list() {
    return this.messages;
  }

  count() {
    return this.messages.length;
  }
}

module.exports = { Message, MessageStore, ROLE_LABELS };
