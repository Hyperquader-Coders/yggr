package lsp

// client.odin — lifecycle, request correlation, document tracking.
// NO GTK. Callbacks fire on the READER THREAD; the UI layer's callbacks
// must only package a payload and g_idle_add it.

import "base:runtime"
import os2 "core:os"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import ols "vendor_ols"

Response_Callback :: proc(result: json.Value, is_error: bool, user: rawptr)

// Server-pushed notifications the UI subscribes to.
Notification_Handler :: struct {
	on_diagnostics: proc(params_json: []u8, user: rawptr), // raw clone; UI decodes on main thread
	on_server_exit: proc(user: rawptr),                    // reader hit EOF (crash/quit) — UI restart policy (SPEC §5)
	user:           rawptr,
}

Client :: struct {
	transport:   ^Transport,
	reader:      ^thread.Thread,
	next_id:     i64,
	pending_mu:  sync.Mutex,
	pending:     map[i64]Pending_Request,
	docs_mu:     sync.Mutex,
	docs:        map[string]int, // uri -> version (guarded by docs_mu)
	handler:     Notification_Handler,
	utf8_pos:    bool,   // server accepted positionEncoding "utf-8"
	trigger_chars: []string, // from completion capabilities
	initialized: bool,
	trace:       bool,   // YGGR_LSP_TRACE=1
}

Pending_Request :: struct {
	cb:   Response_Callback,
	user: rawptr,
}

client_start :: proc(argv: []string, root_dir: string, handler: Notification_Handler) -> (c: ^Client, ok: bool) {
	t, terr := transport_spawn(argv, root_dir)
	if terr != .None {
		fmt.eprintfln("yggr: spawn failed for %v (soft failure, LSP disabled)", argv)
		return nil, false
	}
	// Client state outlives and crosses the reader thread → heap allocator,
	// independent of any tracking/temp allocator installed in this context.
	c = new(Client, runtime.heap_allocator())
	c.transport = t
	c.pending   = make(map[i64]Pending_Request, runtime.heap_allocator())
	c.docs      = make(map[string]int, runtime.heap_allocator())
	c.handler   = handler
	c.reader    = thread.create_and_start_with_data(c, reader_loop)
	return c, true
}

// ---- outgoing --------------------------------------------------------

client_request :: proc(c: ^Client, method: string, params: any, cb: Response_Callback, user: rawptr) -> i64 {
	sync.mutex_lock(&c.pending_mu)
	c.next_id += 1
	id := c.next_id
	c.pending[id] = Pending_Request{cb, user}
	sync.mutex_unlock(&c.pending_mu)

	send(c, id, method, params)
	return id
}

client_notify :: proc(c: ^Client, method: string, params: any) {
	send(c, 0, method, params) // id 0 => omit id (notification)
}

@(private)
send :: proc(c: ^Client, id: i64, method: string, params: any) {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, `{"jsonrpc":"2.0"`)
	if id != 0 do fmt.sbprintf(&sb, `,"id":%d`, id)
	fmt.sbprintf(&sb, `,"method":%q,"params":`, method)
	// Marshal via the vendored OLS marshaller (rule 10): it honors json:"" tags
	// AND omits nil-union fields, which is how optional LSP params are encoded.
	data, _ := ols.marshal(params, {}, context.temp_allocator)
	strings.write_bytes(&sb, data)
	strings.write_string(&sb, "}")

	body := transmute([]u8)strings.to_string(sb)
	if c.trace do fmt.eprintfln("--> %s (%d bytes)", method, len(body))
	transport_write(c.transport, body)
}

// ---- lifecycle -------------------------------------------------------

// Context threaded through the async `initialize` response back to `done`.
@(private)
Init_Ctx :: struct {
	c:    ^Client,
	done: proc(user: rawptr),
	user: rawptr,
}

// Build InitializeParams per SPEC §4.1, send `initialize`; on reply, capture
// server capabilities (positionEncoding -> c.utf8_pos, completionProvider
// .triggerCharacters -> c.trigger_chars), notify `initialized`, then invoke
// `done`. NOTE: `done` fires on the READER THREAD — the UI layer's `done`
// must only g_idle_add to the main thread.
client_initialize :: proc(c: ^Client, root_uri: string, done: proc(user: rawptr), user: rawptr) {
	// Name the workspace after the root's last path segment (servers key off
	// workspaceFolders to activate a project + diagnostics; rootUri alone
	// isn't enough for OLS).
	ws_name := root_uri
	if idx := strings.last_index_byte(root_uri, '/'); idx >= 0 && idx + 1 < len(root_uri) {
		ws_name = root_uri[idx + 1:]
	}
	params := Initialize_Params{
		process_id = os2.get_pid(),
		root_uri   = root_uri,
		workspace_folders = {{uri = root_uri, name = ws_name}},
		capabilities = {
			general = {position_encodings = {"utf-8"}},
			text_document = {
				hover               = {content_format = {"markdown", "plaintext"}},
				completion          = {completion_item = {snippet_support = false}},
				publish_diagnostics = {version_support = true},
			},
		},
	}
	ic := new(Init_Ctx, runtime.heap_allocator()) // freed on the reader thread
	ic^ = {c = c, done = done, user = user}
	client_request(c, "initialize", params, on_initialize_response, ic)
}

