package ui

// diagnostics.odin — publishDiagnostics rendering (Phase 4, ARCH §4).
// The reader thread only clones raw JSON and hops to the main thread via
// g_idle_add_full; ALL GtkSourceView mutation happens in apply_diagnostics_main
// on the main thread. No GTK call is reachable from the reader thread here.

import "base:runtime"
import "core:encoding/json"
import "core:strings"
import lsp "../lsp"

// SPEC §4.2 colors/underline styles.
diagnostics_setup :: proc(ed: ^Editor_State) {
	buffer := ed.buffer
	// error: red squiggle (#e01b24 = Adwaita standard error red, matching
	// libspelling's misspelling underline; SPEC §4.2 just says "red");
	// warning: same squiggle, amber #b58900 (SPEC §4.2); info/hint: single
	// underline, dim (Pango has no dotted underline).
	ed.tag_error   = kat_make_squiggle_tag(buffer, "lsp-error",   PANGO_UNDERLINE_ERROR,  "#e01b24")
	ed.tag_warning = kat_make_squiggle_tag(buffer, "lsp-warning", PANGO_UNDERLINE_ERROR,  "#b58900")
	ed.tag_info    = kat_make_squiggle_tag(buffer, "lsp-info",    PANGO_UNDERLINE_SINGLE, "#93a1a1")

	// Gutter mark categories + symbolic icons (16px provided by the theme).
	kat_setup_mark_attrs(ed.view, "lsp-error",   "dialog-error-symbolic",       3)
	kat_setup_mark_attrs(ed.view, "lsp-warning", "dialog-warning-symbolic",     2)
	kat_setup_mark_attrs(ed.view, "lsp-info",    "dialog-information-symbolic", 1)
}

// Reader-thread entry (lsp.Notification_Handler.on_diagnostics). Package the
// heap-cloned JSON into a heap payload and marshal to the main thread.
diagnostics_from_reader_thread :: proc(params_json: []u8, user: rawptr) {
	ed := (^Editor_State)(user)
	p := new(Diag_Payload, runtime.heap_allocator())
	p.ed = ed
	p.json = params_json // takes ownership of the reader's heap clone
	g_idle_add_full(G_PRIORITY_DEFAULT, apply_diagnostics_main, p, free_diag_payload)
}

// Reader-thread entry for server death (SPEC §5): clear diagnostics for our
// URI on the main thread. (MVP does not auto-restart.)
server_exit_from_reader_thread :: proc(user: rawptr) {
	ed := (^Editor_State)(user)
	p := new(Diag_Payload, runtime.heap_allocator())
	p.ed = ed
	p.json = nil // nil json => clear-only
	g_idle_add_full(G_PRIORITY_DEFAULT, apply_diagnostics_main, p, free_diag_payload)
}

@(private = "file")
Diag_Payload :: struct {
	ed:   ^Editor_State,
	json: []u8,
}

free_diag_payload :: proc "c" (data: gpointer) {
	context = runtime.default_context()
	p := (^Diag_Payload)(data)
	if p.json != nil do delete(p.json, runtime.heap_allocator())
	free(p, runtime.heap_allocator())
}

