const EventEmitter = require('events');

class UIState extends EventEmitter {
  constructor() {
    super();
    this.state = {
      currentMode: 'chat',
      panelsVisible: true,
      activeModel: null,
      desktopContext: null,
      systemStats: null,
      tasks: [],
      goals: [],
      voiceRecording: false,
      voiceSeconds: 0,
      voiceTotalSeconds: 5,
      voiceLevel: 0,
      statusHint: '',
    };
  }

  get(key) {
    return this.state[key];
  }

  set(key, value) {
    const old = this.state[key];
    this.state[key] = value;
    if (old !== value) this.emit('change', key, value, old);
    this.emit(`change:${key}`, value, old);
    return value;
  }

  getAll() {
    return { ...this.state };
  }

  onChange(key, cb) {
    this.on(`change:${key}`, cb);
  }
}

module.exports = { UIState };