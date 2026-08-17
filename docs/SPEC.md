# SPEC.md — Yggr LSP Integration, MVP

## 1. Goal

An editor pane in Yggr (Odin, GTK4, GtkSourceView 5) gains four LSP
features — diagnostics, hover, completion, formatting — for any language
Foundry can provide a server for, with the LSP client written in Odin and
servers obtained via `foundry lsp run <language>`.

## 2. Non-goals (MVP)

No go-to-definition/references/rename/code actions/semantic tokens, no
incremental text sync (full-text `didChange` is fine at MVP), no
multi-root workspaces, no more than one server per buffer, no
snippet-placeholder editing, no configuration UI.

## 3. Protocol surface (exhaustive for MVP)

Client → server requests: `initialize`, `shutdown`,
`textDocument/hover`, `textDocument/completion`,
`textDocument/formatting`.
Client → server notifications: `initialized`, `exit`,
`textDocument/didOpen`, `textDocument/didChange` (full text, sync kind 1),
`textDocument/didClose`.
Server → client notifications handled: `textDocument/publishDiagnostics`,
`window/logMessage` (log only), `window/showMessage` (log only).
Server → client requests: respond with empty/`null` result to
`workspace/configuration` and `client/registerCapability`; everything else
gets a MethodNotFound error response. Never leave a server request
unanswered (some servers block on it).

## 4. Behavior

### 4.1 Lifecycle
- One client per (language, project root). Project root = nearest ancestor
  of the file containing `.git`, else the file's directory.
- Spawn: `foundry lsp run <gtksourceview-language-id>` with cwd = root;
  `YGGR_LSP_CMD` overrides the whole command line for testing.
- `initialize` params include: `processId`, `rootUri`, `capabilities`
  advertising `positionEncoding: ["utf-8"]`, hover `contentFormat:
  ["markdown","plaintext"]`, completion with `snippetSupport: false`,
  `publishDiagnostics.versionSupport: true`.
- Shutdown on last buffer close or app quit: `shutdown` → `exit` → 2 s
  grace → SIGTERM → 1 s → SIGKILL.

### 4.2 Diagnostics
- Squiggle via GtkTextTag per severity: error `PANGO_UNDERLINE_ERROR` red;
  warning same underline, `#b58900`; info/hint dotted, dim.
- GtkSourceMark per line, categories `lsp-error|lsp-warning|lsp-info`,
  16 px symbolic icons, tooltip = joined messages for that line.
- New publish for a URI replaces all previous diagnostics for that URI.
- Stale publishes (version mismatch) are dropped.

### 4.3 Hover
- Triggered by GtkSourceView's own hover machinery (pointer dwell / K
  keybinding later). Async; a request in flight is cancelled (client-side
  ignore) if the context moves.
- Markdown down-converted to Pango markup: `**b**`→`<b>`, `*i*`→`<i>`,
  backtick spans→`<tt>`, fenced blocks→`<tt>` block, everything else
  escaped with `g_markup_escape_text`. Never pass unescaped server text to
  Pango (markup injection).

### 4.4 Completion
- Triggers: server `triggerCharacters`, Ctrl+Space, and ≥3-char word.
- Columns: icon (kind), typed-text (label), after (detail).
- Activation applies `textEdit` when present else word-replace with
  `insertText`/`label`; `insertTextFormat==2` items have `$n`/`${n:x}`
  stripped.
- Results capped at 200 items client-side.

### 4.5 Formatting
- Ctrl+Shift+F formats the whole document; `tabSize` and `insertSpaces`
  read from the view's settings.
- Edits sorted descending by (start line, start char), applied in one
  user-action group → single undo step. Cursor restored via a GtkTextMark
  captured before applying.

## 5. Failure behavior

Foundry missing, server crash, or malformed JSON: feature degrades
silently (one stderr warning, diagnostics cleared for that URI); the
editor never blocks, never crashes, never shows a modal. Server crash →
one automatic restart per 60 s window, then give up for that session.

## 6. Acceptance criteria

1. `make test` passes with no GTK/Foundry installed (headless core).
2. Framing test proves correct handling of a message split across two
   reads and two messages in one read.
3. Position test proves utf-16→utf-8 conversion on a line containing
   `"héllo 🦀 wörld"` matches hand-computed offsets.
4. Opening a Go file with a type error shows squiggle + gutter mark ≤ 2 s
   after the triggering edit stops (150 ms debounce + server time).
5. Hover over `fmt.Println` shows its doc string, bold rendered bold.
6. Ctrl+Space after `fmt.` lists members; activating one inserts via its
   textEdit at the correct position on a line containing multibyte chars.
7. Ctrl+Shift+F on an unformatted file matches `gofmt` output; one undo
   restores the pre-format text exactly.
8. Quitting the app orphans zero server processes.
