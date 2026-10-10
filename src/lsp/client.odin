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
import "core:sys/posix"
import "core:thread"
import "core:time"
import ols "vendor_ols"

Response_Callback :: proc(result: json.Value, is_error: bool, user: rawptr)

// Server-pushed notifications the UI subscribes to.
Notification_Handler :: struct {
	on_diagnostics: proc(params_json: []u8, user: rawptr), // raw clone; UI decodes on main thread
	on_server_exit: proc(user: rawptr),                    // reader hit EOF without our shutdown (crash/quit, SPEC §5)
	user:           rawptr,
}

Client :: struct {
	transport:     ^Transport,
	reader:        ^thread.Thread,
	next_id:       i64,
	pending_mu:    sync.Mutex,
	pending:       map[i64]Pending_Request,
	docs_mu:       sync.Mutex,
	docs:          map[string]int, // uri (heap clone) -> version (guarded by docs_mu)
	handler:       Notification_Handler,
	// Server capabilities: written once on the reader thread before `ready`
	// is set and never changed after, so read them only once client_ready has
	// returned true.
	utf8_pos:      bool,     // server accepted positionEncoding "utf-8"
	trigger_chars: []string, // from completion capabilities
	can_hover:     bool,     // hoverProvider
	can_complete:  bool,     // completionProvider
	can_format:    bool,     // documentFormattingProvider
	ready:         bool,     // atomic: initialize answered, `initialized` sent
	reader_done:   bool,     // atomic: the reader thread has hit EOF
	trace:         bool,     // YGGR_LSP_TRACE=1
}

Pending_Request :: struct {
	cb:   Response_Callback,
	user: rawptr,
}

client_start :: proc(argv: []string, root_dir: string, handler: Notification_Handler) -> (c: ^Client, ok: bool) {
	// A write to a server that has died must fail with EPIPE rather than kill
	// the editor with SIGPIPE. The disposition is process-wide; no editor
	// wants the default.
	posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN)

	t, terr := transport_spawn(argv, root_dir)
	if terr != .None {
		fmt.eprintfln("yggr: cannot start language server %q; LSP disabled", argv[0] if len(argv) > 0 else "")
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

// Whether the initialize handshake has completed. Until it has, the client
// must send no request but `initialize` (LSP lifecycle), and utf8_pos /
// trigger_chars are not yet known.
client_ready :: proc(c: ^Client) -> bool {
	return c != nil && sync.atomic_load_explicit(&c.ready, .Acquire)
}

// ---- outgoing --------------------------------------------------------

// Send a request; `cb` receives the result on the reader thread. If the
// request cannot be sent (the server is gone), `cb` runs at once on the
// calling thread with is_error = true, so every request resolves exactly once.
// Returns the request id, or 0 when it was not sent.
client_request :: proc(c: ^Client, method: string, params: any, cb: Response_Callback, user: rawptr) -> i64 {
	sync.mutex_lock(&c.pending_mu)
	c.next_id += 1
	id := c.next_id
	c.pending[id] = Pending_Request{cb, user}
	sync.mutex_unlock(&c.pending_mu)

	if send(c, id, method, params) do return id

	// The reader thread may already have failed it at EOF; resolve it once.
	sync.mutex_lock(&c.pending_mu)
	_, found := c.pending[id]
	if found do delete_key(&c.pending, id)
	sync.mutex_unlock(&c.pending_mu)
	if found && cb != nil do cb(nil, true, user)
	return 0
}

// Send a notification. A failed write means the server is gone, which the
// reader thread reports once through on_server_exit; there is nothing more
// for a notification's caller to do.
client_notify :: proc(c: ^Client, method: string, params: any) {
	send(c, 0, method, params) // id 0 => omit id (notification)
}

// Frame and write one message. A nil `params` omits the field (LSP methods
// whose params are void: shutdown, exit). Uses the temp allocator, which the
// caller's thread frees (main: per GTK callback; reader: per message).
@(private)
send :: proc(c: ^Client, id: i64, method: string, params: any) -> bool {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, `{"jsonrpc":"2.0"`)
	if id != 0 do fmt.sbprintf(&sb, `,"id":%d`, id)
	fmt.sbprintf(&sb, `,"method":%q`, method)
	if params.id != nil {
		// Marshal via the vendored OLS marshaller (rule 10): it honors json:""
		// tags AND omits nil-union fields, which is how optional LSP params are
		// encoded.
		data, merr := ols.marshal(params, {}, context.temp_allocator)
		if merr != nil {
			fmt.eprintfln("yggr: cannot encode %s: %v", method, merr)
			return false
		}
		strings.write_string(&sb, `,"params":`)
		strings.write_bytes(&sb, data)
	}
	strings.write_string(&sb, "}")

	body := transmute([]u8)strings.to_string(sb)
	if c.trace do fmt.eprintfln("--> %s (%d bytes)", method, len(body))
	return transport_write(c.transport, body) == .None
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
// .triggerCharacters -> c.trigger_chars, which of hover / completion /
// formatting it provides), notify `initialized`, mark the
// client ready, then invoke `done`. NOTE: `done` fires on the READER THREAD —
// the UI layer's `done` must only g_idle_add to the main thread. If the server
// answers with an error (or dies first), the client never becomes ready and
// `done` is not called.
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

	if is_error {
		// An error reply, or EOF before any reply (fail_pending_on_eof); a dead
		// server is reported by on_server_exit, so only a refusal is logged.
		if !sync.atomic_load(&c.reader_done) {
			fmt.eprintln("yggr: language server refused to initialize; LSP disabled")
		}
		return
	}

	// json.Value is destroyed when dispatch() returns — clone anything we keep.
	if caps, ok := dig_object(result, "capabilities"); ok {
		if pe, is_str := caps["positionEncoding"].(string); is_str {
			c.utf8_pos = pe == "utf-8"
		}
		c.can_hover    = provides(caps, "hoverProvider")
		c.can_complete = provides(caps, "completionProvider")
		c.can_format   = provides(caps, "documentFormattingProvider")
		if cp, has_cp := caps["completionProvider"].(json.Object); has_cp {
			if tc, has_tc := cp["triggerCharacters"].(json.Array); has_tc {
				chars := make([dynamic]string, 0, len(tc), runtime.heap_allocator())
				for v in tc {
					if s, is_s := v.(string); is_s do append(&chars, strings.clone(s, runtime.heap_allocator()))
				}
				c.trigger_chars = chars[:]
			}
		}
	}

	client_notify(c, "initialized", struct {}{})
	sync.atomic_store_explicit(&c.ready, true, .Release)
	if ic.done != nil do ic.done(ic.user)
}

