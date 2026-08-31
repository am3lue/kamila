module.exports = {
  async transcribe(bridge, filePath) { return bridge.send('audio.transcribe', { file_path: filePath }); },
  async record(bridge, seconds = 3) { return bridge.send('audio.record', { seconds }); },
};