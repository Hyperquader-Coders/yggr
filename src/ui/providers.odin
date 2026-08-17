package ui

// providers.odin — Hover (Phase 5) and Completion (Phase 6) providers.
//
// Threading (ARCH §2/§3): GTK calls our *_cb vfuncs on the MAIN thread via the
// C shim. We fire an LSP request whose response callback runs on the READER
// thread — there we only extract+clone plain data (never touch GTK), then
// g_idle_add back to the main thread to build widgets / the proposal store and
// complete the GTask. Nothing here calls GTK off the main thread.

import "base:runtime"
import "core:encoding/json"
import "core:strings"
import lsp "../lsp"

providers_setup :: proc(ed: ^Editor_State) {
	ed.vtable = Kat_Lsp_Vtable{
		hover_populate      = hover_populate_cb,
		completion_populate = completion_populate_cb,
		proposal_display    = proposal_display_cb,
		proposal_activate   = proposal_activate_cb,
		is_trigger          = is_trigger_cb,
		refilter            = refilter_cb,
	}
	prov := kat_provider_new(&ed.vtable, ed)
	ed.provider = prov

	hover := gtk_source_view_get_hover(ed.view)
	gtk_source_hover_add_provider(hover, prov)
	comp := gtk_source_view_get_completion(ed.view)
	gtk_source_completion_add_provider(comp, prov)
}

// GtkTextIter (line, byte) → LSP Position (byte if utf-8 negotiated, else
// utf-16 unit).
iter_to_position :: proc(ed: ^Editor_State, buffer: gpointer, iter: ^Gtk_Text_Iter) -> lsp.Position {
	line := int(gtk_text_iter_get_line(iter))
	byte := int(gtk_text_iter_get_line_index(iter))
	ch := byte
	if ed.client != nil && !ed.client.utf8_pos {
		ls: Gtk_Text_Iter
		gtk_text_buffer_get_iter_at_line(buffer, &ls, i32(line))
		le := ls
		gtk_text_iter_forward_to_line_end(&le)
		ct := gtk_text_buffer_get_text(buffer, &ls, &le, false)
		ch = lsp.byte_to_utf16(string(ct), byte)
		g_free(rawptr(ct))
	}
	return {line = line, character = ch}
}

// Params shared by hover/completion requests.
@(private = "file")
Text_Doc_Position :: struct {
	text_document: lsp.Text_Document_Identifier `json:"textDocument"`,
	position:      lsp.Position                 `json:"position"`,
}

// ======================= Hover (Phase 5) ============================

@(private = "file")
Hover_Ctx :: struct {
	ed:      ^Editor_State,
	task:    gpointer,
	display: gpointer,
}

@(private = "file")
Hover_Result_Payload :: struct {
	task:    gpointer,
	display: gpointer,
	markup:  string, // heap; "" => no result
}

hover_populate_cb :: proc "c" (ctx: gpointer, display: gpointer, task: gpointer, user: gpointer) {
	context = runtime.default_context()
	ed := (^Editor_State)(user)
	if ed.client == nil {
		kat_task_return_declined(task)
		g_object_unref(task)
		return
	}
	iter: Gtk_Text_Iter
	if !gtk_source_hover_context_get_iter(ctx, &iter) {
		kat_task_return_declined(task)
		g_object_unref(task)
		return
	}
	pos := iter_to_position(ed, ed.buffer, &iter)

	hc := new(Hover_Ctx, runtime.heap_allocator())
	hc.ed = ed; hc.task = task; hc.display = display
	params := Text_Doc_Position{{ed.uri}, pos}
	lsp.client_request(ed.client, "textDocument/hover", params, on_hover_response_reader, hc)
}

// Reader thread: extract the markdown/plaintext string, clone it, hop to main.
on_hover_response_reader :: proc(result: json.Value, is_error: bool, user: rawptr) {
	hc := (^Hover_Ctx)(user)
	defer free(hc, runtime.heap_allocator())

	markup := ""
	if !is_error {
		markup = extract_hover_text(result) // heap clone (or "")
	}
	p := new(Hover_Result_Payload, runtime.heap_allocator())
	p.task = hc.task; p.display = hc.display; p.markup = markup
	g_idle_add_full(G_PRIORITY_DEFAULT, on_hover_main, p, free_hover_payload)
}

