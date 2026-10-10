package ui

// editor.odin — GTK main-thread application shell.
// Window + GtkSourceView + file load, language detection, LSP client
// lifecycle, debounced didChange (SPEC/ARCH §7), save, and clean shutdown.
// All GTK calls here run on the main thread.
//
// Temp memory: every GTK callback (`proc "c"`) opens with
// runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(), which releases the temp memory
// it allocated when it returns. Guards nest, so a callback GTK runs inside
// another (a buffer edit emitting "changed") cannot free its caller's memory.
// Nothing kept past a callback may live in temp memory.

import "base:runtime"
import os2 "core:os"
import "core:fmt"
import "core:strings"
import "core:path/filepath"
import "core:sys/posix"
import lsp "../lsp"
import ols "../lsp/vendor_ols"
import paths "../paths"

APP_ID :: "io.github.hyperquader.Yggr"

Editor_State :: struct {
	app:             gpointer,
	window:          gpointer,
	view:            gpointer, // GtkSourceView*
	buffer:          gpointer, // GtkSourceBuffer* (also a GtkTextBuffer*)
	file_path:       string,
	uri:             string,
	root:            string,
	language_id:     string,
	client:          ^lsp.Client,
	doc_open:        bool, // didOpen sent: edits now go out as didChange
	closed:          bool, // window destroyed: idles still queued must not touch it
	debounce_source: u32,  // g_timeout source id, 0 = none

	// Severity tag handles (GtkTextTag*).
	tag_error, tag_warning, tag_info: gpointer,

	// Provider (KatProvider*) + its vtable (kept alive).
	provider: gpointer,
	vtable:   Kat_Lsp_Vtable,
}

DEBOUNCE_MS :: 150

// Entry point from main.odin.
run :: proc(path: string) {
	i18n_init() // localization (en source + de catalog) before any UI string
	ed := new(Editor_State)
	// No file → empty "Untitled" buffer (bare launch / double-click). With a
	// file, paths.expand expands a leading ~ and makes it lexically absolute
	// (Go's filepath.Abs): unlike core filepath.abs it does not open or
	// realpath the file, so a URI and root are built without touching the
	// filesystem or resolving symlinks.
	if path == "" {
		ed.file_path = ""
	} else if expanded, eerr := paths.expand(path, context.allocator); eerr == nil {
		ed.file_path = expanded
	} else {
		ed.file_path = path
	}

	// NON_UNIQUE: one process per file. A unique GtkApplication would hand a
	// second `yggr other.odin` to the running instance, whose activate knows
	// nothing of the new file — and Editor_State holds exactly one buffer and
	// one client.
	app := gtk_application_new(APP_ID, G_APPLICATION_NON_UNIQUE)
	ed.app = app
	g_signal_connect_data(app, "activate", rawptr(on_activate), ed, nil, G_CONNECT_DEFAULT)

	// SIGTERM, SIGINT and SIGHUP close the window the way its close button
	// does, so the language server is shut down instead of orphaned (SPEC
	// criterion 8). The default action would kill yggr and leave it running.
	for sig in ([?]posix.Signal{.SIGHUP, .SIGINT, .SIGTERM}) {
		g_unix_signal_add(i32(sig), on_quit_signal, ed)
	}

	g_application_run(app, 0, nil)

	// Belt-and-suspenders: if the destroy handler didn't already, make sure
	// no server survives us (SPEC criterion 8).
	if ed.client != nil {
		lsp.client_shutdown(ed.client)
		ed.client = nil
	}
	g_object_unref(app)
}

