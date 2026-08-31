module.exports = {
  async status(bridge) { return bridge.send('desktop.status'); },
  async screenshot(bridge) { return bridge.send('desktop.screenshot'); },
  async watch(bridge, enable) { return bridge.send('desktop.watch', { enable }); },
  async stats(bridge) { return bridge.send('desktop.stats'); },
  async organize(bridge, createFolders = true, moveFiles = false) { return bridge.send('desktop.organize', { create_folders: createFolders, move_files: moveFiles }); },
  async clean(bridge, daysOld = 30) { return bridge.send('desktop.clean', { days_old: daysOld }); },
  async suggest(bridge) { return bridge.send('desktop.suggest'); },
  async health(bridge) { return bridge.send('desktop.health'); },
};