on_hover_main :: proc "c" (data: gpointer) -> gboolean {
	context = runtime.default_context()
	p := (^Hover_Result_Payload)(data)
	// The hover round-tripped through the LSP reader thread; by the time this
	// idle fires the hover may have been dismissed (a click — e.g. right-click
	// opening the context menu — a keypress, a cursor move) or superseded, in
	// which case GtkSourceView has cancelled the op and torn down the hover
	// display/assistant. Completing the task via the SUCCESS path then drives
	// g_task_return into gtk_source_hover_assistant_populate_cb, which touches
	// the stale display → use-after-free SIGSEGV (the observed crash:
	// on_hover_main → g_task_return_boolean → gtksourceview). Honour the
	// cancellable instead: return CANCELLED, which GtkSourceView's populate
	// path handles by skipping the display access entirely. The task was
	// created with the op's GCancellable in the C shim, so this checks it.
	if g_task_return_error_if_cancelled(p.task) {
		g_object_unref(p.task)
		return false
	}
	if len(p.markup) == 0 {
		// No hover text here (common on e.g. a diagnostic squiggle). Decline
		// with an error rather than g_task_return_boolean(false): a bare FALSE
		// leaves the async error unset and GtkSourceView's populate_cb crashes
		// dereferencing it (error->message).
		kat_task_return_declined(p.task)
		g_object_unref(p.task)
		return false
	}
	pango := md_to_pango(p.markup)
	label := gtk_label_new(nil)
	gtk_label_set_markup(label, temp_cstr(pango))
	gtk_source_hover_display_append(p.display, label)
	g_task_return_boolean(p.task, true)
	g_object_unref(p.task)
	return false
}

free_hover_payload :: proc "c" (data: gpointer) {
	context = runtime.default_context()
	p := (^Hover_Result_Payload)(data)
	if len(p.markup) > 0 do delete(p.markup, runtime.heap_allocator())
	free(p, runtime.heap_allocator())
}

// LSP Hover.contents may be MarkupContent {kind,value}, a MarkedString
// (string | {language,value}), or an array thereof. Normalize to one string.
@(private = "file")
extract_hover_text :: proc(result: json.Value) -> string {
	obj, ok := result.(json.Object)
	if !ok do return ""
	contents, has := obj["contents"]
	if !has do return ""

	#partial switch c in contents {
	case json.String:
		return strings.clone(string(c), runtime.heap_allocator())
	case json.Object:
		if val, vok := c["value"].(string); vok {
			return strings.clone(string(val), runtime.heap_allocator())
		}
	case json.Array:
		b := strings.builder_make(context.temp_allocator)
		for item in c {
			#partial switch it in item {
			case json.String:
				strings.write_string(&b, string(it)); strings.write_byte(&b, '\n')
			case json.Object:
				if val, vok := it["value"].(string); vok {
					strings.write_string(&b, string(val)); strings.write_byte(&b, '\n')
				}
			}
		}
		return strings.clone(strings.to_string(b), runtime.heap_allocator())
	}
	return ""
}

// ===================== Completion (Phase 6) =========================

@(private = "file")
Completion_Ctx :: struct {
	ed:   ^Editor_State,
	task: gpointer,
}

@(private = "file")
Item_Data :: struct {
	label, detail, icon, insert_text: string, // heap
	has_edit:                         bool,
	sl, sc, el, ec:                   int,
}

@(private = "file")
Completion_Payload :: struct {
	task:  gpointer,
	items: []Item_Data, // heap; strings heap
}

MAX_ITEMS :: 200