on_activate :: proc "c" (app: gpointer, user: gpointer) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	ed := (^Editor_State)(user)
	if ed.window != nil || ed.closed {
		if ed.window != nil do gtk_window_present(ed.window)
		return
	}

	// Load file text (soft-fail to empty on error — editor still opens). An
	// empty file_path means an untitled buffer (no file to read, no LSP).
	text := ""
	if ed.file_path != "" {
		data, rerr := os2.read_entire_file(ed.file_path, context.temp_allocator)
		if rerr == nil {
			text = string(data)
		} else if rerr != os2.General_Error.Not_Exist { // a new file is created on save
			fmt.eprintfln("yggr: cannot read %s: %v", ed.file_path, rerr)
		}
	}

	// Language detection via GtkSourceView, then Foundry keys off the id.
	lm := gtk_source_language_manager_get_default()
	lang: gpointer = nil
	if ed.file_path != "" {
		lang = gtk_source_language_manager_guess_language(lm, cstr(ed.file_path), nil)
		// Extension fallback when content/mime guessing fails (FLATPAK.md §3).
		if lang == nil {
			if id := ext_language_id(ed.file_path); id != "" {
				lang = gtk_source_language_manager_get_language(lm, cstr(id))
			}
		}
	}
	buffer: gpointer = lang != nil ? gtk_source_buffer_new_with_language(lang) : gtk_source_buffer_new(nil)
	ed.buffer = buffer
	ed.language_id = lang != nil ? strings.clone(string(gtk_source_language_get_id(lang))) : ""

	// Style scheme so the source renders as highlighted code (like GNOME Text
	// Editor / GtkSourceView 5 apps). Prefer the Adwaita scheme, fall back to
	// classic; a NULL scheme is a harmless no-op.
	sm := gtk_source_style_scheme_manager_get_default()
	scheme := gtk_source_style_scheme_manager_get_scheme(sm, "Adwaita-dark")
	if scheme == nil do scheme = gtk_source_style_scheme_manager_get_scheme(sm, "classic")
	if scheme != nil do gtk_source_buffer_set_style_scheme(buffer, scheme)

	gtk_text_buffer_set_text(buffer, cstr(text), i32(len(text)))

	view := gtk_source_view_new_with_buffer(buffer)
	g_object_unref(buffer) // the view holds its own reference
	gtk_source_view_set_show_line_numbers(view, true)
	gtk_text_view_set_monospace(view, true)
	ed.view = view

	sw := gtk_scrolled_window_new()
	gtk_scrolled_window_set_child(sw, view)

	win := gtk_application_window_new(app)
	gtk_window_set_default_size(win, 960, 680)
	title := fmt.tprintf("Yggr — %s", tr("Untitled")) if ed.file_path == "" else fmt.tprintf("Yggr — %s", ed.file_path)
	gtk_window_set_title(win, cstr(title))
	gtk_window_set_child(win, sw)
	ed.window = win

	// Created before the client so diagnostics that arrive immediately after
	// didOpen have somewhere to land.
	diagnostics_setup(ed)
	providers_setup(ed)

	// Ctrl+Shift+F → format, Ctrl+S → save.
	kc := gtk_event_controller_key_new()
	g_signal_connect_data(kc, "key-pressed", rawptr(on_key_pressed), ed, nil, G_CONNECT_DEFAULT)
	gtk_widget_add_controller(view, kc)

	// Spawn + initialize the LSP client, then debounce edits.
	editor_start_client(ed)
	g_signal_connect_data(buffer, "changed", rawptr(on_buffer_changed), ed, nil, G_CONNECT_DEFAULT)
	g_signal_connect_data(win, "destroy", rawptr(on_window_destroy), ed, nil, G_CONNECT_DEFAULT)

	gtk_window_present(win)
	gtk_widget_grab_focus(view)
}

// ---- LSP client lifecycle -------------------------------------------

editor_start_client :: proc(ed: ^Editor_State) {
	// Untitled buffer (no file): no language / project root / server.
	if ed.file_path == "" do return
	ed.root = compute_project_root(ed.file_path)
	argv, ok := resolve_server_argv(ed.language_id)
	if !ok {
		fmt.eprintln("yggr: no language server for this file (no YGGR_LSP_CMD, registry entry or language); LSP disabled")
		return
	}

	handler := lsp.Notification_Handler{
		on_diagnostics = diagnostics_from_reader_thread,
		on_server_exit = server_exit_from_reader_thread,
		user           = ed,
	}
	c, started := lsp.client_start(argv, ed.root, handler)
	if !started do return // soft failure already logged by client_start
	ed.client = c

	ed.uri = make_file_uri(ed.file_path)
	if trace := os2.get_env("YGGR_LSP_TRACE", context.temp_allocator); trace == "1" {
		c.trace = true
	}

	root_uri := make_file_uri(ed.root)
	lsp.client_initialize(c, root_uri, on_initialize_done, ed)
}

