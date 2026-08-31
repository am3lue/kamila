module.exports = {
  async stats(bridge) { return bridge.send('memory.stats'); },
  async addGoal(bridge, goal, category = 'general', priority = 1) { return bridge.send('memory.add_goal', { goal, category, priority }); },
  async completeGoal(bridge, goalId) { return bridge.send('memory.complete_goal', { goal_id: goalId }); },
  async goals(bridge) { return bridge.send('memory.goals'); },
  async history(bridge, session = 'default') { return bridge.send('chat.history', { session }); },
};