completion_populate_cb :: proc "c" (ctx: gpointer, task: gpointer, user: gpointer) {
	context = runtime.default_context()
	ed := (^Editor_State)(user)
	if ed.client == nil {
		kat_task_return_declined(task)
		g_object_unref(task)
		return
	}
	begin, end: Gtk_Text_Iter
	if !gtk_source_completion_context_get_bounds(ctx, &begin, &end) {
		kat_task_return_declined(task)
		g_object_unref(task)
		return
	}
	pos := iter_to_position(ed, ed.buffer, &end)

	cc := new(Completion_Ctx, runtime.heap_allocator())
	cc.ed = ed; cc.task = task
	params := Text_Doc_Position{{ed.uri}, pos}
	lsp.client_request(ed.client, "textDocument/completion", params, on_completion_response_reader, cc)
}

// Reader thread: flatten the completion result into plain heap data (no GTK).
on_completion_response_reader :: proc(result: json.Value, is_error: bool, user: rawptr) {
	cc := (^Completion_Ctx)(user)
	defer free(cc, runtime.heap_allocator())

	items: []Item_Data
	if !is_error {
		items = extract_completion_items(result)
	}
	p := new(Completion_Payload, runtime.heap_allocator())
	p.task = cc.task; p.items = items
	g_idle_add_full(G_PRIORITY_DEFAULT, on_completion_main, p, free_completion_payload)
}

on_completion_main :: proc "c" (data: gpointer) -> gboolean {
	context = runtime.default_context()
	p := (^Completion_Payload)(data)
	// Same lifetime hazard as on_hover_main: the completion may have been
	// dismissed or superseded (GtkSourceView cancels the op) while our LSP
	// reply was in flight. Bail via the cancellable rather than returning a
	// model into a torn-down completion context.
	if g_task_return_error_if_cancelled(p.task) {
		g_object_unref(p.task)
		return false
	}
	if len(p.items) == 0 {
		kat_task_return_declined(p.task) // no proposals: decline (see hover)
		g_object_unref(p.task)
		return false
	}
	store := g_list_store_new(kat_proposal_get_type())
	for it in p.items {
		prop := kat_proposal_new(
			temp_cstr(it.label), temp_cstr(it.detail), temp_cstr(it.icon),
			temp_cstr(it.insert_text), gboolean(it.has_edit),
			i32(it.sl), i32(it.sc), i32(it.el), i32(it.ec),
		)
		g_list_store_append(store, prop)
		g_object_unref(prop) // store holds its own ref
	}
	g_task_return_pointer(p.task, store, nil)
	g_object_unref(p.task)
	return false
}

free_completion_payload :: proc "c" (data: gpointer) {
	context = runtime.default_context()
	p := (^Completion_Payload)(data)
	for it in p.items {
		delete(it.label, runtime.heap_allocator())
		delete(it.detail, runtime.heap_allocator())
		delete(it.icon, runtime.heap_allocator())
		delete(it.insert_text, runtime.heap_allocator())
	}
	if p.items != nil do delete(p.items, runtime.heap_allocator())
	free(p, runtime.heap_allocator())
}

@(private = "file")
extract_completion_items :: proc(result: json.Value) -> []Item_Data {
	// result is CompletionItem[] or CompletionList{items:[...]}.
	arr: json.Array
	#partial switch r in result {
	case json.Array:
		arr = r
	case json.Object:
		if items, ok := r["items"].(json.Array); ok do arr = items
	}
	if len(arr) == 0 do return nil

	n := min(len(arr), MAX_ITEMS)
	out := make([]Item_Data, n, runtime.heap_allocator())
	for i in 0 ..< n {
		obj, ok := arr[i].(json.Object)
		if !ok do continue
		label := jstr(obj, "label")
		detail := jstr(obj, "detail")
		kind := int(cj_int(obj["kind"]))
		fmt_flag := int(cj_int(obj["insertTextFormat"]))
		insert := jstr(obj, "insertText")
		if insert == "" do insert = label

		it := Item_Data{
			label = strings.clone(label, runtime.heap_allocator()),
			detail = strings.clone(detail, runtime.heap_allocator()),
			icon = strings.clone(lsp.completion_kind_icon(kind), runtime.heap_allocator()),
		}

		text := insert
		if te, teok := obj["textEdit"].(json.Object); teok {
			it.has_edit = true
			if rng, rok := te["range"].(json.Object); rok {
				it.sl, it.sc = point(rng, "start")
				it.el, it.ec = point(rng, "end")
			}
			text = jstr(te, "newText")
		}
		if fmt_flag == 2 do text = strip_snippet(text)
		it.insert_text = strings.clone(text, runtime.heap_allocator())
		out[i] = it
	}
	return out
}

