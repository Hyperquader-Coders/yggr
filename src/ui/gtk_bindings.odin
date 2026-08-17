package ui

// gtk_bindings.odin — hand-rolled foreign decls for GTK4 / GtkSourceView 5 /
// GLib / GIO, plus the C shim (src/ui/shim.c) externs. Signatures were
// verified against the installed headers (/usr/include/gtk-4.0,
// /usr/include/gtksourceview-5, /usr/include/glib-2.0) — see the commit notes.
// Only what the MVP phases use is declared.

foreign import gtk   "system:gtk-4"
foreign import gsv   "system:gtksourceview-5"
foreign import gobj  "system:gobject-2.0"
foreign import glib_ "system:glib-2.0"
foreign import gio_  "system:gio-2.0"
// shim.o is linked in via the Makefile's -extra-linker-flags; its symbols
// resolve at link time from the same final binary, so no foreign import block
// is needed — declare them under `foreign shim` with a matching lib? Odin
// needs a foreign block target; we attach shim decls to the gtk import since
// they end up in the same executable image.

gboolean :: b32
gpointer :: rawptr
GType    :: uint

GSourceFunc         :: proc "c" (user_data: gpointer) -> gboolean
GDestroyNotify      :: proc "c" (data: gpointer)
GAsyncReadyCallback :: proc "c" (source: gpointer, res: gpointer, user: gpointer)

G_PRIORITY_DEFAULT          :: 0
G_APPLICATION_DEFAULT_FLAGS :: 0
G_CONNECT_DEFAULT           :: 0

// Pango underline enum (pango/pango-attributes.h). ERROR = red squiggle.
PANGO_UNDERLINE_NONE   :: 0
PANGO_UNDERLINE_SINGLE :: 1
PANGO_UNDERLINE_ERROR  :: 4

// GtkSourceCompletionColumn (gtksourcecompletioncell.h).
GTK_SOURCE_COMPLETION_COLUMN_ICON       :: 0
GTK_SOURCE_COMPLETION_COLUMN_BEFORE     :: 1
GTK_SOURCE_COMPLETION_COLUMN_TYPED_TEXT :: 2
GTK_SOURCE_COMPLETION_COLUMN_AFTER      :: 3

// GtkTextIter is stack-allocated; 80 bytes on 64-bit (gtktextiter.h). The
// exact size only needs to be >= the real one; GTK never reads past its own
// fields and we always pass a pointer.
Gtk_Text_Iter :: struct {
	_opaque: [80]u8,
}

// Function-pointer table the shim forwards vfuncs into (must match the
// KatLspVtable layout in src/ui/shim.c exactly).
Kat_Lsp_Vtable :: struct {
	hover_populate:      proc "c" (ctx: gpointer, display: gpointer, task: gpointer, user: gpointer),
	completion_populate: proc "c" (ctx: gpointer, task: gpointer, user: gpointer),
	proposal_display:    proc "c" (ctx: gpointer, proposal: gpointer, cell: gpointer, user: gpointer),
	proposal_activate:   proc "c" (ctx: gpointer, proposal: gpointer, user: gpointer),
	is_trigger:          proc "c" (iter: ^Gtk_Text_Iter, ch: u32, user: gpointer) -> gboolean,
	refilter:            proc "c" (ctx: gpointer, model: gpointer, user: gpointer),
}

foreign glib_ {
	g_idle_add_full :: proc "c" (priority: i32, function: GSourceFunc, data: gpointer, notify: GDestroyNotify) -> u32 ---
	g_timeout_add :: proc "c" (interval_ms: u32, function: GSourceFunc, data: gpointer) -> u32 ---
	g_source_remove :: proc "c" (tag: u32) -> gboolean ---
	g_markup_escape_text :: proc "c" (text: cstring, length: i64) -> cstring ---
	g_free :: proc "c" (mem: gpointer) ---
}

foreign gobj {
	g_signal_connect_data :: proc "c" (instance: gpointer, signal: cstring, handler: rawptr, data: gpointer, destroy: rawptr, flags: i32) -> u64 ---
	g_object_unref :: proc "c" (object: gpointer) ---
}

foreign gio_ {
	g_application_run :: proc "c" (app: gpointer, argc: i32, argv: [^]cstring) -> i32 ---
	g_list_store_new :: proc "c" (item_type: GType) -> gpointer ---
	g_list_store_append :: proc "c" (store: gpointer, item: gpointer) ---
	g_list_store_remove :: proc "c" (store: gpointer, position: u32) ---
	g_list_model_get_n_items :: proc "c" (list: gpointer) -> u32 ---
	g_list_model_get_item :: proc "c" (list: gpointer, position: u32) -> gpointer ---
	g_task_return_pointer :: proc "c" (task: gpointer, result: gpointer, destroy: GDestroyNotify) ---
	g_task_return_boolean :: proc "c" (task: gpointer, result: gboolean) ---
	// Completes the task with G_IO_ERROR_CANCELLED (and returns true) if the
	// GCancellable the task was created with has been cancelled — the contract
	// hook for bailing out of a superseded/dismissed/torn-down async op.
	g_task_return_error_if_cancelled :: proc "c" (task: gpointer) -> gboolean ---
}