// Reader thread: the handshake is done. didOpen needs the buffer text, so it is
// sent from the main thread.
on_initialize_done :: proc(user: rawptr) {
	g_idle_add_full(G_PRIORITY_DEFAULT, on_client_ready_main, user, nil)
}

on_client_ready_main :: proc "c" (user: gpointer) -> gboolean {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	ed := (^Editor_State)(user)
	if ed.closed || ed.client == nil do return false
	// Open with the buffer as it is now: anything typed while the server was
	// starting is in it, so a pending debounce has nothing left to send.
	if ed.debounce_source != 0 {
		g_source_remove(ed.debounce_source)
		ed.debounce_source = 0
	}
	ctext := buffer_all_text(ed.buffer) // g_malloc'd cstring
	lsp.client_did_open(ed.client, ed.uri, ed.language_id, string(ctext))
	g_free(rawptr(ctext))
	ed.doc_open = true
	// Nudge check-on-save servers (OLS runs `odin check` on didSave) to emit
	// initial diagnostics for the file.
	lsp.client_did_save(ed.client, ed.uri)
	return false
}

// Reader thread: the server exited or broke the stream without our shutdown.
server_exit_from_reader_thread :: proc(user: rawptr) {
	g_idle_add_full(G_PRIORITY_DEFAULT, on_server_exit_main, user, nil)
}

// Main thread: reap the dead server, clear its diagnostics and carry on
// without LSP. There is no automatic restart (SPEC §5).
on_server_exit_main :: proc "c" (user: gpointer) -> gboolean {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	ed := (^Editor_State)(user)
	if ed.closed || ed.client == nil do return false
	lsp.client_shutdown(ed.client)
	ed.client = nil
	ed.doc_open = false
	diagnostics_clear(ed)
	fmt.eprintln("yggr: language server exited; LSP disabled")
	return false
}

on_buffer_changed :: proc "c" (buffer: gpointer, user: gpointer) {
	context = runtime.default_context()
	ed := (^Editor_State)(user)
	if ed.client == nil || !ed.doc_open do return
	if ed.debounce_source != 0 do g_source_remove(ed.debounce_source)
	ed.debounce_source = g_timeout_add(DEBOUNCE_MS, on_debounce_fire, ed)
}

on_debounce_fire :: proc "c" (user: gpointer) -> gboolean {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	ed := (^Editor_State)(user)
	ed.debounce_source = 0
	send_change(ed)
	return false // G_SOURCE_REMOVE — one-shot
}

// Send an edit still waiting out the debounce now, so a request that follows
// (hover, completion, formatting, didSave) is answered against the text the
// user sees.
editor_flush_change :: proc(ed: ^Editor_State) {
	if ed.debounce_source == 0 do return
	g_source_remove(ed.debounce_source)
	ed.debounce_source = 0
	send_change(ed)
}

@(private = "file")
send_change :: proc(ed: ^Editor_State) {
	if ed.client == nil || !ed.doc_open do return
	ctext := buffer_all_text(ed.buffer) // g_malloc'd cstring
	lsp.client_did_change_full(ed.client, ed.uri, string(ctext))
	g_free(rawptr(ctext))
}

on_window_destroy :: proc "c" (window: gpointer, user: gpointer) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	ed := (^Editor_State)(user)
	ed.closed = true
	ed.window = nil
	if ed.debounce_source != 0 {
		g_source_remove(ed.debounce_source)
		ed.debounce_source = 0
	}
	if ed.client != nil {
		if ed.doc_open do lsp.client_did_close(ed.client, ed.uri)
		lsp.client_shutdown(ed.client) // shutdown → exit → SIGTERM/SIGKILL
		ed.client = nil
		ed.doc_open = false
	}
}

