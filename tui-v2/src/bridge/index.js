const { BridgeClient } = require('./BridgeClient');
const system = require('./methods/system');
const tasks = require('./methods/tasks');
const ai = require('./methods/ai');
const memory = require('./methods/memory');
const desktop = require('./methods/desktop');
const audio = require('./methods/audio');
const permissions = require('./methods/permissions');
const models = require('./methods/models');

const Bridge = {
  BridgeClient,
  system,
  tasks,
  ai,
  memory,
  desktop,
  audio,
  permissions,
  models,
};

module.exports = Bridge;