// A *Provider capability is `true` or an options object; absent, null or
// `false` means the server does not provide it.
@(private)
provides :: proc(caps: json.Object, key: string) -> bool {
	#partial switch v in caps[key] {
	case json.Boolean: return bool(v)
	case json.Object:  return true
	}
	return false
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
	if _, known := c.docs[uri]; !known {
		c.docs[strings.clone(uri, runtime.heap_allocator())] = 0
	} else {
		c.docs[uri] = 0
	}
	sync.mutex_unlock(&c.docs_mu)
	client_notify(c, "textDocument/didOpen", struct {
		text_document: Text_Document_Item `json:"textDocument"`,
	}{{uri = uri, language_id = language_id, version = 0, text = text}})
}

// Send the whole new text of an open document; returns its new version, or -1
// (nothing sent) if `uri` was never opened.
client_did_change_full :: proc(c: ^Client, uri, full_text: string) -> (version: int) {
	sync.mutex_lock(&c.docs_mu)
	cur, known := &c.docs[uri]
	if known {
		cur^ += 1
		version = cur^
	}
	sync.mutex_unlock(&c.docs_mu)
	if !known do return -1
	client_notify(c, "textDocument/didChange", struct {
		text_document:   Versioned_Text_Document_Identifier `json:"textDocument"`,
		content_changes: []struct{ text: string `json:"text"` } `json:"contentChanges"`,
	}{{uri, version}, {{full_text}}})
	return
}

// Current version tracked for `uri`, or -1 if unknown. Used by the UI to
// version-check publishDiagnostics before painting (SPEC §4.2) and to drop
// formatting edits computed against an older text.
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
	if _, known := c.docs[uri]; known {
		key, _ := delete_key(&c.docs, uri)
		delete(key, runtime.heap_allocator())
	}
	sync.mutex_unlock(&c.docs_mu)
}

// How long client_shutdown waits for the server to answer `shutdown`.
SHUTDOWN_REPLY_TIMEOUT :: 2 * time.Second