// Main-thread apply. Returns G_SOURCE_REMOVE; GLib then calls free_diag_payload.
apply_diagnostics_main :: proc "c" (data: gpointer) -> gboolean {
	context = runtime.default_context()
	p := (^Diag_Payload)(data)
	ed := p.ed
	buffer := ed.buffer

	// Always start by clearing existing diagnostics decorations.
	diagnostics_clear(ed)
	if p.json == nil do return false // clear-only (server exit)

	v, perr := json.parse(p.json, .JSON, false, context.temp_allocator)
	if perr != nil do return false
	obj, ok := v.(json.Object)
	if !ok do return false
	// p.json is the whole JSON-RPC message; the fields live under "params".
	params, pok := obj["params"].(json.Object)
	if !pok do return false

	// Version check (SPEC §4.4/§4.2): drop stale publishes whose version is
	// present and != our current buffer version.
	if ver_val, has_ver := params["version"]; has_ver {
		ver := json_int(ver_val)
		if ed.client != nil {
			cur := lsp.client_doc_version(ed.client, ed.uri)
			if cur >= 0 && int(ver) != cur do return false
		}
	}

	diags, has := params["diagnostics"].(json.Array)
	if !has do return false

	for d in diags {
		dobj, dok := d.(json.Object)
		if !dok do continue
		rng, rok := dobj["range"].(json.Object)
		if !rok do continue
		sl, sc := range_point(rng, "start")
		el, ec := range_point(rng, "end")
		sev := 1
		if sv, hs := dobj["severity"]; hs do sev = int(json_int(sv))

		tag, category := severity_tag(ed, sev)

		// range → iters (utf-8 byte offsets; convert if server chose utf-16).
		si, ei: Gtk_Text_Iter
		gtk_text_buffer_get_iter_at_line(buffer, &si, i32(sl))
		gtk_text_iter_set_line_index(&si, char_to_byte(ed, buffer, sl, sc))
		gtk_text_buffer_get_iter_at_line(buffer, &ei, i32(el))
		gtk_text_iter_set_line_index(&ei, char_to_byte(ed, buffer, el, ec))

		gtk_text_buffer_apply_tag(buffer, tag, &si, &ei)

		// Gutter mark at the diagnostic's start line.
		ls: Gtk_Text_Iter
		gtk_text_buffer_get_iter_at_line(buffer, &ls, i32(sl))
		gtk_source_buffer_create_source_mark(buffer, nil, cstr_diag(category), &ls)
	}

	return false
}

@(private = "file")
diagnostics_clear :: proc(ed: ^Editor_State) {
	buffer := ed.buffer
	start, end: Gtk_Text_Iter
	gtk_text_buffer_get_bounds(buffer, &start, &end)
	gtk_text_buffer_remove_tag(buffer, ed.tag_error, &start, &end)
	gtk_text_buffer_remove_tag(buffer, ed.tag_warning, &start, &end)
	gtk_text_buffer_remove_tag(buffer, ed.tag_info, &start, &end)
	gtk_source_buffer_remove_source_marks(buffer, &start, &end, cstr_diag("lsp-error"))
	gtk_source_buffer_remove_source_marks(buffer, &start, &end, cstr_diag("lsp-warning"))
	gtk_source_buffer_remove_source_marks(buffer, &start, &end, cstr_diag("lsp-info"))
}

@(private = "file")
severity_tag :: proc(ed: ^Editor_State, severity: int) -> (tag: gpointer, category: string) {
	switch severity {
	case 1: return ed.tag_error, "lsp-error"
	case 2: return ed.tag_warning, "lsp-warning"
	case:   return ed.tag_info, "lsp-info"
	}
}

// LSP character offset (byte if utf-8 negotiated, else utf-16 unit) → clamped
// GtkTextIter line byte-index (ARCH §5).
@(private = "file")
char_to_byte :: proc(ed: ^Editor_State, buffer: gpointer, line, character: int) -> i32 {
	ls: Gtk_Text_Iter
	gtk_text_buffer_get_iter_at_line(buffer, &ls, i32(line))
	max_bytes := int(gtk_text_iter_get_bytes_in_line(&ls))

	byte_off := character
	if ed.client != nil && !ed.client.utf8_pos {
		// utf-16 fallback: read the line text and convert.
		le := ls
		gtk_text_iter_forward_to_line_end(&le)
		ctext := gtk_text_buffer_get_text(buffer, &ls, &le, false)
		byte_off = lsp.utf16_to_byte(string(ctext), character)
		g_free(rawptr(ctext))
	}
	if byte_off > max_bytes do byte_off = max_bytes
	if byte_off < 0 do byte_off = 0
	return i32(byte_off)
}

@(private = "file")
range_point :: proc(rng: json.Object, which: string) -> (line, character: int) {
	pt, ok := rng[which].(json.Object)
	if !ok do return 0, 0
	return int(json_int(pt["line"])), int(json_int(pt["character"]))
}

@(private = "file")
json_int :: proc(v: json.Value) -> i64 {
	#partial switch n in v {
	case json.Integer: return i64(n)
	case json.Float:   return i64(n)
	}
	return 0
}

@(private = "file")
cstr_diag :: proc(s: string) -> cstring {
	return strings.clone_to_cstring(s, context.temp_allocator)
}