on_quit_signal :: proc "c" (user: gpointer) -> gboolean {
	context = runtime.default_context()
	ed := (^Editor_State)(user)
	if ed.window != nil {
		// on_window_destroy shuts the client down; the app quits with its
		// last window.
		gtk_window_destroy(ed.window)
	} else {
		g_application_quit(ed.app)
	}
	return true // keep handling: a repeated signal must not fall back to the default kill
}

// ---- helpers --------------------------------------------------------

// Odin string → temp cstring for a C call within the current turn.
@(private = "file")
cstr :: proc(s: string) -> cstring {
	return strings.clone_to_cstring(s, context.temp_allocator)
}

// Ctrl+S: write the buffer to disk, then tell the server it was saved so a
// check-on-save server (OLS) re-runs and refreshes diagnostics. Soft-fails.
save_document :: proc(ed: ^Editor_State) {
	if ed.file_path == "" {
		fmt.eprintln("yggr: an untitled buffer cannot be saved (there is no Save As)")
		return
	}
	ctext := buffer_all_text(ed.buffer) // g_malloc'd cstring
	defer g_free(rawptr(ctext))
	if err := os2.write_entire_file(ed.file_path, string(ctext)); err != nil {
		fmt.eprintfln("yggr: cannot save %s: %v", ed.file_path, err)
		return
	}
	if ed.client != nil && ed.doc_open {
		editor_flush_change(ed) // the server's text must be what is on disk
		lsp.client_did_save(ed.client, ed.uri)
	}
}

// Full buffer text as a freshly g_malloc'd cstring (caller g_free's it).
buffer_all_text :: proc(buffer: gpointer) -> cstring {
	start, end: Gtk_Text_Iter
	gtk_text_buffer_get_bounds(buffer, &start, &end)
	return gtk_text_buffer_get_text(buffer, &start, &end, false)
}

// Whether LSP `character` values are utf-8 bytes (negotiated) rather than
// utf-16 units. Only meaningful once the client is ready.
@(private = "file")
utf8_positions :: proc(ed: ^Editor_State) -> bool {
	return ed.client == nil || ed.client.utf8_pos
}

// `line`'s text without its terminator, as a g_malloc'd cstring the caller
// g_free's; `start` is set to the line's first iter. `line` must exist.
@(private = "file")
line_text :: proc(buffer: gpointer, line: i32, start: ^Gtk_Text_Iter) -> cstring {
	gtk_text_buffer_get_iter_at_line(buffer, start, line)
	end := start^
	// forward_to_line_end from an empty line's start would skip to the next line.
	if !gtk_text_iter_ends_line(&end) do gtk_text_iter_forward_to_line_end(&end)
	return gtk_text_buffer_get_text(buffer, start, &end, false)
}

// LSP position → buffer iter (ARCH §5). The line is clamped to the buffer and
// the character goes through lsp.character_to_byte (utf-16 conversion,
// clamping to the line, character boundary), so no server position can make
// GTK abort.
position_to_iter :: proc(ed: ^Editor_State, line, character: int, iter: ^Gtk_Text_Iter) {
	ln := i32(clamp(line, 0, int(gtk_text_buffer_get_line_count(ed.buffer)) - 1))
	ctext := line_text(ed.buffer, ln, iter)
	off := lsp.character_to_byte(string(ctext), character, utf8_positions(ed))
	g_free(rawptr(ctext))
	gtk_text_iter_set_line_index(iter, i32(off))
}

// Buffer iter → LSP position (utf-8 byte if negotiated, else utf-16 unit).
iter_to_position :: proc(ed: ^Editor_State, iter: ^Gtk_Text_Iter) -> lsp.Position {
	line := gtk_text_iter_get_line(iter)
	byte := int(gtk_text_iter_get_line_index(iter))
	if utf8_positions(ed) do return {line = int(line), character = byte}
	ls: Gtk_Text_Iter
	ctext := line_text(ed.buffer, line, &ls)
	ch := lsp.byte_to_utf16(string(ctext), byte)
	g_free(rawptr(ctext))
	return {line = int(line), character = ch}
}

