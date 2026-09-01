const blessed = require('blessed');
const { TerminalBox } = require('./TerminalBox');
const { theme } = require('../theme/TerminalTheme');
const { escapeBraces } = require('../rendering/MessageRenderer');

const CONTROL_RE = /^[\x00-\x08\x0b-\x0c\x0e-\x1f\x7f]$/;

class ChatInput {
  constructor(screen, regionManager, app) {
    this.screen = screen;
    this.regionManager = regionManager;
    this.app = app;
    this.box = null;
    this.input = null;
    this.footer = null;
    this.recallRing = [];
    this.recallIndex = -1;
    this.onSubmit = null;
    this.onKeyPress = null;
    this.value = '';
    this.cursor = 0;
    this.active = false;
    this.hint = '';
    this.model = '';
    this._lastLines = 1;
    this._lastEnterSeq = null;
  }

  create() {
    const region = this.regionManager.get('input');
    if (!region) return;

    this.box = new TerminalBox({
      parent: this.screen,
      top: region.y,
      left: region.x,
      width: region.width,
      height: region.height,
      role: 'input',
      title: ' STDIN ',
      tags: true,
      borderType: 'line',
    }).create();

    this.input = blessed.box({
      parent: this.box,
      top: 0,
      left: 0,
      width: '100%-1',
      height: '100%-3',
      style: {
        fg: theme.text,
        bg: theme.surface,
        focus: { fg: theme.text, bg: theme.surface },
      },
      tags: true,
      keys: true,
      input: true,
      mouse: true,
      scrollable: true,
    });

    this.footer = blessed.text({
      parent: this.box,
      top: '100%-3',
      left: 0,
      width: '100%-1',
      height: 1,
      style: { fg: theme.textMuted, bg: theme.surface },
      tags: true,
    });

    this.input.on('focus', () => { this.active = true; this._render(); this.screen.render(); });
    this.input.on('blur', () => { this.active = false; this._render(); this.screen.render(); });
    this.input.on('click', () => this.focus());
    this.input.on('keypress', (ch, key) => this._onKey(ch, key));
    this.input.on('wheelup', () => this.input.scroll(-1));
    this.input.on('wheeldown', () => this.input.scroll(1));

    this._renderFooter();
    this._render();
    return this.box;
  }

  _innerWidth() {
    const region = this.regionManager.get('input');
    const w = region ? region.width : (this.box ? this.box.width : 80);
    return Math.max(10, w - 4);
  }

  _segments(value, width) {
    const segs = [];
    if (!value) { segs.push({ start: 0, end: 0, text: '' }); return segs; }
    let offset = 0;
    for (const line of value.split('\n')) {
      const chars = Array.from(line);
      let acc = 0;
      let cur = '';
      let start = offset;
      for (const ch of chars) {
        const w = blessed.unicode.strWidth(ch);
        if (acc + w > width && cur) {
          segs.push({ start, end: start + cur.length, text: cur });
          start += cur.length;
          cur = '';
          acc = 0;
        }
        cur += ch;
        acc += w;
      }
      if (cur !== '' || chars.length === 0) {
        segs.push({ start, end: start + cur.length, text: cur });
      }
      offset += line.length + 1;
    }
    return segs;
  }

  _countLines(value, width) {
    return Math.max(1, this._segments(value, width).length);
  }

  _posToSegment(index, segs) {
    if (!segs.length) return { vl: 0, col: 0 };
    for (let i = 0; i < segs.length; i++) {
      if (index >= segs[i].start && index <= segs[i].end) {
        return { vl: i, col: index - segs[i].start };
      }
    }
    const last = segs[segs.length - 1];
    return { vl: segs.length - 1, col: last.end - last.start };
  }

  _onKey(ch, key) {
    if (!this.active || !key || !key.name) return;
    const full = key.full;
    if (this.onKeyPress) this.onKeyPress(ch, key);

    if (full === 'C-c') {
      if (this.value) {
        this.clearValue();
      } else if (this.app && this.app.quitApp) {
        this.app.quitApp();
      }
      return;
    }

    // Enter submits. Ctrl/Alt+Enter insert a multiline newline when the
    // terminal/blessed reports those modifiers (best-effort). We deliberately
    // do NOT map Shift+Enter to newline: blessed does not parse the CSI-u
    // Shift+Enter sequence and a legacy terminal sends "\x1b\r", whose leading
    // escape byte would otherwise hit the global escape handler and quit.
    if (key.name === 'enter' || key.name === 'linefeed' || key.name === 'return') {
      // A single "\r" may arrive twice (enter, then return); only handle once.
      if (this._lastEnterSeq === key.sequence) return;
      this._lastEnterSeq = key.sequence;
      if (key.ctrl || key.meta || full === 'C-enter') {
        this._insert('\n');
      } else {
        this._submit();
      }
      return;
    }

    if (key.name === 'backspace') {
      if (this.cursor > 0) {
        const before = this.value.slice(0, this.cursor - 1);
        const after = this.value.slice(this.cursor);
        this.value = before + after;
        this.cursor -= 1;
        this._afterEdit();
      }
      return;
    }

    if (key.name === 'delete' || full === 'C-d') {
      if (this.cursor < this.value.length) {
        this.value = this.value.slice(0, this.cursor) + this.value.slice(this.cursor + 1);
        this._afterEdit();
      }
      return;
    }

    if (key.name === 'left') {
      this.cursor = Math.max(0, this.cursor - 1);
      this._render();
      return;
    }

    if (key.name === 'right') {
      this.cursor = Math.min(this.value.length, this.cursor + 1);
      this._render();
      return;
    }

    if (key.name === 'up') { this._moveVLine(-1); return; }
    if (key.name === 'down') { this._moveVLine(1); return; }

    if (key.name === 'home' || full === 'C-a') {
      this.cursor = this._lineStart();
      this._render();
      return;
    }
    if (key.name === 'end' || full === 'C-e') {
      this.cursor = this._lineEnd();
      this._render();
      return;
    }

    if (full === 'C-u') { this.value = ''; this.cursor = 0; this._afterEdit(); return; }
    if (full === 'C-k') {
      this.value = this.value.slice(0, this.cursor) + this.value.slice(this._lineEnd());
      this._afterEdit();
      return;
    }
    if (full === 'C-w') { this._deleteWord(); return; }

    if (ch && !CONTROL_RE.test(ch)) {
      this._insert(ch);
      return;
    }
  }