@(private)
on_initialize_response :: proc(result: json.Value, is_error: bool, user: rawptr) {
	ic := (^Init_Ctx)(user)
	defer free(ic, runtime.heap_allocator())
	c := ic.c

	// json.Value is destroyed when dispatch() returns — clone anything we keep.
	if !is_error {
		if caps, ok := dig_object(result, "capabilities"); ok {
			if pe, ok := caps["positionEncoding"].(string); ok {
				c.utf8_pos = pe == "utf-8"
			}
			if cp, ok := caps["completionProvider"].(json.Object); ok {
				if tc, ok := cp["triggerCharacters"].(json.Array); ok {
					chars := make([]string, len(tc), runtime.heap_allocator())
					for v, i in tc {
						s, _ := v.(string)
						chars[i] = strings.clone(s, runtime.heap_allocator())
					}
					c.trigger_chars = chars
				}
			}
		}
	}

	client_notify(c, "initialized", struct {}{})
	c.initialized = true
	if ic.done != nil do ic.done(ic.user)
}

@(private)
dig_object :: proc(v: json.Value, key: string) -> (json.Object, bool) {
	obj, ok := v.(json.Object)
	if !ok do return nil, false
	child, cok := obj[key].(json.Object)
	return child, cok
}

client_did_open :: proc(c: ^Client, uri, language_id, text: string) {
	sync.mutex_lock(&c.docs_mu)
	c.docs[uri] = 0
	sync.mutex_unlock(&c.docs_mu)
	client_notify(c, "textDocument/didOpen", struct {
		text_document: Text_Document_Item `json:"textDocument"`,
	}{{uri = uri, language_id = language_id, version = 0, text = text}})
}

client_did_change_full :: proc(c: ^Client, uri, full_text: string) -> (version: int) {
	sync.mutex_lock(&c.docs_mu)
	c.docs[uri] += 1
	version = c.docs[uri]
	sync.mutex_unlock(&c.docs_mu)
	client_notify(c, "textDocument/didChange", struct {
		text_document:   Versioned_Text_Document_Identifier `json:"textDocument"`,
		content_changes: []struct{ text: string `json:"text"` } `json:"contentChanges"`,
	}{{uri, version}, {{full_text}}})
	return
}

// Current version tracked for `uri`, or -1 if unknown. Used by the UI to
// version-check publishDiagnostics before painting (SPEC §4.2).
client_doc_version :: proc(c: ^Client, uri: string) -> int {
	sync.mutex_lock(&c.docs_mu)
	defer sync.mutex_unlock(&c.docs_mu)
	v, ok := c.docs[uri]
	return v if ok else -1
}

// Notify the server the document was saved to disk. Some servers (OLS) only
// run their checker / emit diagnostics on save, not on open/change.
client_did_save :: proc(c: ^Client, uri: string) {
	client_notify(c, "textDocument/didSave", struct {
		text_document: Text_Document_Identifier `json:"textDocument"`,
	}{{uri}})
}

client_did_close :: proc(c: ^Client, uri: string) {
	client_notify(c, "textDocument/didClose", struct {
		text_document: Text_Document_Identifier `json:"textDocument"`,
	}{{uri}})
	sync.mutex_lock(&c.docs_mu)
	delete_key(&c.docs, uri)
	sync.mutex_unlock(&c.docs_mu)
}

// Full LSP + process teardown. Idempotent-ish; call once on last-buffer
// close or app quit. Guarantees zero orphaned servers (SPEC criterion 8):
// shutdown req -> exit notif -> close stdin -> join reader (exits on EOF) ->
// transport_shutdown (2 s grace, SIGTERM, 1 s, SIGKILL).
client_shutdown :: proc(c: ^Client) {
	if c == nil do return
	if c.transport != nil && !c.transport.closed {
		client_request(c, "shutdown", struct {}{}, nil, nil)
		client_notify(c, "exit", struct {}{})
		transport_close_stdin(c.transport)
	}
	if c.reader != nil {
		thread.join(c.reader)
		thread.destroy(c.reader)
		c.reader = nil
	}
	transport_shutdown(c.transport)
	client_free(c)
}