// Project root = nearest ancestor containing `.git`, else the file's dir.
compute_project_root :: proc(path: string) -> string {
	abs, err := paths.abs(path, context.temp_allocator) // lexical (no realpath/open)
	if err != nil do abs = path
	dir := filepath.dir(abs)
	cur := dir
	for {
		git, _ := filepath.join({cur, ".git"}, context.temp_allocator)
		if os2.exists(git) do return strings.clone(cur)
		parent := filepath.dir(cur)
		if parent == cur || parent == "" do break
		cur = parent
	}
	return strings.clone(dir)
}

make_file_uri :: proc(path: string) -> string {
	abs, err := paths.abs(path, context.temp_allocator) // lexical (no realpath/open)
	if err != nil do abs = path
	u := ols.create_uri(abs, context.temp_allocator)
	return strings.clone(u.uri)
}

// Whether two file URIs name the same document, however each is
// percent-encoded.
same_document :: proc(a, b: string) -> bool {
	if a == b do return true
	ua, oka := ols.parse_uri(a, context.temp_allocator)
	ub, okb := ols.parse_uri(b, context.temp_allocator)
	return oka && okb && ua.path == ub.path
}

// Resolve the server command; ok=false when there is nothing to run (soft
// failure per SPEC §5). The argv is temp memory: it is only used to spawn.
// Three-step resolution (FLATPAK.md §3):
//   1. YGGR_LSP_CMD env  — explicit override (testing).
//   2. lsp-servers.conf registry — $XDG_CONFIG_HOME/yggr then /app/share/yggr
//      (the flatpak has no Foundry; the bundled registry maps odin->ols etc.).
//   3. `foundry lsp run <lang>` (spawning fails softly if foundry is absent).
resolve_server_argv :: proc(language_id: string) -> ([]string, bool) {
	if cmd := os2.get_env("YGGR_LSP_CMD", context.temp_allocator); cmd != "" {
		parts := strings.fields(cmd, context.temp_allocator)
		return parts, len(parts) > 0
	}
	if language_id == "" do return nil, false

	for path in registry_conf_paths() {
		if data, err := os2.read_entire_file(path, context.temp_allocator); err == nil {
			if cmd, ok := lsp.registry_lookup(string(data), language_id, context.temp_allocator); ok {
				return cmd, true
			}
		}
	}

	foundry := os2.get_env("YGGR_FOUNDRY_BIN", context.temp_allocator)
	if foundry == "" do foundry = "foundry"
	argv := make([]string, 4, context.temp_allocator)
	argv[0] = foundry
	argv[1] = "lsp"
	argv[2] = "run"
	argv[3] = language_id
	return argv, true
}

// Registry search order: user config first, then the bundled flatpak copy.
registry_conf_paths :: proc() -> []string {
	out := make([dynamic]string, context.temp_allocator)
	if xdg := os2.get_env("XDG_CONFIG_HOME", context.temp_allocator); xdg != "" {
		if p, e := filepath.join({xdg, "yggr", "lsp-servers.conf"}, context.temp_allocator); e == nil do append(&out, p)
	} else if home := os2.get_env("HOME", context.temp_allocator); home != "" {
		if p, e := filepath.join({home, ".config", "yggr", "lsp-servers.conf"}, context.temp_allocator); e == nil do append(&out, p)
	}
	append(&out, "/app/share/yggr/lsp-servers.conf")
	return out[:]
}

// Extension → gtksourceview language id, for when guess_language returns NULL
// (FLATPAK.md §3). Minimal map for the bundled languages.
ext_language_id :: proc(path: string) -> string {
	if strings.has_suffix(path, ".odin") do return "odin"
	if strings.has_suffix(path, ".md") do return "markdown"
	return ""
}
