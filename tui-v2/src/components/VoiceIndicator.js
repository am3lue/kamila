const blessed = require('blessed');
const { TerminalBox } = require('./TerminalBox');
const { theme, translateTags } = require('../theme/TerminalTheme');

class VoiceIndicator {
  constructor(screen, regionManager, app) {
    this.screen = screen;
    this.regionManager = regionManager;
    this.app = app;
    this.box = null;
    this.visible = false;
    this.recording = false;
    this.seconds = 0;
    this.totalSeconds = 5;
    this.timer = null;
    this.level = 0;
  }

  create() {
    this.box = new TerminalBox({
      parent: this.screen,
      top: 0,
      left: 1,
      width: '50%',
      height: 3,
      role: 'panel',
      title: ' VOICE ',
      tags: true,
      hidden: true,
    }).create();

    this._reposition();
    return this.box;
  }

  _reposition() {
    if (!this.box) return;
    const region = this.regionManager.get('input');
    const top = region ? Math.max(0, region.y - 3) : 0;
    this.box.top = top;
    this.box.left = 1;
    this.box.width = Math.min(this.screen.width - 2, 60);
  }

  start(seconds = 5) {
    this.totalSeconds = seconds;
    this.seconds = 0;
    this.recording = true;
    this.visible = true;
    this._reposition();
    if (this.box) this.box.show();
    this._tick();
    this.timer = setInterval(() => this._tick(), 1000);
    this.screen.render();
  }

  _tick() {
    if (!this.recording) return;
    this.seconds++;
    if (this.seconds > this.totalSeconds) {
      this.seconds = this.totalSeconds;
    }
    this.render();
  }

  setLevel(level) {
    this.level = Math.max(0, Math.min(1, level));
    this.render();
  }

  cancel() {
    this.stop();
    this.visible = false;
    if (this.box) this.box.hide();
    this.screen.render();
  }

  stop() {
    this.recording = false;
    if (this.timer) {
      clearInterval(this.timer);
      this.timer = null;
    }
  }

  render() {
    if (!this.box || !this.visible) return;
    const pct = this.totalSeconds > 0 ? this.seconds / this.totalSeconds : 0;
    const barWidth = Math.max(10, this.box.width - 35);
    const filled = Math.round(barWidth * pct);
    const empty = barWidth - filled;
    const bar = `{green-fg}${'.'.repeat(filled)}{/}{textDim}${'.'.repeat(empty)}{/}`;
    const timeStr = `${this.seconds}s / ${this.totalSeconds}s`;
    const levelBars = Math.round(this.level * 8);
    const meter = '█'.repeat(levelBars) + '░'.repeat(8 - levelBars);
    const content = ` {yellow-fg}🎤 Recording...{/} ${timeStr}  [${bar}]  {cyan-fg}${meter}{/}  {textDim}[Esc] Cancel{/}`;
    this.box.setContent(translateTags(content));
    this.screen.render();
  }

  onResize() {
    this._reposition();
    this.render();
  }
}

module.exports = { VoiceIndicator };