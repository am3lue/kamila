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

## Session 2026-08-31 — Input-section audit: voice-record Esc/quit guard

Origin: TUI · Kind: ui/input · Level: high

### Fixed — Esc / quit during voice recording (origin: tui, kind: ui, level: high)
Audited the input section (`ChatInput.js`, `Keybindings.js`, `KamilaApp.js`
`_onInputKeyPress` / `_dismissOverlays` / `quitApp` / `app.quit` routing).
Confirmed a latent HIGH bug the earlier verbose TUI review had flagged but
never fixed: `_dismissOverlays()` (bound to `Esc` twice — via the
`overlay.dismiss` action and directly via `screen.key(['escape'], …)`) called
`process.exit(0)` without checking `uiState.voiceRecording`. So pressing Esc
mid-capture — which `VoiceIndicator` renders as `[Esc] Cancel` and the input
hint promises ("Recording... Press Esc to cancel") — actually killed the whole
app and abandoned the in-flight `Bridge.audio.record` promise, which would then
resolve later and mutate UI state from beyond the grave.

- `_dismissOverlays`: if `voiceRecording`, call new `_cancelVoiceRecord()` and
  return instead of exiting.
- `quitApp()` + the `app.quit` C-c binding now route through the same guard
  (previously the binding inlined `bridge.stop(); process.exit(0)`).
- New `_cancelVoiceRecord()`: sets `_voiceCancelled`, stops/cancels the
  `VoiceIndicator`, clears the input hint, appends a cancel notice, refocuses
  the input, re-renders.
- `_startVoiceRecord`: resets `_voiceCancelled = false`; both the `.then`
  and `.catch` of `Bridge.audio.record` early-return when `_voiceCancelled`,
  so a late-recording resolution after a cancel can no longer overwrite the
  input value / append a draft while the user has moved on.
- `tui.log` path: `tuiLogDir` now always includes the `logs` segment even when
  `KAMILA_HOME` is set (previously `KAMILA_HOME` branch dropped it, landing the
  file at `~/.kamila/tui.log` instead of `~/.kamila/logs/tui.log`).

### Extracted patterns (for skill/rule updates)
1. **Keybinding-dismiss vs long-running operation**: a global "dismiss"
   binding (Esc) that falls through to a quit path must be a *gated escape
   hatch*, not an unconditional exit. Any key that can kill the process must
   first consult the currently active blocking mode (e.g. voiceRecording) and
   cancel that mode instead of exiting. Rule: `process.exit` is never reached
   from a key handler without a positive "nothing in-flight / idle" check.
2. **Late-result poisoning of async UI**: when a long-running bridge call
   (`record`) outlives its UI intent (user hit Esc cancel), the resolving
   promise must not write back to state/input. Introduce a monotonic cancel
   flag (`_voiceCancelled`) reset at start and checked at both `.then` and
   `.catch`; never guard only one branch.
3. **Single source for process teardown**: route every quit path (`app.quit`
   binding, `quitApp()`, `_dismissOverlays` fallthrough) through one guarded
   method so a future mode (recording, unsaved draft, running task) only needs
   one guard to be updated. Inlining `process.exit` in the binding was the
   defect — an inline teardown can't be mode-aware.
4. **Env-var path composition**: when building a log/config dir from
   `process.env.KAMILA_HOME || default`, always append the subdir with
   `path.join(..., 'logs')` unconditionally — don't expect the env var to carry
   it. The fallback had `'logs'`; the env branch silently didn't.

### Tests added
- `tui-v2/test/unit/voiceCancel.test.js` (node:test): Esc-cancel does not
  exit / stops bridge / sets `_voiceCancelled`; `_cancelVoiceRecord` sets the
  gating flag + refocuses; idle paths still quit; `quitApp` cancels when
  recording and quits when idle. 5/5 pass.

### Post-review hardening (independent code review → H1 + W1)
A standalone code review (full 54-file scope vs `origin/Agent0.2`) found no
CRITICAL issues and approved, recommending two pre-merge fixes which were applied:

- **H1 (high) — tool-arg content was persisted at `info`** (`src/bridge.jl`):
  `ai tool call` / `ai agent tool call` logged up to 200 chars of tool
  arguments (shell commands, file writes) to `~/.kamila/logs/kamila.log` at the
  default `info` level, contradicting the opt-in-verbose intent. Split each call
  into `info` metadata (`name`, `args_len`) + a `debug`-only `ai tool call args`
  payload. Verified: bridge suite 154/154 green; the `info` line now reads
  `name=run_shell_command args_len=53` with no content.
- **W1 (warning) — link/image url terminal-tag injection** (`MessageRenderer.js`):
  `renderToken` concatenated `token.href` and image `text`/`href` without
  `escapeBraces`, so `[x](a{red-fg}hi{/})` could inject blessed style tags into
  the terminal string. Escaped all three. Terminal-only impact (cosmetic), not
  RCE — hence warning, not critical.

Also noted (not fixed this round): policy file at `~/.kamila_policy.json` sits
outside the guarded `~/.kamila/config` (0700) — migrate candidate W3; `npm run
lint` is warning-only (43 unused imports) and not wired into CI (S5/S6);
duplicate-column migration warnings spam stderr on cold start (S4).

### Pattern reaffirmed (from review)
- **Secrets/log hygiene asymmetry**: a security blocker was a *logging
  default*, not a runtime bug — the reviewer found values persisted at `info`
  that the code comments claimed were debug-gated. General rule: when a
  sensitive field appears in any log call, treat its *level* as a
  security-relevant decision; don't assume `info` is safe just because it's
  the "common" level. Keep payload content at `debug` and metadata at `info`.