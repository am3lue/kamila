const EventEmitter = require('events');

class Keybindings extends EventEmitter {
  constructor(screen, focusManager) {
    super();
    this.screen = screen;
    this.focusManager = focusManager;
    this.bindings = new Map();
    this.globalHandlers = new Map();
    this.contextualHandlers = new Map();
    this._registerDefaults();
  }

  _registerDefaults() {
    this.bind('f5', 'refresh.all');
    this.bind('C-S-r', 'refresh.all');
    this.bind('f10', 'logs.toggle');
    this.bind('C-S-l', 'logs.toggle');
    this.bind('f11', 'permissions.toggle');
    this.bind('C-A-p', 'permissions.toggle');
    this.bind('C-t', 'sidebar.toggle');
    this.bind('C-b', 'sidebar.toggle');
    this.bind('C-p', 'palette.open');
    this.bind('C-r', 'voice.recordQuick');
    this.bind('C-o', 'editor.open');
    this.bind('C-d', 'delete.contextual');
    this.bind('tab', 'input.focus');
    this.bind('escape', 'overlay.dismiss');
    this.bind('C-c', 'app.quit');
  }

  bind(key, action, context = 'global') {
    const entry = { key, action, context };
    this.bindings.set(`${context}:${key}`, entry);
    
    if (context === 'global') {
      this._attachGlobal(key, action);
    } else {
      this.contextualHandlers.set(`${context}:${key}`, entry);
    }
    return this;
  }

  // Keys that are still allowed to trigger globally while the chat input is
  // focused (typing). Everything else (printables, C-c, C-d, C-p, arrows…)
  // is left to the input widget so typing never triggers a global action.
  static get _typingAllowlist() {
    return new Set(['f5', 'C-S-r', 'f10', 'C-S-l', 'f11', 'C-A-p', 'C-t', 'C-b', 'C-o', 'tab', 'escape']);
  }

  _attachGlobal(key, action) {
    try {
      this.screen.key(key, (...args) => {
        if (this.focusManager.isFocused('chatInput') && !Keybindings._typingAllowlist.has(key)) {
          return;
        }
        this.emit('action', action, { key, source: 'global' });
        this.emit(action, { key, source: 'global' });
      });
    } catch (e) {
      console.warn(`Failed to bind key "${key}":`, e.message);
    }
  }

  attachContext(context, element) {
    if (!element || typeof element.key !== 'function') return;
    for (const [k, entry] of this.contextualHandlers) {
      if (k.startsWith(`${context}:`)) {
        try {
          element.key(entry.key, (...args) => {
            if (this.focusManager.isFocused(context) || entry.globalWhenFocused) {
              this.emit('action', entry.action, { key: entry.key, source: context });
              this.emit(entry.action, { key: entry.key, source: context });
            }
          });
        } catch (e) {
          console.warn(`Failed to bind contextual key "${entry.key}" for ${context}:`, e.message);
        }
      }
    }
  }

  unbind(key, context = 'global') {
    this.bindings.delete(`${context}:${key}`);
    this.contextualHandlers.delete(`${context}:${key}`);
  }

  getBinding(key, context = 'global') {
    return this.bindings.get(`${context}:${key}`) || this.bindings.get(`global:${key}`);
  }

  getAll() {
    return Array.from(this.bindings.values());
  }

  getHelpText() {
    const groups = {};
    for (const entry of this.bindings.values()) {
      if (!groups[entry.context]) groups[entry.context] = [];
      groups[entry.context].push(`${entry.key} → ${entry.action}`);
    }
    return groups;
  }
}

module.exports = { Keybindings };