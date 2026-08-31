module.exports = {
  async status(bridge) { return bridge.send('ai.status'); },
  async models(bridge) { return bridge.send('ai.models'); },
  async query(bridge, prompt, opts = {}, cb = {}) { return bridge.sendStream('ai.query', { prompt, ...opts }, cb); },
  async agentQuery(bridge, prompt, opts = {}, cb = {}) { return bridge.sendStream('ai.agent_query', { prompt, ...opts }, cb); },
  async testConnection(bridge) { return bridge.send('ai.test_connection'); },
  async setupModel(bridge) { return bridge.send('ai.setup_model'); },
  async explainFile(bridge, filePath, content) { return bridge.send('ai.explain_file', { path: filePath, content }); },
};