# Kamila Development Log

Human-readable per-session record of changes for later review. Structured
runtime logs live under `~/.kamila/logs/` (`kamila.log` human, `kamila.log`
JSON when `--verbose`, `tui.log` TUI-side JSONL).

## Session 2026-08-17 — Input, streaming, splash, verbose logging

Origin: TUI + Julia bridge · Kind: ui/input · Level: critical

### Fixed — input (origin: tui, kind: ui, level: critical)
- Rewrote `ChatInput` as a custom input widget (`tui-v2/src/components/ChatInput.js`):
  dropped `blessed.textbox`/`readInput`, which were the root cause of
  invisible typing and duplicated letters on Enter (blessed `_done` ran
  `rewindFocus()`, stealing focus and stopping input after the first Enter;
  Enter emitted both `enter` and `return` passes causing ghosted letters).
- Owns `value` + `cursor`, renders a visible block cursor, handles
  printable chars, backspace/delete, arrows, home/end, C-a/C-e/C-u/C-k/C-w,
  C-d (delete char), C-c (clear line or quit), C-p/C-n recall, enter → single submit.
- Input is focused on startup so typing works immediately.

### Fixed — keybindings (origin: tui, kind: ui, level: critical)
- Removed the `q → app.quit` global binding (typing `q` used to quit the app).
- Global binds are gated while the chat input is focused (`Keybindings._typingAllowlist`),
  so `C-p`, `C-d`, `C-c`, etc. no longer misfire mid-typing. `C-c` quits only
  when the input is empty; otherwise it clears the line.

### Fixed — streaming (origin: tui/bridge, kind: stream, level: critical)
- `_handleSubmit`/`_runAgent` now pass real `_streamHandlers()` callbacks
  (`onChunk`/`onThinking`/`onToolCall`/`onToolResult`) — words stream into the
  chat live instead of being dropped.
- Removed dead `bridge.on('stream'|'tool_call'|'tool_result'|'stream_end')`
  handlers in `_setupBridgeHandlers` (`BridgeClient._handleMessage` routes
  stream events through the `sendStream` pending callbacks, never through
  EventEmitter) — this also fixes assistant replies never rendering.

### Fixed — startup (origin: tui, kind: lifecycle, level: high)
- Removed the blocking `SplashScreen` (`src/index.js` + deleted
  `SplashScreen.js`). The full UI builds immediately; the StatusBar shows
  "Starting Julia backend…" until `bridge.onReady` → `app.onBackendReady()`.
- Refresh loops and submit are guarded on `bridge.ready` to avoid pre-start
  crashes; `_hydrateHistory` moved to backend-ready.

### Added — verbose + categorized logging (origin: all, kind: log, level: high)
- `bin/kamila`: verbose (debug) logging is on by default
  (`KAMILA_LOG=debug` → `~/.kamila/logs/kamila.log`); `--verbose` /
  `KAMILA_VERBOSE=1` enables structured JSON (`KAMILA_LOG_FORMAT=json`).
- `KamilaLog` (`src/system/log.jl`): entries now carry four dimensions —
  `level` (criticality), `origin` (module/subsystem), `kind` (event type),
  `msg` (what). JSON output uses `origin`+`kind` keys.
- AI pipeline (`src/bridge.jl`): step logs at `info` (query start / tool call /
  query complete) and `debug` (loop iteration, per-token `kind=stream` with the
  chunk text, tool result).
- TUI: `logBuffer` entries are now `{time, level, origin, kind, msg}`; the
  log panel (F10) colors by level, shows `[level][origin:kind]`, and filters
  by level; every entry is also appended to `~/.kamila/logs/tui.log` (JSONL).
- New `docs/dev_log.md` (this file) for per-session development review.