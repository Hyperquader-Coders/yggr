package ui

// editor.odin — GTK main-thread application shell (Phases 3 & 7).
// Window + GtkSourceView + file load, language detection, LSP client
// lifecycle, debounced didChange (SPEC/ARCH §7), Ctrl+Shift+F formatting,
// and clean shutdown. All GTK calls here run on the main thread.

import "base:runtime"
import os2 "core:os"
import "core:fmt"
import "core:strings"
import "core:path/filepath"
import afs "amber:afs"
import lsp "../lsp"
import ols "../lsp/vendor_ols"

Editor_State :: struct {
	app:             gpointer,
	window:          gpointer,
	view:            gpointer, // GtkSourceView*
	buffer:          gpointer, // GtkSourceBuffer* (also a GtkTextBuffer*)
	file_path:       string,
	uri:             string,
	root:            string,
	language_id:     string,
	open_text:       string, // full text snapshot handed to didOpen
	client:          ^lsp.Client,
	debounce_source: u32, // g_timeout source id, 0 = none

	// Phase 4 severity tag handles (GtkTextTag*).
	tag_error, tag_warning, tag_info: gpointer,

	// Phase 5/6 provider (KatProvider*) + its vtable (kept alive).
	provider: gpointer,
	vtable:   Kat_Lsp_Vtable,
}

DEBOUNCE_MS :: 150

