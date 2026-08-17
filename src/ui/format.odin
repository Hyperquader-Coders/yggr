package ui

// format.odin — document formatting (Phase 7, SPEC §4.5 / ARCH §4).
// Ctrl+Shift+F → textDocument/formatting; the returned TextEdits are applied
// bottom-up (descending by start line/char) inside one begin/end_user_action
// pair so the whole reformat is a single undo step.

import "base:runtime"
import "core:encoding/json"
import "core:strings"
import lsp "../lsp"

// GDK modifier masks (gdk/gdkenums.h) and key symbols (gdk/gdkkeysyms.h).
GDK_SHIFT_MASK   :: 1 << 0
GDK_CONTROL_MASK :: 1 << 2
GDK_KEY_F        :: 0x0046
GDK_KEY_f        :: 0x0066
GDK_KEY_S        :: 0x0053
GDK_KEY_s        :: 0x0073

on_key_pressed :: proc "c" (ctrl: gpointer, keyval: u32, keycode: u32, state: u32, user: gpointer) -> gboolean {
	context = runtime.default_context()
	ed := (^Editor_State)(user)
	has_ctrl := (state & GDK_CONTROL_MASK) != 0
	has_shift := (state & GDK_SHIFT_MASK) != 0
	// Ctrl+Shift+F → format.
	if has_ctrl && has_shift && (keyval == GDK_KEY_F || keyval == GDK_KEY_f) {
		format_request(ed)
		return true
	}
	// Ctrl+S → save to disk (and notify the server via didSave).
	if has_ctrl && !has_shift && (keyval == GDK_KEY_S || keyval == GDK_KEY_s) {
		save_document(ed)
		return true
	}
	return false
}

@(private = "file")
Fmt_Params :: struct {
	text_document: lsp.Text_Document_Identifier `json:"textDocument"`,
	options:       lsp.Formatting_Options       `json:"options"`,
}

format_request :: proc(ed: ^Editor_State) {
	if ed.client == nil do return
	tab := int(gtk_source_view_get_tab_width(ed.view))
	if tab <= 0 do tab = 4
	spaces := bool(gtk_source_view_get_insert_spaces_instead_of_tabs(ed.view))
	params := Fmt_Params{{ed.uri}, {tab_size = tab, insert_spaces = spaces}}
	fc := new(Fmt_Ctx, runtime.heap_allocator())
	fc.ed = ed
	lsp.client_request(ed.client, "textDocument/formatting", params, on_format_response_reader, fc)
}

@(private = "file")
Fmt_Ctx :: struct {
	ed: ^Editor_State,
}

@(private = "file")
Edit_Data :: struct {
	sl, sc, el, ec: int,
	new_text:       string, // heap
}

@(private = "file")
Fmt_Payload :: struct {
	ed:    ^Editor_State,
	edits: []Edit_Data, // heap
}

// Reader thread: flatten TextEdit[] into plain heap data (no GTK).
on_format_response_reader :: proc(result: json.Value, is_error: bool, user: rawptr) {
	fc := (^Fmt_Ctx)(user)
	defer free(fc, runtime.heap_allocator())

	edits: []Edit_Data
	if !is_error {
		if arr, ok := result.(json.Array); ok && len(arr) > 0 {
			tmp := make([]Edit_Data, len(arr), runtime.heap_allocator())
			n := 0
			for e in arr {
				obj, ook := e.(json.Object)
				if !ook do continue
				rng, rok := obj["range"].(json.Object)
				if !rok do continue
				sl, sc := fpoint(rng, "start")
				el, ec := fpoint(rng, "end")
				tmp[n] = Edit_Data{
					sl = sl, sc = sc, el = el, ec = ec,
					new_text = strings.clone(fjstr(obj, "newText"), runtime.heap_allocator()),
				}
				n += 1
			}
			edits = tmp[:n]
		}
	}
	p := new(Fmt_Payload, runtime.heap_allocator())
	p.ed = fc.ed; p.edits = edits
	g_idle_add_full(G_PRIORITY_DEFAULT, on_format_main, p, free_fmt_payload)
}