// ---- display / activate (main thread) -------------------------------

proposal_display_cb :: proc "c" (ctx: gpointer, proposal: gpointer, cell: gpointer, user: gpointer) {
	context = runtime.default_context()
	col := gtk_source_completion_cell_get_column(cell)
	switch col {
	case GTK_SOURCE_COMPLETION_COLUMN_ICON:
		gtk_source_completion_cell_set_icon_name(cell, kat_proposal_icon_name(proposal))
	case GTK_SOURCE_COMPLETION_COLUMN_TYPED_TEXT:
		gtk_source_completion_cell_set_text(cell, kat_proposal_label(proposal))
	case GTK_SOURCE_COMPLETION_COLUMN_AFTER:
		gtk_source_completion_cell_set_text(cell, kat_proposal_detail(proposal))
	}
}

proposal_activate_cb :: proc "c" (ctx: gpointer, proposal: gpointer, user: gpointer) {
	context = runtime.default_context()
	ed := (^Editor_State)(user)
	buffer := ed.buffer
	insert := kat_proposal_insert_text(proposal)

	gtk_text_buffer_begin_user_action(buffer)
	if kat_proposal_has_edit(proposal) {
		// Apply the server textEdit range (utf-8 byte offsets).
		si, ei: Gtk_Text_Iter
		gtk_text_buffer_get_iter_at_line(buffer, &si, kat_proposal_start_line(proposal))
		gtk_text_iter_set_line_index(&si, kat_proposal_start_col(proposal))
		gtk_text_buffer_get_iter_at_line(buffer, &ei, kat_proposal_end_line(proposal))
		gtk_text_iter_set_line_index(&ei, kat_proposal_end_col(proposal))
		gtk_text_buffer_delete(buffer, &si, &ei)
		gtk_text_buffer_insert(buffer, &si, insert, -1)
	} else {
		// Word-replace (SPEC §4.4): delete the word the completion was invoked
		// on, then insert — otherwise the typed prefix is duplicated
		// ("Pri" + Println -> "PriPrintln"). Use the completion context's
		// bounds (as GNOME Builder does); fall back to the bare cursor.
		begin, end: Gtk_Text_Iter
		if gtk_source_completion_context_get_bounds(ctx, &begin, &end) {
			gtk_text_buffer_delete(buffer, &begin, &end)
		} else {
			mark := gtk_text_buffer_get_insert(buffer)
			gtk_text_buffer_get_iter_at_mark(buffer, &begin, mark)
		}
		gtk_text_buffer_insert(buffer, &begin, insert, -1)
	}
	gtk_text_buffer_end_user_action(buffer)
}

// Narrow an already-populated proposal store as the typed word grows — the
// GtkSourceCompletionProvider default refilter is a no-op, so without this the
// popup would keep showing every proposal from the original request (matches
// the bundled `words` provider, which implements refilter). Destructive removal
// is fine: shrinking the word (backspace) fails can_refilter and re-populates.
refilter_cb :: proc "c" (ctx: gpointer, model: gpointer, user: gpointer) {
	context = runtime.default_context()
	wordc := gtk_source_completion_context_get_word(ctx)
	defer g_free(rawptr(wordc))
	word := strings.to_lower(string(wordc), context.temp_allocator)
	if len(word) == 0 do return

	n := int(g_list_model_get_n_items(model))
	for i := n - 1; i >= 0; i -= 1 {
		item := g_list_model_get_item(model, u32(i)) // transfer full
		label := strings.to_lower(string(kat_proposal_label(item)), context.temp_allocator)
		if !strings.contains(label, word) {
			g_list_store_remove(model, u32(i))
		}
		g_object_unref(item)
	}
}