// Full LSP + process teardown; frees the client. Call once, from the thread
// that started it, on last-buffer close, app quit, or after on_server_exit.
// Guarantees zero orphaned servers (SPEC criterion 8): shutdown request →
// its reply (≤ 2 s) → exit notification → close stdin → join reader (exits
// on EOF) → transport_shutdown (2 s grace, SIGTERM, 1 s, SIGKILL). A server
// that is already gone skips straight to closing stdin.
client_shutdown :: proc(c: ^Client) {
	if c == nil do return
	if !sync.atomic_load(&c.reader_done) && !transport_is_closed(c.transport) {
		// LSP: `exit` only after the `shutdown` reply, or the server may exit
		// with an error code (or ignore it) while still finishing work.
		answered: sync.Sema
		client_request(c, "shutdown", nil, proc(_: json.Value, _: bool, user: rawptr) {
			sync.sema_post((^sync.Sema)(user))
		}, &answered)
		// The callback can still fire after a timeout, but only while this
		// frame is alive: the reader is joined below before it returns.
		_ = sync.sema_wait_with_timeout(&answered, SHUTDOWN_REPLY_TIMEOUT)
		client_notify(c, "exit", nil)
	}
	transport_close_stdin(c.transport)
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
	// The reader thread has been joined: nothing else touches the client now.
	delete(c.pending)
	for uri in c.docs do delete(uri, runtime.heap_allocator())
	delete(c.docs)
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
		dispatch(c, body)
		delete(body)
		// The temp allocator is this thread's own. Nothing outlives a message
		// in it: callbacks hand the main thread heap copies, so every temp
		// allocation made for this message (header parsing, marshalled
		// replies, hover text) is dead here.
		free_all(context.temp_allocator)
	}
	sync.atomic_store(&c.reader_done, true)
	// EOF. Fail any in-flight requests so awaiting UI callbacks resolve
	// (empty) rather than hang.
	fail_pending_on_eof(c)
	free_all(context.temp_allocator)
	// If stdin is already closed, this EOF is our own orderly shutdown.
	// Otherwise the server died or broke the stream (SPEC §5).
	if !transport_is_closed(c.transport) && c.handler.on_server_exit != nil {
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
	if perr != nil {
		if c.trace do fmt.eprintfln("<-- unparsable message (%d bytes): %v", len(body), perr)
		return
	}
	defer json.destroy_value(v)
	obj, is_obj := v.(json.Object)
	if !is_obj do return

	if c.trace {
		m, _ := obj["method"].(string)
		fmt.eprintfln("<-- %s (%d bytes)", m if m != "" else "response", len(body))
	}

	method, has_method := obj["method"].(string)
	id, has_id := obj["id"]

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
					if m, is_msg := p["message"].(string); is_msg do fmt.eprintfln("    [srv] %s", m)
				}
			}
		}
	case has_method && has_id: // request FROM server — must answer (SPEC §3)
		reply := server_request_reply(id, method, obj["params"])
		transport_write(c.transport, transmute([]u8)reply)
	case has_id: // response to us
		id_num := id_as_i64(id)
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

// The reply to a request the server sent us (SPEC §3). The id is echoed as the
// server sent it — JSON-RPC allows a string or a number. workspace/configuration
// gets one null per requested item (no client-side settings);
// client/registerCapability gets null; anything else MethodNotFound. Allocated
// with the temp allocator.
@(private)
server_request_reply :: proc(id: json.Value, method: string, params: json.Value) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"jsonrpc":"2.0","id":`)
	#partial switch v in id {
	case json.Integer, json.Float:
		fmt.sbprintf(&b, "%d", id_as_i64(id))
	case json.String:
		quoted, _ := json.marshal(v, {}, context.temp_allocator)
		strings.write_bytes(&b, quoted)
	case:
		strings.write_string(&b, "null")
	}
	switch method {
	case "workspace/configuration":
		n := 0
		if p, ok := params.(json.Object); ok {
			if items, has_items := p["items"].(json.Array); has_items do n = len(items)
		}
		strings.write_string(&b, `,"result":[`)
		for i in 0 ..< n {
			if i > 0 do strings.write_byte(&b, ',')
			strings.write_string(&b, "null")
		}
		strings.write_string(&b, "]}")
	case "client/registerCapability":
		strings.write_string(&b, `,"result":null}`)
	case:
		strings.write_string(&b, `,"error":{"code":-32601,"message":"method not supported"}}`)
	}
	return strings.to_string(b)
}
