const { marked } = require('marked');
const { theme } = require('../theme/TerminalTheme');

function escapeBraces(text) {
  return String(text).replace(/\{/g, '\\{').replace(/\}/g, '\\}');
}

function stripTags(text) {
  let out = '';
  let inTag = false;
  for (let i = 0; i < text.length; i++) {
    if (text[i] === '\\' && i + 1 < text.length && (text[i + 1] === '{' || text[i + 1] === '}')) {
      if (!inTag) out += text[i + 1];
      i++;
    } else if (text[i] === '{' && !inTag) {
      inTag = true;
    } else if (text[i] === '}' && inTag) {
      inTag = false;
    } else if (!inTag) {
      out += text[i];
    }
  }
  return out.replace(/\u001b\[[0-9;]*m/g, '').trim();
}

function textWidth(rendered) {
  return stripTags(rendered).length;
}

function renderToken(token) {
  switch (token.type) {
    case 'paragraph': {
      const content = token.tokens.map(renderToken).join('');
      return content + '\n';
    }
    case 'text':
      if (token.tokens) return token.tokens.map(renderToken).join('');
      return escapeBraces(token.text);
    case 'strong':
      return `{bold}${token.tokens.map(renderToken).join('')}{/}`;
    case 'em':
      return `{italic}${token.tokens.map(renderToken).join('')}{/}`;
    case 'codespan':
      return `{yellow-fg}${escapeBraces(token.text)}{/}`;
    case 'code': {
      let out = '';
      if (token.lang) out += `  {cyan-fg}[${token.lang}]{/}\n`;
      out += token.text.split('\n').map(l => `  {yellow-fg}${escapeBraces(l)}{/}`).join('\n');
      return out + '\n';
    }
    case 'heading': {
      const prefix = '#'.repeat(token.depth);
      return `{cyan-fg}{bold}${prefix} ${token.tokens.map(renderToken).join('')}{/}{/}\n\n`;
    }
    case 'list':
      return renderList(token, 0);
    case 'link':
      return `${token.tokens.map(renderToken).join('')}{#a8a8a8-fg} (${token.href}){/}`;
    case 'image':
      return `{#a8a8a8-fg}[img: ${token.text}]${token.href ? ' (' + token.href + ')' : ''}{/}`;
    case 'blockquote': {
      const content = token.tokens.map(renderToken).join('').trim();
      if (!content) return '';
      return content.split('\n').filter(Boolean).map(l =>
        `  {italic}{#a8a8a8-fg}│ ${l.trim()}{/}{/}`
      ).join('\n') + '\n\n';
    }
    case 'hr':
      return `{#a8a8a8-fg}────────────────────────────────{/}\n\n`;
    case 'space':
      return '\n\n';
    case 'del':
      return `{strikethrough}${token.tokens.map(renderToken).join('')}{/}`;
    case 'br':
      return '\n';
    case 'table':
      return renderTable(token) + '\n\n';
    default:
      if (token.raw) return escapeBraces(token.raw);
      if (token.text) return escapeBraces(token.text);
      return '';
  }
}

function renderList(token, depth) {
  const pad = '  '.repeat(depth);
  let out = token.items.map((item, i) => {
    const bullet = token.ordered ? `${i + 1}.` : '•';
    let textLines = [];
    let nested = [];
    for (const t of item.tokens) {
      if (t.type === 'list') nested.push(renderList(t, depth + 1));
      else textLines.push(renderToken(t));
    }
    const text = textLines.join('').trim();
    let result = '';
    if (text) {
      const lines = text.split('\n');
      result += `${pad}${bullet} ${lines[0].trimStart()}\n`;
      for (let j = 1; j < lines.length; j++) result += `${pad}  ${lines[j].trimStart()}\n`;
    }
    for (const nl of nested) result += nl;
    return result;
  }).join('');
  if (depth === 0) out += '\n';
  return out;
}

function renderTable(token) {
  const headers = token.header;
  const rows = token.rows;
  const aligns = token.align || [];
  const headerTexts = headers.map(h => {
    const rendered = h.tokens.map(renderToken).join('');
    return { rendered, width: textWidth(rendered) };
  });
  const rowTexts = rows.map(row =>
    row.map(cell => {
      const rendered = cell.tokens.map(renderToken).join('');
      return { rendered, width: textWidth(rendered) };
    })
  );
  const colWidths = headers.map((h, i) => {
    const hw = headerTexts[i].width;
    const dw = rowTexts.reduce((m, r) => Math.max(m, r[i] ? r[i].width : 0), 0);
    return Math.max(hw, dw, 1);
  });
  const sepLine = ` {#a8a8a8-fg}${colWidths.map(w => '─'.repeat(w)).join('─┼─')}{/} `;
  const headerLine = ' ' + headerTexts.map((ht, i) => {
    const pad = colWidths[i] - ht.width;
    return `{bold}${ht.rendered}{/}${' '.repeat(pad)}`;
  }).join(` {#a8a8a8-fg}│{/} `) + ' ';
  const dataLines = rowTexts.map(row =>
    ' ' + row.map((cell, i) => {
      const w = colWidths[i];
      const align = aligns[i] || 'left';
      const pad = w - cell.width;
      if (align === 'right') return ' '.repeat(pad) + cell.rendered;
      if (align === 'center') {
        const l = Math.floor(pad / 2);
        return ' '.repeat(l) + cell.rendered + ' '.repeat(pad - l);
      }
      return cell.rendered + ' '.repeat(pad);
    }).join(` {#a8a8a8-fg}│{/} `) + ' '
  );
  return [headerLine, sepLine, ...dataLines].join('\n');
}

function renderMarkdown(text) {
  if (!text) return '';
  try {
    const tokens = marked.lexer(text);
    const out = tokens.map(renderToken).join('').replace(/\n{3,}/g, '\n\n').trim();
    return out
      .replace(/&#(\d+);/g, (_, c) => String.fromCharCode(+c))
      .replace(/&/g, '&').replace(/</g, '<')
      .replace(/>/g, '>').replace(/"/g, '"');
  } catch (e) {
    return text;
  }
}

function wrapTagged(text, width) {
  if (width <= 0) return text;
  const out = [];
  let current = '';
  let curWidth = 0;
  let i = 0;
  const n = text.length;
  while (i < n) {
    const ch = text[i];
    if (ch === '{') {
      const close = text.indexOf('}', i);
      if (close === -1) { current += ch; i++; }
      else { current += text.slice(i, close + 1); i = close + 1; }
      continue;
    }
    if (ch === '\n') {
      out.push(current);
      current = '';
      curWidth = 0;
      i++;
      continue;
    }
    if (curWidth + 1 > width) {
      out.push(current);
      current = '';
      curWidth = 0;
    }
    current += ch;
    curWidth += 1;
    i++;
  }
  if (current.length > 0) out.push(current);
  return out.join('\n');
}

const ROLE_COLOR = {
  user: 'green',
  assistant: 'cyan',
  agent: 'magenta',
  system: 'textDim',
  tool: 'yellow',
};

const KIND_PREFIX = {
  text: '',
  thinking: '{textMuted-fg}🧠 ',
  tool: '{yellow-fg}⚡ ',
  toolresult: '{textDim-fg}→ ',
  status: '{cyan-fg}⟳ ',
  error: '{red-fg}✗ ',
};

function cacheKey(msg, width) {
  return `${msg.id}:${msg.status}:${msg.expanded}:${msg.kind}:${width}`;
}

class MessageRenderer {
  constructor() {
    this.cache = new Map();
  }

  clear() {
    this.cache.clear();
  }

  invalidate(id) {
    for (const key of this.cache.keys()) {
      if (key.startsWith(`${id}:`)) this.cache.delete(key);
    }
  }

  render(msg, opts = {}) {
    const width = opts.width || 80;
    const time = opts.time || '';
    const isStreaming = msg.status === 'streaming';

    const key = cacheKey(msg, width);
    if (!isStreaming) {
      const hit = this.cache.get(key);
      if (hit) return hit.lines;
    }

    let lines;
    if (msg.kind === 'tool') {
      lines = [`{textDim}${escapeBraces(msg.text)}{/}`];
    } else if (msg.kind === 'thinking') {
      if (!msg.expanded) {
        lines = [`{#a8a8a8-fg}[${time}]{/} {magenta-fg}🧠 Thinking… (click to expand){/}`];
      } else {
        const body = msg.text.replace(/\n{3,}/g, '\n\n').trim();
        lines = wrapTagged(body, width).split('\n').map(l => `{textDim}${l}{/}`);
      }
    } else {
      const color = ROLE_COLOR[msg.role] || 'textDim';
      const label = msg.label || msg.role;
      const prefix = KIND_PREFIX[msg.kind] || '';
      let header = `{#a8a8a8-fg}[${time}]{/} {${color}-fg}${prefix}<${label}>:{/}`;

      let body = '';
      if (msg.role === 'system') {
        body = wrapTagged(escapeBraces(msg.text), width);
      } else if (msg.role === 'user') {
        body = wrapTagged(escapeBraces(msg.text), width);
      } else {
        const raw = renderMarkdown(msg.text);
        body = wrapTagged(raw, width);
      }

      const suffix = msg.status === 'streaming'
        ? ' {cyan-fg}⟳{/}'
        : (msg.elapsed != null ? ` {#a8a8a8-fg}(${msg.elapsed}){/}` : '');
      if (suffix && body) {
        const parts = body.split('\n');
        parts[parts.length - 1] += suffix;
        body = parts.join('\n');
      }

      const bodyLines = body.split('\n');
      if (bodyLines.length === 0 || (bodyLines.length === 1 && bodyLines[0] === '')) {
        lines = [`${header} `];
      } else {
        lines = [`${header} ${bodyLines[0]}`];
        for (let j = 1; j < bodyLines.length; j++) lines.push(bodyLines[j]);
      }
    }

    if (!isStreaming) this.cache.set(key, { lines });
    return lines;
  }

  renderAll(store, opts = {}) {
    const width = opts.width || 80;
    const timeOf = opts.time || (() => '');
    const contentLines = [];
    const lineMap = [];
    for (const msg of store.getVisibleMessages()) {
      const lines = this.render(msg, { width, time: timeOf(msg.id) });
      for (const line of lines) {
        contentLines.push(line);
        lineMap.push(msg.id);
      }
    }
    return { content: contentLines.join('\n'), lineMap };
  }
}

module.exports = {
  MessageRenderer,
  escapeBraces,
  stripTags,
  wrapTagged,
  renderMarkdown,
  cacheKey,
};