@(private)
client_free :: proc(c: ^Client) {
	sync.mutex_lock(&c.pending_mu)
	delete(c.pending)
	sync.mutex_unlock(&c.pending_mu)
	sync.mutex_lock(&c.docs_mu)
	delete(c.docs)
	sync.mutex_unlock(&c.docs_mu)
	// trigger_chars were cloned on the reader thread with the heap allocator;
	// free them the same way (this runs on the main thread).
	for s in c.trigger_chars do delete(s, runtime.heap_allocator())
	delete(c.trigger_chars, runtime.heap_allocator())
	free(c.transport, runtime.heap_allocator())
	free(c, runtime.heap_allocator())
}

// ---- incoming (reader thread!) ----------------------------------------

@(private)
reader_loop :: proc(data: rawptr) {
	// CRITICAL (ARCH §2): the reader thread must never touch the ambient
	// context allocator — under `odin test` that is a per-test tracking
	// allocator shared with the main thread and NOT thread-safe. Pin every
	// allocation this thread makes (json parse/destroy, frame bodies, payload
	// clones, capability strings) to the process heap allocator.
	context.allocator = runtime.heap_allocator()

	c := (^Client)(data)
	for {
		body, err := transport_read_frame(c.transport)
		if err != .None do break
		defer delete(body)
		dispatch(c, body)
	}
	// EOF. Fail any in-flight requests so awaiting UI callbacks resolve
	// (empty) rather than hang.
	fail_pending_on_eof(c)
	// If stdin is already closed, this EOF is our own orderly shutdown — no
	// restart. Otherwise the server died unexpectedly (SPEC §5).
	if !c.transport.closed && c.handler.on_server_exit != nil {
		c.handler.on_server_exit(c.handler.user)
	}
}

@(private)
fail_pending_on_eof :: proc(c: ^Client) {
	sync.mutex_lock(&c.pending_mu)
	pend := c.pending
	c.pending = make(map[i64]Pending_Request, runtime.heap_allocator())
	sync.mutex_unlock(&c.pending_mu)
	for _, req in pend {
		if req.cb != nil do req.cb(nil, true, req.user)
	}
	delete(pend)
}

@(private)
dispatch :: proc(c: ^Client, body: []u8) {
	v, perr := json.parse(body, .JSON, false)
	if perr != nil do return
	defer json.destroy_value(v)
	obj, is_obj := v.(json.Object)
	if !is_obj do return

	if c.trace {
		m, _ := obj["method"].(string)
		fmt.eprintfln("<-- %s (%d bytes)", m if m != "" else "response", len(body))
	}

	method, has_method := obj["method"].(string)
	_, has_id := obj["id"]

	switch {
	case has_method && !has_id: // notification from server
		switch method {
		case "textDocument/publishDiagnostics":
			if c.handler.on_diagnostics != nil {
				// Clone raw bytes on the heap; UI decodes + version-checks on
				// main thread and frees with the heap allocator (ARCH §2).
				clone := make([]u8, len(body), runtime.heap_allocator())
				copy(clone, body)
				c.handler.on_diagnostics(clone, c.handler.user)
			}
		case "window/logMessage", "window/showMessage":
			// log-only per SPEC §3; surface the text when tracing.
			if c.trace {
				if p, ok := obj["params"].(json.Object); ok {
					if m, ok := p["message"].(string); ok do fmt.eprintfln("    [srv] %s", m)
				}
			}
		}
	case has_method && has_id: // request FROM server — must answer (SPEC §3)
		id_num := id_as_i64(obj["id"])
		switch method {
		case "workspace/configuration", "client/registerCapability":
			reply_null(c, id_num)
		case:
			reply_method_not_found(c, id_num)
		}
	case has_id: // response to us
		id_num := id_as_i64(obj["id"])
		sync.mutex_lock(&c.pending_mu)
		req, found := c.pending[id_num]
		if found do delete_key(&c.pending, id_num)
		sync.mutex_unlock(&c.pending_mu)
		if found && req.cb != nil {
			result, has_result := obj["result"]
			_, has_err := obj["error"]
			req.cb(result if has_result else nil, has_err, req.user)
		}
	}
}

@(private)
id_as_i64 :: proc(v: json.Value) -> i64 {
	#partial switch n in v {
	case json.Integer: return i64(n)
	case json.Float:   return i64(n)
	}
	return 0
}

@(private)
reply_null :: proc(c: ^Client, id: i64) {
	body := fmt.tprintf(`{{"jsonrpc":"2.0","id":%d,"result":null}}`, id)
	transport_write(c.transport, transmute([]u8)body)
}

@(private)
reply_method_not_found :: proc(c: ^Client, id: i64) {
	body := fmt.tprintf(`{{"jsonrpc":"2.0","id":%d,"error":{{"code":-32601,"message":"not implemented"}}}}`, id)
	transport_write(c.transport, transmute([]u8)body)
}
