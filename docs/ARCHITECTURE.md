# ARCHITECTURE.md — Yggr LSP

## 1. Layering

```
┌──────────────────────────────── GTK main thread ─┐
│ src/ui/                                          │
│  editor.odin      window, client lifecycle       │
│  diagnostics.odin tags + GtkSourceMarks          │
│  providers.odin   Hover/Completion providers     │
│  format.odin      formatting, Ctrl+S             │
│  gtk_bindings.odin foreign decls; shim.c GObjects│
└───────────────▲───────────────────────────────────┘
                │ g_idle_add_full(payload)   ▲ requests (any thread-safe call)
┌───────────────┴───────────────────────────┴───────┐
│ src/lsp/   (NO GTK imports, headless-testable)    │
│  client.odin    lifecycle, pending map, docs      │
│  transport.odin subprocess + Content-Length frames│
│  protocol.odin  typed LSP structs (MVP subset)    │
│  encoding.odin  utf16↔utf8 line-offset conversion │
│  hover.odin     Hover.contents → one string       │
│ src/markup/  hover Markdown → escaped Pango       │
└───────────────▲───────────────────────────────────┘
                │ stdio (JSON-RPC 2.0)
        foundry lsp run <lang>   →   real language server
```

The `vim.lsp` analogy: `src/lsp/` is `vim/lsp/rpc.lua` + `client.lua`;
`src/ui/` is the handler layer that paints results onto buffer APIs.

## 2. Threads and ownership

- **Main thread**: GTK. Owns all buffers, tags, marks, popovers. Sends LSP
  requests/notifications (transport write is mutex-guarded and blocks only
  if the server stops reading its stdin).
- **Reader thread** (one per client): blocking loop `read_frame → decode →
  dispatch`. Dispatch NEVER touches GTK. For responses it looks up the id
  in the pending map and invokes the stored callback **still on the reader
  thread**; the callback's only job is to package results and
  `g_idle_add_full(G_PRIORITY_DEFAULT, on_main, payload, free_fn)`.
- **Payload rule**: everything crossing threads is copied into a payload
  struct allocated with the default heap allocator; the main-thread
  consumer frees it in `free_fn`. No borrowed slices across threads —
  `core:encoding/json` output referencing the read buffer must be cloned
  before handoff.
- Pending map: `map[i64]Pending_Request` behind `sync.Mutex`. Request ids
  are a monotonically increasing i64. Every request resolves exactly once:
  with its response, with an error at EOF (`fail_pending_on_eof`), or at once
  on the calling thread if it could not be written.
- Capabilities (`utf8_pos`, trigger characters, which providers exist) are
  written on the reader thread before the atomic `ready` flag is released,
  and read only after `client_ready` has acquired it.
- **Temp allocator**: each thread's `context.temp_allocator` is its own. The
  reader thread frees it after every dispatched message; every GTK callback
  opens with `runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()`, which nests, so a
  callback GTK runs inside another (a buffer edit emitting `changed`) frees
  only its own memory. Nothing that outlives a message or a callback lives in
  temp memory: payloads are cloned onto the heap first. A headless test
  (`test_reader_frees_temp_allocator`) holds the reader's arena to one
  message's worth.
- SIGPIPE is ignored (`client_start`), so writing to a dead server fails with
  EPIPE instead of killing the editor.

Shutdown ordering: `shutdown` request → wait for its reply (≤ 2 s) → `exit`
→ close stdin → join reader thread (it exits on EOF) → wait child,
escalating SIGTERM/SIGKILL. If the reader has already hit EOF (the server
died), the requests are skipped. A server death the client did not cause is
reported through `on_server_exit`; the UI then runs the same teardown on the
main thread and carries on without LSP.

## 3. Framing & JSON

Wire format per message: `Content-Length: N\r\n\r\n` + N bytes JSON. The
vendored OLS reader (`vendor_ols/`) reads header lines byte by byte up to the
blank line — header names case-insensitive, Content-Type accepted and
ignored — then reads exactly N body bytes. That handles split and coalesced
messages (both tested). A Content-Length over 64 MiB is treated as a broken
stream.

JSON: `core:encoding/json` decodes each message into a `json.Value`; dispatch
sniffs `"id"`/`"method"` to classify request vs response vs notification and
the callbacks walk the value directly, cloning what they keep. Server numbers
may arrive as float — accept both when reading `id`. Outgoing messages are
typed structs (`protocol.odin`) encoded by the vendored OLS marshaller.

## 4. Feature wiring (main thread)

### Diagnostics
On `publishDiagnostics` payload for URI:
1. URI check (only the open document) and version check (drop stale).
2. `gtk_text_buffer_remove_tag` for each of the three severity tags over
   the whole buffer; `gtk_source_buffer_remove_source_marks` for the three
   `lsp-*` categories.
3. For each diagnostic: range → iters via
   `gtk_text_buffer_get_iter_at_line` + `gtk_text_iter_set_line_index`
   (utf-8 byte offset — see §5), via `position_to_iter`, which clamps to
   the line and to a character boundary;
   `apply_tag`; create `gtk_source_buffer_create_source_mark(NULL,
   category, &line_start_iter)`.
