module.exports = {
  async status(bridge) { return bridge.send('system.status'); },
  async info(bridge) { return bridge.send('system.info'); },
  async latency(bridge) { return bridge.send('system.latency'); },
};