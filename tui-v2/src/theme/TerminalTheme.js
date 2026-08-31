const theme = {
  bg: '#050505',
  surface: '#0a0a0a',
  border: '#333333',
  text: '#e0e0e0',
  textMuted: '#555555',
  accent: '#00d7ff',
  success: '#00ff00',
  warning: '#ffb300',
  error: '#ff0033',
};

const border = {
  tl: '┌', tr: '┐', bl: '└', br: '┘',
  h: '─', v: '│',
  titleLeft: '[ ', titleRight: ' ]',
};

function makeTitle(title) {
  if (!title) return '';
  return `${border.titleLeft}${String(title).trim()}${border.titleRight}`;
}

function makeBorder(width, title = '') {
  const t = makeTitle(title);
  const tLen = t.length;
  const avail = width - 2;
  if (tLen >= avail) return border.tl + border.h.repeat(width - 2) + border.tr;
  const leftPad = Math.floor((avail - tLen) / 2);
  const rightPad = avail - tLen - leftPad;
  return border.tl + border.h.repeat(leftPad) + t + border.h.repeat(rightPad) + border.tr;
}

function makeBottomBorder(width) {
  return border.bl + border.h.repeat(width - 2) + border.br;
}

const CUSTOM_TAGS = {
  textDim: theme.textMuted,
  textMuted: theme.textMuted,
  textBrand: theme.accent,
  accent: theme.accent,
  success: theme.success,
  warn: theme.warning,
  warning: theme.warning,
  error: theme.error,
  surface: theme.surface,
};

function translateTags(str) {
  if (!str || typeof str !== 'string') return str;
  return str.replace(/\{(textDim|textMuted|textBrand|accent|success|warn|warning|error|surface)(-(fg|bg))?\}/g, (_m, name, _suffix, prop) => {
    const hex = CUSTOM_TAGS[name];
    if (!hex) return `{${name}}`;
    const p = prop || 'fg';
    return `{#${hex.replace(/^#/, '')}-${p}}`;
  });
}

function styleFor(role) {
  const base = {
    fg: theme.text,
    bg: theme.bg,
    border: { fg: theme.border },
  };
  switch (role) {
    case 'header': return { ...base, bg: theme.accent, fg: theme.bg };
    case 'status': return { ...base, bg: theme.surface, fg: theme.textMuted };
    case 'input': return { ...base, bg: theme.surface };
    case 'panel': return { ...base };
    default: return base;
  }
}

const blessed = require('blessed');
// blessed's colors.match cache is polluted at load time by the ccolors IIFE,
// which reduces every exact 256-palette color to its nearest-of-8. Clear it so
// hex colors like #a8a8a8 (muted text) and #00d7ff (accent) resolve correctly.
const blessedColors = require('blessed/lib/colors.js');
if (blessedColors && blessedColors._cache) blessedColors._cache = {};
const proto = blessed.Element.prototype;
if (proto && proto.setContent && !proto.__kamilaTagTranslate) {
  const originalSetContent = proto.setContent;
  proto.setContent = function (content, noInit) {
    if (typeof content === 'string') content = translateTags(content);
    return originalSetContent.call(this, content, noInit);
  };
  proto.__kamilaTagTranslate = true;
}

module.exports = { theme, border, makeTitle, makeBorder, makeBottomBorder, styleFor, translateTags };