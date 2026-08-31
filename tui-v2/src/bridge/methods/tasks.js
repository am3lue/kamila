module.exports = {
  async list(bridge) { return bridge.send('tasks.list'); },
  async stats(bridge) { return bridge.send('tasks.stats'); },
  async add(bridge, title, params = {}) { return bridge.send('tasks.add', { title, ...params }); },
  async complete(bridge, taskId) { return bridge.send('tasks.complete', { task_id: taskId }); },
  async delete(bridge, taskId) { return bridge.send('tasks.delete', { task_id: taskId }); },
};