// Entry point from main.odin.
run :: proc(path: string) {
	i18n_init() // localization (en source + de catalog) before any UI string
	ed := new(Editor_State)
	// No file → empty "Untitled" buffer (bare launch / double-click). With a
	// file, afs.expand expands a leading ~ / env vars then makes it lexically
	// absolute (Go's filepath.Abs) — unlike core filepath.abs it does NOT
	// open()/realpath the file, so a URI/root can be built without touching
	// the fs or resolving symlinks. (amber:afs landmine.)
	if path == "" {
		ed.file_path = ""
	} else if expanded, eerr := afs.expand(path, context.allocator); eerr == nil {
		ed.file_path = expanded
	} else {
		ed.file_path = path
	}

	app := gtk_application_new("io.github.hyperquader.Yggr", G_APPLICATION_DEFAULT_FLAGS)
	ed.app = app
	g_signal_connect_data(app, "activate", rawptr(on_activate), ed, nil, G_CONNECT_DEFAULT)

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
	ed := (^Editor_State)(user)

	// Load file text (soft-fail to empty on error — editor still opens). An
	// empty file_path means an untitled buffer (no file to read, no LSP).
	text := ""
	if ed.file_path != "" {
		if data, rerr := os2.read_entire_file(ed.file_path, context.allocator); rerr == nil {
			text = string(data)
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

	// Phase 4 + 5/6 wiring (created before the client so diagnostics that
	// arrive immediately after didOpen have somewhere to land).
	diagnostics_setup(ed)
	providers_setup(ed)

	// Ctrl+Shift+F → format (Phase 7).
	kc := gtk_event_controller_key_new()
	g_signal_connect_data(kc, "key-pressed", rawptr(on_key_pressed), ed, nil, G_CONNECT_DEFAULT)
	gtk_widget_add_controller(view, kc)

	// Spawn + initialize the LSP client, then debounce edits.
	editor_start_client(ed, text)
	g_signal_connect_data(buffer, "changed", rawptr(on_buffer_changed), ed, nil, G_CONNECT_DEFAULT)
	g_signal_connect_data(win, "destroy", rawptr(on_window_destroy), ed, nil, G_CONNECT_DEFAULT)

	gtk_window_present(win)
	gtk_widget_grab_focus(view)
}

// ---- LSP client lifecycle -------------------------------------------

editor_start_client :: proc(ed: ^Editor_State, text: string) {
	// Untitled buffer (no file): no language / project root / server.
	if ed.file_path == "" do return
	ed.root = compute_project_root(ed.file_path)
	argv, ok := resolve_server_argv(ed.language_id)
	if !ok {
		fmt.eprintln("yggr: no language server available (foundry missing, no YGGR_LSP_CMD) — LSP features disabled")
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
	ed.open_text = strings.clone(text)
	if tr := os2.get_env("YGGR_LSP_TRACE", context.temp_allocator); tr == "1" {
		c.trace = true
	}

	root_uri := make_file_uri(ed.root)
	// on_initialize_done runs on the reader thread but only sends didOpen (no
	// GTK), so it is safe to call there directly (ARCH §2).
	lsp.client_initialize(c, root_uri, on_initialize_done, ed)
}

on_initialize_done :: proc(user: rawptr) {
	ed := (^Editor_State)(user)
	if ed.client == nil do return
	lsp.client_did_open(ed.client, ed.uri, ed.language_id, ed.open_text)
	// The just-opened buffer matches the on-disk file, so nudge check-on-save
	// servers (OLS runs `odin check` on didSave) to emit initial diagnostics.
	lsp.client_did_save(ed.client, ed.uri)
}

on_buffer_changed :: proc "c" (buffer: gpointer, user: gpointer) {
	context = runtime.default_context()
	ed := (^Editor_State)(user)
	if ed.client == nil do return
	if ed.debounce_source != 0 do g_source_remove(ed.debounce_source)
	ed.debounce_source = g_timeout_add(DEBOUNCE_MS, on_debounce_fire, ed)
}

on_debounce_fire :: proc "c" (user: gpointer) -> gboolean {
	context = runtime.default_context()
	ed := (^Editor_State)(user)
	ed.debounce_source = 0
	if ed.client != nil {
		ctext := buffer_all_text(ed.buffer) // g_malloc'd cstring
		lsp.client_did_change_full(ed.client, ed.uri, string(ctext))
		g_free(rawptr(ctext))
	}
	return false // G_SOURCE_REMOVE — one-shot
}

on_window_destroy :: proc "c" (window: gpointer, user: gpointer) {
	context = runtime.default_context()
	ed := (^Editor_State)(user)
	if ed.debounce_source != 0 {
		g_source_remove(ed.debounce_source)
		ed.debounce_source = 0
	}
	if ed.client != nil {
		lsp.client_did_close(ed.client, ed.uri)
		lsp.client_shutdown(ed.client) // shutdown → exit → SIGTERM/SIGKILL
		ed.client = nil
	}
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
		fmt.eprintln("yggr: cannot save an untitled buffer (Save As is post-MVP)")
		return
	}
	ctext := buffer_all_text(ed.buffer) // g_malloc'd cstring
	defer g_free(rawptr(ctext))
	if err := os2.write_entire_file(ed.file_path, string(ctext)); err != nil {
		fmt.eprintfln("yggr: save failed for %s: %v", ed.file_path, err)
		return
	}
	if ed.client != nil do lsp.client_did_save(ed.client, ed.uri)
}

// Full buffer text as a freshly g_malloc'd cstring (caller g_free's it).
buffer_all_text :: proc(buffer: gpointer) -> cstring {
	start, end: Gtk_Text_Iter
	gtk_text_buffer_get_bounds(buffer, &start, &end)
	return gtk_text_buffer_get_text(buffer, &start, &end, false)
}

// Project root = nearest ancestor containing `.git`, else the file's dir.
compute_project_root :: proc(path: string) -> string {
	abs, err := afs.abs(path, context.allocator) // lexical (no realpath/open)
	if err != nil do abs = path
	dir := filepath.dir(abs)
	cur := dir
	for {
		git, _ := filepath.join({cur, ".git"}, context.temp_allocator)
		if os2.exists(git) do return cur
		parent := filepath.dir(cur)
		if parent == cur || parent == "" do break
		cur = parent
	}
	return dir
}

make_file_uri :: proc(path: string) -> string {
	abs, err := afs.abs(path, context.temp_allocator) // lexical (no realpath/open)
	if err != nil do abs = path
	u := ols.create_uri(abs, context.allocator)
	return u.uri
}

// Resolve the server command: YGGR_LSP_CMD override, else foundry. Returns
// ok=false when neither is usable (soft failure per SPEC §5).
// Three-step resolution (FLATPAK.md §3):
//   1. YGGR_LSP_CMD env  — explicit override (testing).
//   2. lsp-servers.conf registry — $XDG_CONFIG_HOME/yggr then /app/share/yggr
//      (the flatpak has no Foundry; the bundled registry maps odin->ols etc.).
//   3. `foundry lsp run <lang>` if foundry is reachable (transport soft-fails
//      if absent — SPEC §5).
resolve_server_argv :: proc(language_id: string) -> ([]string, bool) {
	if cmd := os2.get_env("YGGR_LSP_CMD", context.allocator); cmd != "" {
		parts := strings.split(cmd, " ", context.allocator)
		return parts, len(parts) > 0
	}
	if language_id == "" do return nil, false

	for path in registry_conf_paths() {
		if data, err := os2.read_entire_file(path, context.temp_allocator); err == nil {
			if cmd, ok := lsp.registry_lookup(string(data), language_id, context.allocator); ok {
				return cmd, true
			}
		}
	}

	foundry := os2.get_env("YGGR_FOUNDRY_BIN", context.allocator)
	if foundry == "" do foundry = "foundry"
	argv := make([]string, 4)
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
