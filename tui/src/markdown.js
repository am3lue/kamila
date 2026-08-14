const { marked } = require('marked');

function escapeBraces(text) {
  return text.replace(/\{/g, '\\{').replace(/\}/g, '\\}');
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
  // Strip ANSI escape codes (blessed converts {..} tags into real SGR codes
  // in the rendered buffer, so getLine()/getContent() return them).
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
      return '{#a8a8a8-fg}────────────────────────────────{/}\n\n';

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
      if (t.type === 'list') {
        nested.push(renderList(t, depth + 1));
      } else {
        textLines.push(renderToken(t));
      }
    }
    const text = textLines.join('').trim();
    let result = '';
    if (text) {
      const lines = text.split('\n');
      result += `${pad}${bullet} ${lines[0].trimStart()}\n`;
      for (let j = 1; j < lines.length; j++) {
        result += `${pad}  ${lines[j].trimStart()}\n`;
      }
    }
    for (const nl of nested) {
      result += nl;
    }
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
    return out.replace(/&#(\d+);/g, (_, c) => String.fromCharCode(+c))
              .replace(/&amp;/g, '&').replace(/&lt;/g, '<')
              .replace(/&gt;/g, '>').replace(/&quot;/g, '"');
  } catch (e) {
    return text;
  }
}

/**
 * Word-wrap a blessed-tagged string to `width` visible columns.
 *
 * `{...}` tags occupy zero visible width; wrapping breaks on spaces first and
 * hard-breaks long tokens, keeping tag markup intact across line breaks.
 * Returns the wrapped string.
 */
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
      // Consume a complete {..} tag as a zero-width token.
      const close = text.indexOf('}', i);
      if (close === -1) {
        current += ch;
        i++;
      } else {
        current += text.slice(i, close + 1);
        i = close + 1;
      }
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
      // Break at current position (hard break for long tokens).
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

/**
 * Render a single chat message into blessed-tagged content.
 *
 * Returns an array of lines. `opts`:
 *   - width:   wrap width in visible columns
 *   - time:    timestamp string (or falsy to omit)
 *   - streaming: whether the message is currently being streamed
 */
function renderMessage(msg, opts = {}) {
  const width = opts.width || 80;
  const time = opts.time || '';

  if (msg.kind === 'tool') {
    return [`{textDim}${escapeBraces(msg.text)}{/}`];
  }

  if (msg.kind === 'thinking') {
    if (!msg.expanded) {
      return [`{#a8a8a8-fg}[${time}]{/} {magenta-fg}🧠 Thinking… (click to expand){/}`];
    }
    const body = msg.text.replace(/\n{3,}/g, '\n\n').trim();
    return wrapTagged(body, width).split('\n').map(l => `{textDim}${l}{/}`);
  }

  const headerColor = { user: 'yellow', assistant: 'green', agent: 'magenta', system: 'textDim' };
  const color = headerColor[msg.role] || 'textDim';
  const label = msg.label || msg.role;

  let header = `{#a8a8a8-fg}[${time}]{/} {${color}-fg}<${label}>:{/}`;

  let body = '';
  if (msg.role === 'system') {
    body = wrapTagged(escapeBraces(msg.text), width);
  } else if (msg.role === 'user') {
    body = wrapTagged(escapeBraces(msg.text), width);
  } else {
    // assistant / agent — markdown body, then wrap to width.
    const raw = renderMarkdown(msg.text);
    body = wrapTagged(raw, width);
  }

  // Streaming indicator / elapsed tag appended to the last body line.
  const suffix = msg.status === 'streaming'
    ? ' {cyan-fg}⟳{/}'
    : (msg.elapsed != null ? ` {#a8a8a8-fg}(${msg.elapsed}){/}` : '');
  if (suffix && body) {
    const parts = body.split('\n');
    parts[parts.length - 1] += suffix;
    body = parts.join('\n');
  }

  const lines = body.split('\n');
  // First body line is joined to the header (mirrors prior layout).
  const result = [];
  if (lines.length === 0 || (lines.length === 1 && lines[0] === '')) {
    result.push(`${header} `);
  } else {
    result.push(`${header} ${lines[0]}`);
    for (let j = 1; j < lines.length; j++) result.push(lines[j]);
  }
  return result;
}

module.exports = { renderMarkdown, stripTags, escapeBraces, wrapTagged, renderMessage, textWidth };