is_trigger_cb :: proc "c" (iter: ^Gtk_Text_Iter, ch: u32, user: gpointer) -> gboolean {
	context = runtime.default_context()
	ed := (^Editor_State)(user)
	if ed.client == nil do return false
	for tc in ed.client.trigger_chars {
		if len(tc) == 1 && u32(tc[0]) == ch do return true
	}
	return false
}

// ---- small helpers --------------------------------------------------

@(private = "file")
jstr :: proc(obj: json.Object, key: string) -> string {
	if s, ok := obj[key].(string); ok do return string(s)
	return ""
}

@(private = "file")
point :: proc(rng: json.Object, which: string) -> (line, character: int) {
	pt, ok := rng[which].(json.Object)
	if !ok do return 0, 0
	return int(cj_int(pt["line"])), int(cj_int(pt["character"]))
}

@(private = "file")
cj_int :: proc(v: json.Value) -> i64 {
	#partial switch n in v {
	case json.Integer: return i64(n)
	case json.Float:   return i64(n)
	}
	return 0
}

// Strip snippet placeholders ($0, $1, ${1:name}) from an insertText (MVP: no
// placeholder editing — insert as plain text).
@(private = "file")
strip_snippet :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	i := 0
	for i < len(s) {
		if s[i] == '$' {
			i += 1
			if i < len(s) && s[i] == '{' {
				// ${n:default} → keep default text after ':'
				depth := 1
				i += 1
				seg := strings.builder_make(context.temp_allocator)
				saw_colon := false
				for i < len(s) && depth > 0 {
					switch s[i] {
					case '{': depth += 1
					case '}': depth -= 1; if depth == 0 { i += 1; continue }
					case ':': if depth == 1 && !saw_colon { saw_colon = true; i += 1; continue }
					}
					if saw_colon do strings.write_byte(&seg, s[i])
					i += 1
				}
				strings.write_string(&b, strings.to_string(seg))
			} else {
				// $n — skip digits
				for i < len(s) && s[i] >= '0' && s[i] <= '9' do i += 1
			}
		} else {
			strings.write_byte(&b, s[i]); i += 1
		}
	}
	return strings.clone(strings.to_string(b), context.temp_allocator)
}

@(private = "file")
temp_cstr :: proc(s: string) -> cstring {
	return strings.clone_to_cstring(s, context.temp_allocator)
}

// Markdown → Pango markup (SPEC §4.3): escape everything, then re-introduce
// <b>/<i>/<tt> for **bold**, *italic*, `code`/```fences```. Toggling scan.
md_to_pango :: proc(src: string) -> string {
	esc := g_markup_escape_text(temp_cstr(src), -1) // g_malloc'd, entities for < > & ' "
	defer g_free(rawptr(esc))
	s := string(esc)

	b := strings.builder_make(context.temp_allocator)
	in_code, in_bold, in_italic := false, false, false
	i := 0
	for i < len(s) {
		if s[i] == '`' {
			// consume a run of backticks (handles ``` fences and `spans`)
			for i < len(s) && s[i] == '`' do i += 1
			if in_code {
				strings.write_string(&b, "</tt>"); in_code = false
			} else {
				strings.write_string(&b, "<tt>"); in_code = true
			}
			continue
		}
		if !in_code && i + 1 < len(s) && s[i] == '*' && s[i + 1] == '*' {
			i += 2
			if in_bold {
				strings.write_string(&b, "</b>"); in_bold = false
			} else {
				strings.write_string(&b, "<b>"); in_bold = true
			}
			continue
		}
		if !in_code && s[i] == '*' {
			i += 1
			if in_italic {
				strings.write_string(&b, "</i>"); in_italic = false
			} else {
				strings.write_string(&b, "<i>"); in_italic = true
			}
			continue
		}
		strings.write_byte(&b, s[i]); i += 1
	}
	// Close any dangling spans so Pango markup stays well-formed.
	if in_code do strings.write_string(&b, "</tt>")
	if in_bold do strings.write_string(&b, "</b>")
	if in_italic do strings.write_string(&b, "</i>")
	return strings.clone(strings.to_string(b), context.temp_allocator)
}
