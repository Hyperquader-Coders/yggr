package ui

// providers.odin — Hover and Completion providers.
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
import "../markup"

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

// Params shared by hover/completion requests.
@(private = "file")
Text_Doc_Position :: struct {
	text_document: lsp.Text_Document_Identifier `json:"textDocument"`,
	position:      lsp.Position                 `json:"position"`,
}

// ============================ Hover =================================

@(private = "file")
Hover_Ctx :: struct {
	ed:      ^Editor_State,
	task:    gpointer,
	display: gpointer,
}

@(private = "file")
Hover_Result_Payload :: struct {
	ed:      ^Editor_State,
	task:    gpointer,
	display: gpointer,
	pango:   string, // heap Pango markup; "" => no result
}

hover_populate_cb :: proc "c" (ctx: gpointer, display: gpointer, task: gpointer, user: gpointer) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	ed := (^Editor_State)(user)
	iter: Gtk_Text_Iter
	if !lsp.client_ready(ed.client) || !ed.client.can_hover || !ed.doc_open || !gtk_source_hover_context_get_iter(ctx, &iter) {
		kat_task_return_declined(task)
		g_object_unref(task)
		return
	}
	editor_flush_change(ed)
	pos := iter_to_position(ed, &iter)

	hc := new(Hover_Ctx, runtime.heap_allocator())
	hc.ed = ed; hc.task = task; hc.display = display
	params := Text_Doc_Position{{ed.uri}, pos}
	lsp.client_request(ed.client, "textDocument/hover", params, on_hover_response_reader, hc)
}

// Reader thread: normalize Hover.contents and render it to Pango markup (plain
// data, no GTK), then hop to main.
on_hover_response_reader :: proc(result: json.Value, is_error: bool, user: rawptr) {
	hc := (^Hover_Ctx)(user)
	defer free(hc, runtime.heap_allocator())

	pango := ""
	if !is_error {
		text, plaintext := lsp.hover_contents(result, context.temp_allocator)
		if len(text) > 0 {
			pango = markup.to_pango(text, .Plaintext if plaintext else .Markdown, runtime.heap_allocator())
		}
	}
	p := new(Hover_Result_Payload, runtime.heap_allocator())
	p.ed = hc.ed; p.task = hc.task; p.display = hc.display; p.pango = pango
	g_idle_add_full(G_PRIORITY_DEFAULT, on_hover_main, p, free_hover_payload)
}

on_hover_main :: proc "c" (data: gpointer) -> gboolean {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
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
	if len(p.pango) == 0 || p.ed.closed {
		// No hover text here (common on e.g. a diagnostic squiggle). Decline
		// with an error rather than g_task_return_boolean(false): a bare FALSE
		// leaves the async error unset and GtkSourceView's populate_cb crashes
		// dereferencing it (error->message).
		kat_task_return_declined(p.task)
		g_object_unref(p.task)
		return false
	}
	// The popup inherits the editor view's monospace font, which would make the
	// prose look like the code; set it in the interface font so only the <tt>
	// code (still the editor's monospace) reads as code.
	ui_font: cstring
	g_object_get(gtk_settings_get_default(), "gtk-font-name", &ui_font, nil)
	text := markup.with_font(p.pango, string(ui_font), context.temp_allocator)
	g_free(rawptr(ui_font))
	label := gtk_label_new(nil)
	gtk_label_set_markup(label, temp_cstr(text))
	gtk_source_hover_display_append(p.display, label)
	g_task_return_boolean(p.task, true)
	g_object_unref(p.task)
	return false
}

free_hover_payload :: proc "c" (data: gpointer) {
	context = runtime.default_context()
	p := (^Hover_Result_Payload)(data)
	if len(p.pango) > 0 do delete(p.pango, runtime.heap_allocator())
	free(p, runtime.heap_allocator())
}

// ========================== Completion ==============================

@(private = "file")
Completion_Ctx :: struct {
	ed:   ^Editor_State,
	task: gpointer,
}

@(private = "file")
Item_Data :: struct {
	label, detail, icon, insert_text: string, // heap
	has_edit:                         bool,
	sl, sc, el, ec:                   int,    // textEdit range as the server sent it
}