foreign gtk {
	gtk_application_new :: proc "c" (app_id: cstring, flags: u32) -> gpointer ---
	gtk_application_window_new :: proc "c" (app: gpointer) -> gpointer ---
	gtk_scrolled_window_new :: proc "c" () -> gpointer ---
	gtk_scrolled_window_set_child :: proc "c" (sw: gpointer, child: gpointer) ---
	gtk_window_set_child :: proc "c" (window: gpointer, child: gpointer) ---
	gtk_window_set_default_size :: proc "c" (window: gpointer, w, h: i32) ---
	gtk_window_set_title :: proc "c" (window: gpointer, title: cstring) ---
	gtk_window_present :: proc "c" (window: gpointer) ---
	gtk_widget_grab_focus :: proc "c" (widget: gpointer) -> gboolean ---
	gtk_widget_add_controller :: proc "c" (widget: gpointer, controller: gpointer) ---
	gtk_event_controller_key_new :: proc "c" () -> gpointer ---

	gtk_label_new :: proc "c" (str: cstring) -> gpointer ---
	gtk_label_set_markup :: proc "c" (label: gpointer, markup: cstring) ---

	gtk_text_buffer_set_text :: proc "c" (buffer: gpointer, text: cstring, length: i32) ---
	gtk_text_buffer_get_text :: proc "c" (buffer: gpointer, start, end: ^Gtk_Text_Iter, include_hidden: gboolean) -> cstring ---
	gtk_text_buffer_get_start_iter :: proc "c" (buffer: gpointer, iter: ^Gtk_Text_Iter) ---
	gtk_text_buffer_get_end_iter :: proc "c" (buffer: gpointer, iter: ^Gtk_Text_Iter) ---
	gtk_text_buffer_get_bounds :: proc "c" (buffer: gpointer, start, end: ^Gtk_Text_Iter) ---
	gtk_text_buffer_get_iter_at_line :: proc "c" (buffer: gpointer, iter: ^Gtk_Text_Iter, line: i32) -> gboolean ---
	gtk_text_buffer_get_iter_at_mark :: proc "c" (buffer: gpointer, iter: ^Gtk_Text_Iter, mark: gpointer) ---
	gtk_text_buffer_get_insert :: proc "c" (buffer: gpointer) -> gpointer ---
	gtk_text_buffer_create_mark :: proc "c" (buffer: gpointer, name: cstring, where_: ^Gtk_Text_Iter, left_gravity: gboolean) -> gpointer ---
	gtk_text_buffer_delete_mark :: proc "c" (buffer: gpointer, mark: gpointer) ---
	gtk_text_buffer_apply_tag :: proc "c" (buffer: gpointer, tag: gpointer, start, end: ^Gtk_Text_Iter) ---
	gtk_text_buffer_remove_tag :: proc "c" (buffer: gpointer, tag: gpointer, start, end: ^Gtk_Text_Iter) ---
	gtk_text_buffer_begin_user_action :: proc "c" (buffer: gpointer) ---
	gtk_text_buffer_end_user_action :: proc "c" (buffer: gpointer) ---
	gtk_text_buffer_place_cursor :: proc "c" (buffer: gpointer, where_: ^Gtk_Text_Iter) ---
	gtk_text_buffer_delete :: proc "c" (buffer: gpointer, s, e: ^Gtk_Text_Iter) ---
	gtk_text_buffer_insert :: proc "c" (buffer: gpointer, iter: ^Gtk_Text_Iter, text: cstring, length: i32) ---

	gtk_text_iter_set_line_index :: proc "c" (iter: ^Gtk_Text_Iter, byte_idx: i32) ---
	gtk_text_iter_get_line_index :: proc "c" (iter: ^Gtk_Text_Iter) -> i32 ---
	gtk_text_iter_get_bytes_in_line :: proc "c" (iter: ^Gtk_Text_Iter) -> i32 ---
	gtk_text_iter_get_line :: proc "c" (iter: ^Gtk_Text_Iter) -> i32 ---
	gtk_text_iter_forward_to_line_end :: proc "c" (iter: ^Gtk_Text_Iter) -> gboolean ---
	gtk_text_view_set_monospace :: proc "c" (view: gpointer, monospace: gboolean) ---
}