Tags are created once at buffer setup (`gtk_text_buffer_create_tag` with
`underline`, `underline-rgba`). Mark attributes registered once per view
with `gtk_source_view_set_mark_attributes(view, category, attrs, prio)`
and `gtk_source_mark_attributes_set_icon_name(attrs,
"dialog-error-symbolic")` etc.

### Hover
`GtkSourceHoverProvider.populate_async(provider, context, display, cancellable, cb, data)`:
1. `gtk_source_hover_context_get_iter` → (line, byte-index) → LSP position.
2. Fire `textDocument/hover`; keep the GTask; on the LSP reply (reader
   thread) normalize the contents (`lsp.hover_contents`) and convert them to
   Pango markup (`markup.to_pango`); marshaled back to main, build a
   `GtkLabel` with that markup in the interface font,
   `gtk_source_hover_display_append`, `g_task_return_boolean(task, TRUE)`.
3. If the result is null or empty, complete the task with
   `G_IO_ERROR_NOT_SUPPORTED` (`kat_task_return_declined`): GtkSourceView
   expects a failed populate to carry an error.
Register once: `hover = gtk_source_view_get_hover(view);
gtk_source_hover_add_provider(hover, provider)`.

### Completion
`GtkSourceCompletionProvider`, implemented through the C shim (§6):
- `is_trigger`: match server triggerCharacters.
- `populate_async`: cursor iter → position → `textDocument/completion`;
  wrap items in a `GListStore` of proposal GObjects;
  `g_task_return_pointer(store)`.
- `refilter`: drop proposals whose label does not contain the typed word.
- `display`: switch on `gtk_source_completion_cell_get_column`:
  ICON ← kind icon-name, TYPED_TEXT ← label, AFTER ← detail.
- `activate`: prefer `textEdit` (range→iters, extended to the cursor,
  delete, insert) else replace word bounds from
  `gtk_source_completion_context_get_bounds`. Wrap in a user action.
Register once: `completion = gtk_source_view_get_completion(view);
gtk_source_completion_add_provider(completion, provider)`.

### Formatting
Request against the current text (pending edit flushed first) and remember
its version; a reply for an older version is dropped. Response `TextEdit[]`
→ sort descending by (line, character), stable for equal starts → for each:
range→iters, `gtk_text_buffer_delete`, `gtk_text_buffer_insert`. All
inside one `begin_user_action`/`end_user_action`. Iters are invalidated by
each edit — re-resolve from fresh line/offset each iteration (safe because
we edit strictly bottom-up).

## 5. Position encoding

Advertise `"positionEncoding": ["utf-8"]`. Read the server's choice from
`InitializeResult.capabilities.positionEncoding` (absent ⇒ utf-16).

- utf-8 mode: LSP `character` == byte offset in line ==
  `gtk_text_iter_set_line_index` / `get_line_index`. Zero conversion.
- utf-16 fallback (`encoding.odin`): walk the line's UTF-8 bytes; each
  codepoint < 0x10000 costs 1 utf-16 unit, ≥ 0x10000 costs 2. Provide
  `utf16_to_byte(line: string, u16_off: int) -> int` and inverse. Get the
  line text via `gtk_text_buffer_get_text` between line start/end iters.

Line numbers are 0-based on both sides — no adjustment. Clamp everything:
servers occasionally send end positions past EOL/EOF.

## 6. GObject interfaces from Odin — the C shim

Registering a GType that implements GtkSourceCompletionProvider /
HoverProvider requires class/interface init callbacks with exact C ABI and an
instance struct laid out after its parent GObject. That ceremony lives in
`src/ui/shim.c`: one `KatProvider` type implementing both interfaces, whose
every vfunc forwards into a `KatLspVtable` of Odin `proc "c"` functions
(`hover_populate`, `completion_populate`, `proposal_display`,
`proposal_activate`, `is_trigger`, `refilter`), plus a `KatProposal` GObject
carrying one completion item and the property-varargs helpers for the
severity tags and mark attributes. The Makefile compiles it with
`gcc -c shim.c $(pkg-config --cflags gtk4 gtksourceview-5)` and links the
object into the Odin build. 100% of the logic stays in Odin; only GObject
ceremony is in C.

## 7. Debounce & traffic

Buffer `changed` signal → cancel previous `g_timeout_add(150, …)` source →
new one; on fire, snapshot full text, bump version, send `didChange`. Hover,
completion, formatting and save flush a pending change first.
`YGGR_LSP_TRACE=1` logs one line per frame to stderr — direction, method (or
"response") and byte count — plus the text of `window/logMessage` and
`window/showMessage`. Bodies are not logged.

## 8. Foundry notes

- Language id passed to `foundry lsp run` MUST be the GtkSourceView id.
- Foundry ≥ 1.0 (GNOME 49). Not in Mint 22 repos — built from source or
  located via `YGGR_FOUNDRY_BIN`. Absence is a soft failure (SPEC §5).
- `foundry lsp prefer <server> <lang>` is user-side configuration; Yggr
  does not manage it in MVP.