on_format_main :: proc "c" (data: gpointer) -> gboolean {
	context = runtime.default_context()
	p := (^Fmt_Payload)(data)
	ed := p.ed
	buffer := ed.buffer
	if len(p.edits) == 0 do return false

	// Sort descending by (start line, start char) via the shared lsp helper so
	// applying bottom-up never invalidates a not-yet-applied edit's offsets.
	te := make([]lsp.Text_Edit, len(p.edits), context.temp_allocator)
	for e, i in p.edits {
		te[i] = lsp.Text_Edit{
			range = {{e.sl, e.sc}, {e.el, e.ec}},
			new_text = e.new_text,
		}
	}
	lsp.sort_edits_desc(te)

	// Capture the cursor in a right-gravity-free mark so it tracks edits.
	cursor := gtk_text_buffer_get_insert(buffer)
	cpos: Gtk_Text_Iter
	gtk_text_buffer_get_iter_at_mark(buffer, &cpos, cursor)
	restore := gtk_text_buffer_create_mark(buffer, nil, &cpos, true)

	gtk_text_buffer_begin_user_action(buffer)
	for e in te {
		si, ei: Gtk_Text_Iter
		gtk_text_buffer_get_iter_at_line(buffer, &si, i32(e.range.start.line))
		gtk_text_iter_set_line_index(&si, clamp_col(buffer, e.range.start.line, e.range.start.character))
		gtk_text_buffer_get_iter_at_line(buffer, &ei, i32(e.range.end.line))
		gtk_text_iter_set_line_index(&ei, clamp_col(buffer, e.range.end.line, e.range.end.character))
		gtk_text_buffer_delete(buffer, &si, &ei)
		gtk_text_buffer_insert(buffer, &si, temp_cstr_f(e.new_text), -1)
	}
	gtk_text_buffer_end_user_action(buffer)

	// Restore cursor to the (adjusted) mark, then drop the temp mark.
	rpos: Gtk_Text_Iter
	gtk_text_buffer_get_iter_at_mark(buffer, &rpos, restore)
	gtk_text_buffer_place_cursor(buffer, &rpos)
	gtk_text_buffer_delete_mark(buffer, restore)
	return false
}

free_fmt_payload :: proc "c" (data: gpointer) {
	context = runtime.default_context()
	p := (^Fmt_Payload)(data)
	for e in p.edits do delete(e.new_text, runtime.heap_allocator())
	if p.edits != nil do delete(p.edits, runtime.heap_allocator())
	free(p, runtime.heap_allocator())
}

@(private = "file")
clamp_col :: proc(buffer: gpointer, line, character: int) -> i32 {
	ls: Gtk_Text_Iter
	gtk_text_buffer_get_iter_at_line(buffer, &ls, i32(line))
	maxb := int(gtk_text_iter_get_bytes_in_line(&ls))
	c := character
	if c > maxb do c = maxb
	if c < 0 do c = 0
	return i32(c)
}

@(private = "file")
fjstr :: proc(obj: json.Object, key: string) -> string {
	if s, ok := obj[key].(string); ok do return string(s)
	return ""
}

@(private = "file")
fpoint :: proc(rng: json.Object, which: string) -> (line, character: int) {
	pt, ok := rng[which].(json.Object)
	if !ok do return 0, 0
	return int(fj_int(pt["line"])), int(fj_int(pt["character"]))
}

@(private = "file")
fj_int :: proc(v: json.Value) -> i64 {
	#partial switch n in v {
	case json.Integer: return i64(n)
	case json.Float:   return i64(n)
	}
	return 0
}

@(private = "file")
temp_cstr_f :: proc(s: string) -> cstring {
	return strings.clone_to_cstring(s, context.temp_allocator)
}
