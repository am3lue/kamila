const EventEmitter = require('events');

class FocusManager extends EventEmitter {
  constructor() {
    super();
    this.focusedPanel = null;
    this.panelRegistry = new Map();
    this.focusHistory = [];
  }

  register(name, element, metadata = {}) {
    this.panelRegistry.set(name, { element, metadata, focused: false });
    if (element && typeof element.on === 'function') {
      element.on('focus', () => this.setFocus(name));
    }
  }

  unregister(name) {
    this.panelRegistry.delete(name);
    if (this.focusedPanel === name) this.focusedPanel = null;
  }

  setFocus(name) {
    if (!this.panelRegistry.has(name)) return;
    const prev = this.focusedPanel;
    this.focusedPanel = name;
    this.focusHistory = [name, ...this.focusHistory.filter(n => n !== name)].slice(0, 10);
    this.panelRegistry.forEach((p, n) => p.focused = n === name);
    this.emit('focusChange', name, prev);
    this.emit('focus', name, this.panelRegistry.get(name)?.metadata);
  }

  getFocus() {
    return this.focusedPanel;
  }

  getMetadata(name) {
    return this.panelRegistry.get(name)?.metadata || {};
  }

  getFocusedMetadata() {
    return this.getMetadata(this.focusedPanel);
  }

  isFocused(name) {
    return this.focusedPanel === name;
  }

  getHistory() {
    return [...this.focusHistory];
  }
}

module.exports = { FocusManager };