foreign gsv {
	gtk_source_view_new_with_buffer :: proc "c" (buffer: gpointer) -> gpointer ---
	gtk_source_view_set_show_line_numbers :: proc "c" (view: gpointer, show: gboolean) ---
	gtk_source_view_get_completion :: proc "c" (view: gpointer) -> gpointer ---
	gtk_source_view_get_hover :: proc "c" (view: gpointer) -> gpointer ---
	gtk_source_view_get_tab_width :: proc "c" (view: gpointer) -> u32 ---
	gtk_source_view_get_insert_spaces_instead_of_tabs :: proc "c" (view: gpointer) -> gboolean ---
	gtk_source_completion_add_provider :: proc "c" (completion, provider: gpointer) ---
	gtk_source_hover_add_provider :: proc "c" (hover, provider: gpointer) ---

	gtk_source_buffer_new :: proc "c" (table: gpointer) -> gpointer ---
	gtk_source_buffer_new_with_language :: proc "c" (language: gpointer) -> gpointer ---
	gtk_source_buffer_set_language :: proc "c" (buffer: gpointer, language: gpointer) ---
	gtk_source_buffer_get_language :: proc "c" (buffer: gpointer) -> gpointer ---
	gtk_source_buffer_set_style_scheme :: proc "c" (buffer: gpointer, scheme: gpointer) ---
	gtk_source_style_scheme_manager_get_default :: proc "c" () -> gpointer ---
	gtk_source_style_scheme_manager_get_scheme :: proc "c" (mgr: gpointer, id: cstring) -> gpointer ---
	gtk_source_buffer_create_source_mark :: proc "c" (buffer: gpointer, name, category: cstring, where_: ^Gtk_Text_Iter) -> gpointer ---
	gtk_source_buffer_remove_source_marks :: proc "c" (buffer: gpointer, start, end: ^Gtk_Text_Iter, category: cstring) ---

	gtk_source_language_manager_get_default :: proc "c" () -> gpointer ---
	gtk_source_language_manager_guess_language :: proc "c" (lm: gpointer, filename: cstring, content_type: cstring) -> gpointer ---
	gtk_source_language_manager_get_language :: proc "c" (lm: gpointer, id: cstring) -> gpointer ---
	gtk_source_language_get_id :: proc "c" (language: gpointer) -> cstring ---

	gtk_source_hover_context_get_iter :: proc "c" (ctx: gpointer, iter: ^Gtk_Text_Iter) -> gboolean ---
	gtk_source_hover_display_append :: proc "c" (display: gpointer, child: gpointer) ---

	gtk_source_completion_context_get_bounds :: proc "c" (ctx: gpointer, begin, end: ^Gtk_Text_Iter) -> gboolean ---
	gtk_source_completion_context_get_word :: proc "c" (ctx: gpointer) -> cstring ---
	gtk_source_completion_cell_get_column :: proc "c" (cell: gpointer) -> i32 ---
	gtk_source_completion_cell_set_text :: proc "c" (cell: gpointer, text: cstring) ---
	gtk_source_completion_cell_set_icon_name :: proc "c" (cell: gpointer, icon_name: cstring) ---
}

// C shim (src/ui/shim.c). Linked into the same binary; declared foreign against
// gtk purely to satisfy Odin's need for a foreign block target.
foreign gtk {
	kat_provider_new :: proc "c" (vt: ^Kat_Lsp_Vtable, user: gpointer) -> gpointer ---
	// Completes a populate task with G_IO_ERROR_NOT_SUPPORTED ("declined") —
	// the crash-safe replacement for returning FALSE/NULL with no error set.
	kat_task_return_declined :: proc "c" (task: gpointer) ---
	kat_proposal_get_type :: proc "c" () -> GType ---
	kat_proposal_new :: proc "c" (label, detail, icon_name, insert_text: cstring, has_edit: gboolean, sl, sc, el, ec: i32) -> gpointer ---
	kat_proposal_label :: proc "c" (p: gpointer) -> cstring ---
	kat_proposal_detail :: proc "c" (p: gpointer) -> cstring ---
	kat_proposal_icon_name :: proc "c" (p: gpointer) -> cstring ---
	kat_proposal_insert_text :: proc "c" (p: gpointer) -> cstring ---
	kat_proposal_has_edit :: proc "c" (p: gpointer) -> gboolean ---
	kat_proposal_start_line :: proc "c" (p: gpointer) -> i32 ---
	kat_proposal_start_col :: proc "c" (p: gpointer) -> i32 ---
	kat_proposal_end_line :: proc "c" (p: gpointer) -> i32 ---
	kat_proposal_end_col :: proc "c" (p: gpointer) -> i32 ---
	kat_make_squiggle_tag :: proc "c" (buffer: gpointer, name: cstring, underline: i32, rgba_spec: cstring) -> gpointer ---
	kat_setup_mark_attrs :: proc "c" (view: gpointer, category: cstring, icon_name: cstring, priority: i32) ---
}
