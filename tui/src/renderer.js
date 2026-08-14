// renderer.js — Incremental chat renderer with a per-message cache.
//
// Each message is rendered once (to an array of blessed-tag lines) and cached
// by a key that changes only when the message's visible state changes
// (streaming text, thinking expand/collapse, completion). Streaming a long
// reply therefore only re-renders the *active* message, never the whole
// buffer. The renderer also exposes a line→message map so click-to-copy and
// thinking-toggle can resolve the target from a screen coordinate.

const { renderMessage } = require('./markdown');

function cacheKey(msg) {
  // Streaming text changes every chunk, so key on status; expanded state and
  // completion/error also change the rendered shape. A message whose status is
  // 'streaming' is re-rendered on every pass regardless of the cache.
  return `${msg.id}:${msg.status}:${msg.expanded}:${msg.kind}`;
}

class ChatRenderer {
  constructor() {
    this.cache = new Map(); // key -> { lines: string[] }
  }

  clear() {
    this.cache.clear();
  }

  /**
   * Render the message store into blessed content.
   * opts: { width, time (fn id->time string) }
   * Returns { content: string, lineMap: (number|null)[] }.
   */
  render(store, opts = {}) {
    const width = opts.width || 80;
    const timeOf = opts.time || (() => '');

    const contentLines = [];
    const lineMap = []; // index -> message id (or null)

    for (const msg of store.list()) {
      const isStreaming = msg.status === 'streaming';
      let block;
      if (isStreaming) {
        // Always re-render the streaming message (text changes per chunk).
        block = renderMessage(msg, { width, time: timeOf(msg) });
        this.cache.set(cacheKey(msg), { lines: block });
      } else {
        const key = cacheKey(msg);
        const hit = this.cache.get(key);
        if (hit) {
          block = hit.lines;
        } else {
          block = renderMessage(msg, { width, time: timeOf(msg) });
          this.cache.set(key, { lines: block });
        }
      }
      for (const line of block) {
        contentLines.push(line);
        lineMap.push(msg.id);
      }
    }

    return { content: contentLines.join('\n'), lineMap };
  }

  invalidate(id) {
    for (const key of this.cache.keys()) {
      if (key.startsWith(`${id}:`)) {
        this.cache.delete(key);
      }
    }
  }

  invalidateAll() {
    this.cache.clear();
  }
}

module.exports = { ChatRenderer };
