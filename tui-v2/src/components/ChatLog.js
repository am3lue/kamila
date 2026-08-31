const blessed = require('blessed');
const { TerminalBox } = require('./TerminalBox');
const { MessageRenderer, cacheKey } = require('../rendering/MessageRenderer');
const { theme, translateTags } = require('../theme/TerminalTheme');

class ChatLog {
  constructor(screen, regionManager, messageStore, app) {
    this.screen = screen;
    this.regionManager = regionManager;
    this.messageStore = messageStore;
    this.app = app;
    this.box = null;
    this.logBox = null;
    this.renderer = new MessageRenderer();
    this.lineMap = [];
    this.selectionStart = null;
    this.lastRenderWidth = 0;
  }

  create() {
    const region = this.regionManager.get('chat');
    if (!region) return;

    this.box = new TerminalBox({
      parent: this.screen,
      top: region.y,
      left: region.x,
      width: region.width,
      height: region.height,
      role: 'panel',
      title: ' STDOUT ',
      tags: true,
      scrollable: true,
      alwaysScroll: true,
      scrollbar: { style: { bg: theme.border } },
      mouse: true,
      keys: true,
      padding: { left: 1, right: 1 },
    }).create();

    this.logBox = this.box;

    this._bindEvents();
    this.render();
    return this.box;
  }

  _bindEvents() {
    this.logBox.key('C-c', () => this._copyLastResponse());
    this.logBox.key('C-up', () => { this.logBox.scroll(-1); this.screen.render(); });
    this.logBox.key('C-down', () => { this.logBox.scroll(1); this.screen.render(); });

    this.logBox.on('mousedown', (mouse) => {
      this.selectionStart = { y: mouse.y, x: mouse.x, scroll: this.logBox.getScroll() };
    });

    this.logBox.on('mouseup', (mouse) => {
      if (!this.selectionStart) return;
      const start = this.selectionStart;
      this.selectionStart = null;
      if (start.y === mouse.y && start.x === mouse.x) {
        this._handleClick(mouse);
      } else {
        const text = this._extractRange(start, { y: mouse.y, x: mouse.x });
        if (text) this._doCopy(text);
      }
    });

    this.logBox.on('rightclick', (mouse) => {
      this._handleRightClick(mouse);
    });
  }

  _handleClick(mouse) {
    const lineIdx = this._getLineIndex(mouse.y);
    if (lineIdx < 0 || lineIdx >= this.lineMap.length) return;
    const msgId = this.lineMap[lineIdx];
    const msg = this.messageStore.find(msgId);
    if (!msg) return;

    if (msg.kind === 'thinking') {
      this.messageStore.toggleThinking(msgId);
      this.render();
      this.screen.render();
      return;
    }

    this._doCopy(msg.text);
  }

  _handleRightClick(mouse) {
    const lineIdx = this._getLineIndex(mouse.y);
    if (lineIdx < 0 || lineIdx >= this.lineMap.length) return;
    const msgId = this.lineMap[lineIdx];
    const msg = this.messageStore.find(msgId);
    if (!msg) return;

    const ContextMenu = require('../overlays/ContextMenu');
    ContextMenu.show(this.screen, mouse.x, mouse.y, [
      { label: 'Copy', action: () => this._doCopy(msg.text), shortcut: 'Enter' },
      { label: 'Delete', action: () => this._confirmDelete(msg), shortcut: 'Ctrl+D' },
      { label: 'Reply', action: () => this._replyTo(msg), shortcut: 'r' },
    ]);
  }

  _confirmDelete(msg) {
    const ConfirmOverlay = require('../overlays/ConfirmOverlay');
    ConfirmOverlay.show(this.screen, {
      message: `Delete message #${msg.id}?`,
      onConfirm: () => {
        this.messageStore.remove(msg.id);
        this.render();
        this.screen.render();
      },
    });
  }

  _replyTo(msg) {
    if (this.app && this.app.setInputValue) {
      this.app.setInputValue(`> ${msg.text}\n`);
      this.app.focusInput();
    }
  }

  _getLineIndex(y) {
    const contentTop = (this.logBox.atop || 0) + 1;
    const scroll = this.logBox.getScroll();
    return y - contentTop + scroll;
  }