  _lineStart() {
    const nl = this.value.lastIndexOf('\n', this.cursor - 1);
    return nl + 1;
  }

  _lineEnd() {
    const nl = this.value.indexOf('\n', this.cursor);
    return nl === -1 ? this.value.length : nl;
  }

  _moveVLine(dir) {
    const segs = this._segments(this.value, this._innerWidth());
    const cur = this._posToSegment(this.cursor, segs);
    const target = cur.vl + dir;
    if (target < 0 || target >= segs.length) return;
    const col = Math.min(cur.col, segs[target].end - segs[target].start);
    this.cursor = segs[target].start + col;
    this._render();
  }

  _insert(text) {
    this.value = this.value.slice(0, this.cursor) + text + this.value.slice(this.cursor);
    this.cursor += text.length;
    this.recallIndex = -1;
    this._afterEdit();
  }

  _deleteWord() {
    let i = this.cursor;
    while (i > 0 && this.value[i - 1] === ' ') i--;
    while (i > 0 && this.value[i - 1] !== ' ' && this.value[i - 1] !== '\n') i--;
    this.value = this.value.slice(0, i) + this.value.slice(this.cursor);
    this.cursor = i;
    this._afterEdit();
  }

  _afterEdit() {
    this._render();
    this._maybeGrow();
    this.screen.render();
  }

  _submit() {
    const text = this.value.trim();
    if (text && this.onSubmit) {
      if (this.recallRing[this.recallRing.length - 1] !== text) {
        this.recallRing.push(text);
      }
      this.recallIndex = -1;
      this.onSubmit(text);
    }
    this.clearValue();
    this.focus();
  }

  _maybeGrow() {
    const lines = this._countLines(this.value, this._innerWidth());
    if (lines === this._lastLines) return;
    this._lastLines = lines;
    if (this.app && this.app.resizeInputTo) this.app.resizeInputTo(lines);
  }

  _render() {
    if (!this.input) return;
    const width = this._innerWidth();
    const segs = this._segments(this.value, width);
    const pos = this._posToSegment(this.cursor, segs);

    const out = [];
    for (let i = 0; i < segs.length; i++) {
      const seg = segs[i];
      if (this.active && i === pos.vl) {
        const col = pos.col;
        const at = seg.text[col] || ' ';
        const line = escapeBraces(seg.text.slice(0, col)) +
          `{accent-bg}{black-fg}${escapeBraces(at)}{/}{/}` +
          escapeBraces(seg.text.slice(col + 1));
        out.push(line);
      } else {
        out.push(escapeBraces(seg.text));
      }
    }
    if (!out.length) out.push(this.active ? '{accent-bg}{black-fg} {/}{/}' : '');

    this.input.setContent(out.join('\n'));

    // Keep the cursor visual line visible.
    const h = Math.max(1, this.input.height || 1);
    const top = Math.max(0, Math.min(pos.vl - (h - 1), Math.max(0, segs.length - h)));
    this.input.setScroll(top);
  }

  _renderFooter() {
    if (!this.footer) return;
    const hint = this.hint || '{textDim}Enter:Send  C-o:Editor  Tab:Focus  Esc:Quit{/}';
    this.footer.setContent(` ${hint} `);
  }

  setValue(text) {
    this.value = String(text == null ? '' : text);
    this.cursor = this.value.length;
    this.recallIndex = -1;
    this._render();
    this._maybeGrow();
    this.screen.render();
  }

  getValue() {
    return this.value;
  }

  clearValue() {
    this.value = '';
    this.cursor = 0;
    this.recallIndex = -1;
    this._render();
    this._maybeGrow();
    this.screen.render();
  }

  setHint(hint) {
    this.hint = hint || '';
    this._renderFooter();
    this.screen.render();
  }

  setModel(model) {
    this.model = model || '';
    if (this.box) {
      const title = this.model ? ` STDIN ─ ${this.model} ` : ' STDIN ';
      this.box.setTitle(title);
    }
    this.screen.render();
  }

  focus() {
    this.active = true;
    if (this.input) this.input.focus();
    this._render();
    this.screen.render();
  }

  onResize() {
    if (this.input) {
      const region = this.regionManager.get('input');
      if (region) {
        this.box.top = region.y;
        this.box.left = region.x;
        this.box.width = region.width;
        this.box.height = region.height;
        this._render();
        this._maybeGrow();
      }
    }
  }

  loadHistory(history) {
    this.recallRing = [...(history || [])].slice(-100);
    this.recallIndex = -1;
  }
}

module.exports = { ChatInput };