@(private = "file")
Completion_Payload :: struct {
	ed:    ^Editor_State,
	task:  gpointer,
	items: []Item_Data, // heap; strings heap
}

MAX_ITEMS :: 200

completion_populate_cb :: proc "c" (ctx: gpointer, task: gpointer, user: gpointer) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	ed := (^Editor_State)(user)
	begin, end: Gtk_Text_Iter
	if !lsp.client_ready(ed.client) || !ed.client.can_complete || !ed.doc_open || !gtk_source_completion_context_get_bounds(ctx, &begin, &end) {
		kat_task_return_declined(task)
		g_object_unref(task)
		return
	}
	editor_flush_change(ed)
	pos := iter_to_position(ed, &end)

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
	p.ed = cc.ed; p.task = cc.task; p.items = items
	g_idle_add_full(G_PRIORITY_DEFAULT, on_completion_main, p, free_completion_payload)
}

on_completion_main :: proc "c" (data: gpointer) -> gboolean {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	p := (^Completion_Payload)(data)
	// Same lifetime hazard as on_hover_main: the completion may have been
	// dismissed or superseded (GtkSourceView cancels the op) while our LSP
	// reply was in flight. Bail via the cancellable rather than returning a
	// model into a torn-down completion context.
	if g_task_return_error_if_cancelled(p.task) {
		g_object_unref(p.task)
		return false
	}
	if len(p.items) == 0 || p.ed.closed {
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
	delete(p.items, runtime.heap_allocator())
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

	out := make([dynamic]Item_Data, 0, min(len(arr), MAX_ITEMS), runtime.heap_allocator())
	for v in arr {
		if len(out) == MAX_ITEMS do break
		obj, ok := v.(json.Object)
		if !ok do continue
		label := jstr(obj, "label")
		if label == "" do continue // label is required (LSP)
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
			// A TextEdit has `range`; an InsertReplaceEdit (which yggr does not
			// advertise, but a server may send) has `insert` and `replace`.
			rng, rok := te["range"].(json.Object)
			if !rok do rng, rok = te["insert"].(json.Object)
			if rok {
				it.has_edit = true
				it.sl, it.sc = point(rng, "start")
				it.el, it.ec = point(rng, "end")
				text = jstr(te, "newText")
			}
		}
		if fmt_flag == 2 do text = strip_snippet(text)
		it.insert_text = strings.clone(text, runtime.heap_allocator())
		append(&out, it)
	}
	return out[:]
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
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	ed := (^Editor_State)(user)
	buffer := ed.buffer
	insert := kat_proposal_insert_text(proposal)

	// The word the completion was invoked on (as GNOME Builder uses it); its
	// end is the cursor.
	begin, end: Gtk_Text_Iter
	has_bounds := gtk_source_completion_context_get_bounds(ctx, &begin, &end)

	gtk_text_buffer_begin_user_action(buffer)
	if kat_proposal_has_edit(proposal) {
		// Apply the server textEdit range.
		si, ei: Gtk_Text_Iter
		position_to_iter(ed, int(kat_proposal_start_line(proposal)), int(kat_proposal_start_col(proposal)), &si)
		position_to_iter(ed, int(kat_proposal_end_line(proposal)), int(kat_proposal_end_col(proposal)), &ei)
		// The range was computed when the request went out. Text typed since,
		// while the popup refiltered, lies between its end and the cursor and
		// belongs to the word being replaced.
		if has_bounds && gtk_text_iter_get_line(&end) == gtk_text_iter_get_line(&ei) && gtk_text_iter_compare(&end, &ei) > 0 {
			ei = end
		}
		gtk_text_buffer_delete(buffer, &si, &ei)
		gtk_text_buffer_insert(buffer, &si, insert, -1)
	} else {
		// Word-replace (SPEC §4.4): delete the word the completion was invoked
		// on, then insert — otherwise the typed prefix is duplicated
		// ("Pri" + Println -> "PriPrintln"). Fall back to the bare cursor.
		if has_bounds {
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
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
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
	if !lsp.client_ready(ed.client) || !ed.client.can_complete do return false
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
// placeholder editing — insert as plain text). Temp memory.
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
	return strings.to_string(b)
}

@(private = "file")
temp_cstr :: proc(s: string) -> cstring {
	return strings.clone_to_cstring(s, context.temp_allocator)
}