  _extractRange(start, end) {
    const contentTop = (this.logBox.atop || 0) + 1;
    let lineStart = start.y - contentTop + start.scroll;
    let lineEnd = end.y - contentTop + this.logBox.getScroll();
    let charStart = Math.max(0, start.x - 1);
    let charEnd = Math.max(0, end.x - 1);

    if (lineStart > lineEnd || (lineStart === lineEnd && charStart > charEnd)) {
      [lineStart, lineEnd] = [lineEnd, lineStart];
      [charStart, charEnd] = [charEnd, charStart];
    }
    if (lineStart < 0) lineStart = 0;

    const { stripTags } = require('../rendering/MessageRenderer');
    const parts = [];
    for (let l = lineStart; l <= lineEnd; l++) {
      const raw = this.logBox.getLine(l);
      if (!raw) continue;
      const clean = stripTags(raw);
      if (l === lineStart && l === lineEnd) {
        parts.push(clean.slice(charStart, charEnd));
      } else if (l === lineStart) {
        parts.push(clean.slice(charStart));
      } else if (l === lineEnd) {
        parts.push(clean.slice(0, charEnd));
      } else {
        parts.push(clean);
      }
    }
    return parts.join('\n');
  }

  _doCopy(text) {
    const fs = require('fs');
    const { execSync } = require('child_process');
    const tmpFile = `/tmp/kamila_copy_${process.pid}_${Date.now()}.txt`;
    let wrote = false;
    try {
      fs.writeFileSync(tmpFile, text, 'utf8');
      wrote = true;
    } catch (e) {}
    try {
      execSync(`xclip -selection clipboard < ${tmpFile} 2>/dev/null`, { stdio: 'ignore' });
      this._showCopyToast('Copied to clipboard');
      return true;
    } catch (e) {}
    try {
      execSync(`xsel -ib < ${tmpFile} 2>/dev/null`, { stdio: 'ignore' });
      this._showCopyToast('Copied to clipboard');
      return true;
    } catch (e) {}
    try {
      this.screen.copyToClipboard(text);
      this._showCopyToast('Copied to clipboard');
      return true;
    } catch (e) {}
    if (wrote) this._showCopyToast('Saved to temp file (clipboard unavailable)', true);
    return wrote;
  }

  _copyLastResponse() {
    const msg = this.messageStore.getLastAssistant();
    if (!msg) {
      this._showCopyToast('No response to copy', true);
      return;
    }
    this._doCopy(msg.text);
  }

  _showCopyToast(msg, isError = false) {
    if (this.app && this.app.toastStack) {
      this.app.toastStack.push(msg, { kind: isError ? 'warn' : 'success', duration: 2 });
    } else if (this.app && this.app.setStatusHint) {
      this.app.setStatusHint(isError ? `{red-fg}${msg}{/}` : `{green-fg}✓ ${msg}{/}`);
    }
  }

  render() {
    if (!this.logBox) return;
    const region = this.regionManager.get('chat');
    if (!region) return;

    const width = region.width - 4;
    const isStreaming = Boolean(this.messageStore.getStreaming()) || Boolean(this.messageStore.getThinking());
    if (!isStreaming && width === this.lastRenderWidth && this.lineMap.length > 0) return;
    this.lastRenderWidth = width;

    const timeOf = (id) => {
      const msg = this.messageStore.find(id);
      return msg && msg.startedAt ? new Date(msg.startedAt).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) : '';
    };

    const { content, lineMap } = this.renderer.renderAll(this.messageStore, { width, time: timeOf });
    this.logBox.setContent(translateTags(content));
    this.lineMap = lineMap;
    this.logBox.setScrollPerc(100);
    this.screen.render();
  }

  onResize() {
    if (this.logBox) {
      const region = this.regionManager.get('chat');
      if (region) {
        this.logBox.top = region.y;
        this.logBox.left = region.x;
        this.logBox.width = region.width;
        this.logBox.height = region.height;
      }
    }
    this.lastRenderWidth = 0;
    this.render();
  }

  scrollToBottom() {
    if (this.logBox) this.logBox.setScrollPerc(100);
  }

  scrollToMessage(id) {
    if (!this.logBox) return;
    const idx = this.lineMap.lastIndexOf(id);
    if (idx >= 0) {
      this.logBox.scrollTo(idx);
    }
  }
}

module.exports = { ChatLog };