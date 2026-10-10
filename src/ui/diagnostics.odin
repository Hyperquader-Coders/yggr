package ui

// diagnostics.odin — publishDiagnostics rendering (ARCH §4).
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
	p := new(Diag_Payload, runtime.heap_allocator())
	p.ed = (^Editor_State)(user)
	p.json = params_json // takes ownership of the reader's heap clone
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
	delete(p.json, runtime.heap_allocator())
	free(p, runtime.heap_allocator())
}

// Main-thread apply. Returns G_SOURCE_REMOVE; GLib then calls free_diag_payload.
apply_diagnostics_main :: proc "c" (data: gpointer) -> gboolean {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	p := (^Diag_Payload)(data)
	ed := p.ed
	if ed.closed || ed.client == nil do return false

	v, perr := json.parse(p.json, .JSON, false, context.temp_allocator)
	if perr != nil do return false
	obj, ok := v.(json.Object)
	if !ok do return false
	// p.json is the whole JSON-RPC message; the fields live under "params".
	params, pok := obj["params"].(json.Object)
	if !pok do return false

	// Only this buffer's diagnostics: a server publishes for every file it
	// checks (OLS: the whole package), and another file's publish — empty or
	// not — must not repaint ours.
	uri, _ := params["uri"].(string)
	if !same_document(uri, ed.uri) do return false

	// Version check (SPEC §4.2): drop stale publishes whose version is
	// present and != our current buffer version.
	if ver_val, has_ver := params["version"]; has_ver {
		if _, is_null := ver_val.(json.Null); !is_null {
			cur := lsp.client_doc_version(ed.client, ed.uri)
			if cur >= 0 && int(json_int(ver_val)) != cur do return false
		}
	}

	diags, has := params["diagnostics"].(json.Array)
	if !has do return false

	// A publish replaces every earlier diagnostic for the document.
	diagnostics_clear(ed)
	buffer := ed.buffer
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

		si, ei: Gtk_Text_Iter
		position_to_iter(ed, sl, sc, &si)
		position_to_iter(ed, el, ec, &ei)
		gtk_text_buffer_apply_tag(buffer, tag, &si, &ei)

		// Gutter mark at the diagnostic's start line.
		ls := si
		gtk_text_iter_set_line_offset(&ls, 0)
		gtk_source_buffer_create_source_mark(buffer, nil, cstr_diag(category), &ls)
	}

	return false
}

diagnostics_clear :: proc(ed: ^Editor_State) {
	buffer := ed.buffer
	start, end: Gtk_Text_Iter
	gtk_text_buffer_get_bounds(buffer, &start, &end)
	gtk_text_buffer_remove_tag(buffer, ed.tag_error, &start, &end)
	gtk_text_buffer_remove_tag(buffer, ed.tag_warning, &start, &end)
	gtk_text_buffer_remove_tag(buffer, ed.tag_info, &start, &end)
	gtk_source_buffer_remove_source_marks(buffer, &start, &end, "lsp-error")
	gtk_source_buffer_remove_source_marks(buffer, &start, &end, "lsp-warning")
	gtk_source_buffer_remove_source_marks(buffer, &start, &end, "lsp-info")
}

@(private = "file")
severity_tag :: proc(ed: ^Editor_State, severity: int) -> (tag: gpointer, category: string) {
	switch severity {
	case 1: return ed.tag_error, "lsp-error"
	case 2: return ed.tag_warning, "lsp-warning"
	case:   return ed.tag_info, "lsp-info"
	}
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
