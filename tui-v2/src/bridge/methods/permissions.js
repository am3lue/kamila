module.exports = {
  async get(bridge) { return bridge.send('permission.get'); },
  async set(bridge, policy) { return bridge.send('permission.set', { policy }); },
  async reset(bridge) { return bridge.send('permission.reset'); },
  async decisions(bridge, limit = 50) { return bridge.send('permission.decisions', { limit }); },
};