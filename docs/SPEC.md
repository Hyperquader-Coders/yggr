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
`textDocument/didSave`, `textDocument/didClose`.
Server → client notifications handled: `textDocument/publishDiagnostics`,
`window/logMessage` (log only), `window/showMessage` (log only).
Server → client requests: `workspace/configuration` is answered with one
`null` per requested item, `client/registerCapability` with `null`;
everything else gets a MethodNotFound error response. The request id is
echoed as sent (string or number). Never leave a server request unanswered
(some servers block on it).

No request but `initialize` is sent before the server has answered it, and
hover, completion and formatting are requested only from a server that
advertises them (`hoverProvider`, `completionProvider`,
`documentFormattingProvider`).

## 4. Behavior

### 4.1 Lifecycle
- One file, one buffer, one client, one process: a second `yggr FILE` starts
  its own instance (`G_APPLICATION_NON_UNIQUE`). Project root = nearest
  ancestor of the file containing `.git`, else the file's directory.
- Spawn: `foundry lsp run <gtksourceview-language-id>` with cwd = root;
  `YGGR_LSP_CMD` overrides the whole command line for testing (resolution
  order in FLATPAK.md §3).
- `initialize` params include: `processId`, `rootUri`, `workspaceFolders`,
  `capabilities` advertising `positionEncodings: ["utf-8"]`, hover
  `contentFormat: ["markdown","plaintext"]`, completion with
  `snippetSupport: false`, `publishDiagnostics.versionSupport: true`.
- `didOpen` carries the buffer as it is when the server becomes ready (text
  typed while it started is not lost), followed by a `didSave` so
  check-on-save servers diagnose at once. An edit still waiting out the
  debounce is sent before any hover, completion, formatting or `didSave`.
- Shutdown on window close, or on SIGTERM/SIGINT/SIGHUP (handled as a window
  close): `didClose` → `shutdown` → its reply (≤ 2 s) → `exit` → 2 s grace
  → SIGTERM → 1 s → SIGKILL. A SIGKILL of yggr itself cannot be handled:
  the server then sees EOF on its stdin and is left to exit by itself (OLS
  does not).

### 4.2 Diagnostics
- Squiggle via GtkTextTag per severity: error `PANGO_UNDERLINE_ERROR` red;
  warning same underline, `#b58900`; info/hint a single dim underline
  (Pango has no dotted one).
- GtkSourceMark at the diagnostic's start line, categories
  `lsp-error|lsp-warning|lsp-info`, 16 px symbolic icons. Marks carry no
  tooltip.
- Only publishes for the open document's URI are applied (servers such as
  OLS publish for every file they check); a new one replaces all previous
  diagnostics.
- Stale publishes (version present and ≠ the buffer's) are dropped.

### 4.3 Hover
- Triggered by GtkSourceView's own hover machinery (pointer dwell). Async; a
  request in flight is cancelled (client-side ignore) if the context moves.
- Markdown down-converted to Pango markup (`src/markup/`): fenced and
  indented code blocks→`<tt>` block without the fence lines, thematic breaks
  (`---`) dropped, `#` headings→`<b>`, list markers→bullets, `` `code` ``→`<tt>`,
  `**b**`/`__b__`→`<b>`, `*i*`/`_i_`→`<i>`, links and images→their text,
  everything else literal. Prose is set in the interface font, code in the
  editor's monospace. `kind: "plaintext"` is shown as plain text. Every byte of
  server text is escaped (invalid UTF-8 and control characters become U+FFFD);
  never pass unescaped server text to Pango (markup injection).

### 4.4 Completion
- Triggers: server `triggerCharacters`, Ctrl+Space, and GtkSourceView's
  interactive completion while typing a word.
- Columns: icon (kind), typed-text (label), after (detail).
- Activation applies `textEdit` when present (its range extended to the
  cursor if more of the word was typed since the request) else word-replace
  with `insertText`/`label`; `insertTextFormat==2` items have `$n`/`${n:x}`
  stripped. The proposal list narrows to labels containing the typed word.
- Results capped at 200 items client-side.

### 4.5 Formatting
- Ctrl+Shift+F formats the whole document; `tabSize` and `insertSpaces`
  read from the view's settings.
- Edits sorted descending by (start line, start char), edits at the same
  position kept in array order, applied in one user-action group → single
  undo step. Cursor restored via a GtkTextMark captured before applying.
- A reply computed against an older text (the user typed meanwhile) is
  dropped.

## 5. Failure behavior

Foundry missing, server crash, or malformed JSON: feature degrades
silently (one stderr line); the editor never crashes and never shows a
modal. A server that exits or breaks the stream is reaped, its diagnostics
are cleared, and LSP stays off for the rest of the session — there is no
automatic restart. Server positions are clamped to the buffer and to
character boundaries before they reach GTK.

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
8. Quitting the app — window close, SIGTERM, SIGINT or SIGHUP — orphans
   zero server processes.
