module.exports = {
  async list(bridge) { return bridge.send('model.list'); },
  async select(bridge, name) { return bridge.send('model.select', { name }); },
  async configure(bridge, action, data = {}) { return bridge.send('model.configure', { action, ...data }); },
};