const blessed = require('blessed');
const { theme } = require('./theme');

const SPINNERS = ['⣾', '⣽', '⣻', '⢿', '⡿', '⣟', '⣯', '⣷'];

class SplashScreen {
  constructor(screen) {
    this.screen = screen;
    this.visible = false;
    this.spinnerIndex = 0;
    this.interval = null;
    this.statusText = '';

    this.box = blessed.box({
      parent: screen,
      top: 'center',
      left: 'center',
      width: 46,
      height: 9,
      label: '',
      border: { type: 'line', fg: theme.accent },
      style: {
        fg: theme.textBright,
        bg: theme.bg,
        border: { fg: theme.accent },
      },
      tags: true,
      content: '',
      hidden: true,
    });
  }

  show(status) {
    this.visible = true;
    this.statusText = status;
    this.box.show();
    this.renderContent();
    this.startSpinner();
    this.screen.render();
  }

  renderContent() {
    this.box.setContent(
      `\n` +
      `  {bold}{cyan-fg}KAMILA v0.2.0{/}\n` +
      `\n` +
      `     ${this.spinnerChar()} ${this.statusText}\n` +
      `\n`
    );
  }

  spinnerChar() {
    return SPINNERS[this.spinnerIndex % SPINNERS.length];
  }

  updateStatus(text) {
    this.statusText = text;
    if (this.visible) {
      this.renderContent();
      this.screen.render();
    }
  }

  startSpinner() {
    this.stopSpinner();
    this.interval = setInterval(() => {
      this.spinnerIndex++;
      if (this.visible) {
        this.renderContent();
        this.screen.render();
      }
    }, 120);
  }

  stopSpinner() {
    if (this.interval) {
      clearInterval(this.interval);
      this.interval = null;
    }
  }

  hide() {
    this.stopSpinner();
    this.visible = false;
    this.box.hide();
    this.screen.render();
  }
}

module.exports = SplashScreen;
