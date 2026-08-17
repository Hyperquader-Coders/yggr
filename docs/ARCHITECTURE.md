# ARCHITECTURE.md — Yggr LSP

## 1. Layering

```
┌──────────────────────────────── GTK main thread ─┐
│ src/ui/                                          │
│  editor.odin      window + GtkSourceView         │
│  diagnostics.odin tags + GtkSourceMarks          │
│  providers.odin   Hover/Completion GObject impls │
│  gtk_bindings.odin foreign decls                 │
└───────────────▲───────────────────────────────────┘
                │ g_idle_add_full(payload)   ▲ requests (any thread-safe call)
┌───────────────┴───────────────────────────┴───────┐
│ src/lsp/   (NO GTK imports, headless-testable)    │
│  client.odin    lifecycle, pending map, docs      │
│  transport.odin subprocess + Content-Length frames│
│  protocol.odin  typed LSP structs (MVP subset)    │
│  encoding.odin  utf16↔utf8 line-offset conversion │
└───────────────▲───────────────────────────────────┘
                │ stdio (JSON-RPC 2.0)
        foundry lsp run <lang>   →   real language server
```

The `vim.lsp` analogy: `src/lsp/` is `vim/lsp/rpc.lua` + `client.lua`;
`src/ui/` is the handler layer that paints results onto buffer APIs.

## 2. Threads and ownership

- **Main thread**: GTK. Owns all buffers, tags, marks, popovers. Sends LSP
  requests/notifications (transport write is mutex-guarded, non-blocking
  in practice; writes are small).
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
  are a monotonically increasing i64.

Shutdown ordering: mark client closing → send `shutdown` (await ≤2 s) →
send `exit` → close stdin → join reader thread (it exits on EOF) → wait
child, escalating SIGTERM/SIGKILL.

## 3. Framing & JSON

Wire format per message: `Content-Length: N\r\n\r\n` + N bytes JSON. The
reader maintains a growable byte buffer; parse loop: find `\r\n\r\n`,
parse Content-Length (case-insensitive header name; ignore Content-Type),
wait until N body bytes available, slice, repeat. This naturally handles
split and coalesced messages — test both.

JSON: `core:encoding/json`. Decode into `json.Value` first, sniff for
`"id"`/`"method"` to classify request vs response vs notification, then
unmarshal params/result into typed structs. Server numbers may arrive as
float — accept both when reading `id`.

## 4. Feature wiring (main thread)

### Diagnostics
On `publishDiagnostics` payload for URI:
1. Version check (drop stale).
2. `gtk_text_buffer_remove_tag` for each of the three severity tags over
   the whole buffer; `gtk_source_buffer_remove_source_marks` for the three
   `lsp-*` categories.
3. For each diagnostic: range → iters via
   `gtk_text_buffer_get_iter_at_line` + `gtk_text_iter_set_line_index`
   (utf-8 byte offset — see §5); clamp to line length;
   `apply_tag`; create `gtk_source_buffer_create_source_mark(NULL,
   category, &line_start_iter)`.
Tags are created once at buffer setup (`gtk_text_buffer_create_tag` with
`underline`, `underline-rgba`). Mark attributes registered once per view
with `gtk_source_view_set_mark_attributes(view, category, attrs, prio)`
and `gtk_source_mark_attributes_set_icon_name(attrs,
"dialog-error-symbolic")` etc.; connect `query-tooltip-text` on the
attributes to serve messages.

### Hover
`GtkSourceHoverProvider.populate_async(provider, context, display, cancellable, cb, data)`:
1. `gtk_source_hover_context_get_iter` → (line, byte-index) → LSP position.
2. Fire `textDocument/hover`; keep the GTask; on LSP reply (marshaled back
   to main) build a `GtkLabel` with converted Pango markup,
   `gtk_source_hover_display_append`, `g_task_return_boolean(task, TRUE)`.
3. If the result is null, return FALSE so the display stays empty.
Register once: `hover = gtk_source_view_get_hover(view);
gtk_source_hover_add_provider(hover, provider)`.

### Completion
Implement `GtkSourceCompletionProvider` (via C shim if needed, §6):
- `get_trigger` / `is_trigger`: match server triggerCharacters.
- `populate_async`: cursor iter → position → `textDocument/completion`;
  wrap items in a `GListStore` of proposal GObjects;
  `g_task_return_pointer(store)`.
- `display`: switch on `gtk_source_completion_cell_get_column`:
  ICON ← kind icon-name, TYPED_TEXT ← label (use
  `gtk_source_completion_fuzzy_highlight` against the typed word),
  AFTER ← detail.
- `activate`: prefer `textEdit` (range→iters, delete, insert) else replace
  word bounds from `gtk_source_completion_context_get_bounds`. Wrap in a
  user action.
Register once: `completion = gtk_source_view_get_completion(view);
gtk_source_completion_add_provider(completion, provider)`.

### Formatting
Response `TextEdit[]` → sort descending by (line, character) → for each:
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

## 6. GObject interfaces from Odin — the C shim escape hatch

Registering a GType that implements GtkSourceCompletionProvider /
HoverProvider requires class/interface init callbacks with exact C ABI.
Odin can do this (`proc "c"`), but the boilerplate (GTypeInfo,
GInterfaceInfo, instance struct layout with parent GObject) is fiddly.
Budget: half a day. Past that, write `src/ui/shim.c`:

```c
// shim.c owns: KatProvider GObject implementing both interfaces.
// Every vfunc forwards to a registered function pointer table:
typedef struct {
  void (*hover_populate)(void *ctx, void *display, void *task);
  void (*completion_populate)(void *ctx, void *task);
  void (*proposal_display)(void *proposal, void *cell);
  void (*proposal_activate)(void *ctx, void *proposal);
} KatLspVtable;
KatProvider *kat_provider_new(const KatLspVtable *vt, void *user_data);
```

Compile with the build (`gcc -c shim.c $(pkg-config --cflags gtk4
gtksourceview-5)`), link the object; Odin fills the vtable with
`proc "c"` functions. This keeps 100% of logic in Odin and only GObject
ceremony in C — the same discipline: only GObject ceremony in C, logic in Odin.

## 7. Debounce & traffic

Buffer `changed` signal → cancel previous `g_timeout_add(150, …)` source →
new one; on fire, snapshot full text, bump version, send `didChange`.
`YGGR_LSP_TRACE=1` dumps every frame (direction, method, id, truncated
body) to stderr. Cap logged body at 2 KiB.

## 8. Foundry notes

- Language id passed to `foundry lsp run` MUST be the GtkSourceView id.
- Foundry ≥ 1.0 (GNOME 49). Not in Mint 22 repos — built from source or
  located via `YGGR_FOUNDRY_BIN`. Absence is a soft failure (SPEC §5).
- `foundry lsp prefer <server> <lang>` is user-side configuration; Yggr
  does not manage it in MVP.
