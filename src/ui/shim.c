/* shim.c — GObject ceremony for Yggr LSP providers (ARCHITECTURE §6).
 *
 * Owns ONE GObject type, KatProvider, implementing both
 * GtkSourceCompletionProvider and GtkSourceHoverProvider. Every vfunc
 * forwards into an Odin-supplied vtable so all logic stays in Odin.
 *
 * The vtable is filled from Odin (src/ui/providers.odin); this file owns only
 * the GObject/interface ceremony. Build:
 *   gcc -c src/ui/shim.c -o build/shim.o $(pkg-config --cflags gtk4 gtksourceview-5)
 * and link shim.o into the Odin build (see Makefile).
 */
#include <gtksourceview/gtksource.h>

typedef struct {
  /* Hover: convert context->iter to a position, fire the LSP request,
   * complete `task` from the main thread when the reply lands. */
  void (*hover_populate)(GtkSourceHoverContext *ctx,
                         GtkSourceHoverDisplay *display,
                         GTask *task, void *user);
  /* Completion */
  void (*completion_populate)(GtkSourceCompletionContext *ctx,
                              GTask *task, void *user);
  void (*proposal_display)(GtkSourceCompletionContext *ctx,
                           GtkSourceCompletionProposal *proposal,
                           GtkSourceCompletionCell *cell, void *user);
  void (*proposal_activate)(GtkSourceCompletionContext *ctx,
                            GtkSourceCompletionProposal *proposal,
                            void *user);
  gboolean (*is_trigger)(const GtkTextIter *iter, gunichar ch, void *user);
  /* Narrow an already-populated model as the typed word grows (the interface
   * default is a no-op, so without this the list never filters). */
  void (*refilter)(GtkSourceCompletionContext *ctx, GListModel *model, void *user);
} KatLspVtable;

typedef struct {
  GObject parent_instance;
  KatLspVtable vt;
  void *user;
} KatProvider;

typedef struct { GObjectClass parent_class; } KatProviderClass;

static void kat_completion_iface_init(GtkSourceCompletionProviderInterface *iface);
static void kat_hover_iface_init(GtkSourceHoverProviderInterface *iface);

G_DEFINE_TYPE_WITH_CODE(KatProvider, kat_provider, G_TYPE_OBJECT,
  G_IMPLEMENT_INTERFACE(GTK_SOURCE_TYPE_COMPLETION_PROVIDER, kat_completion_iface_init)
  G_IMPLEMENT_INTERFACE(GTK_SOURCE_TYPE_HOVER_PROVIDER, kat_hover_iface_init))

static void kat_provider_class_init(KatProviderClass *klass) { (void)klass; }
static void kat_provider_init(KatProvider *self) { (void)self; }

/* ---- completion vfuncs ---- */

static void
kat_populate_async(GtkSourceCompletionProvider *provider,
                   GtkSourceCompletionContext *context,
                   GCancellable *cancellable,
                   GAsyncReadyCallback callback, gpointer user_data)
{
  KatProvider *self = (KatProvider *)provider;
  GTask *task = g_task_new(provider, cancellable, callback, user_data);
  /* Ownership: the async method holds the task's ref; whoever completes it
   * (the Odin vtable fn, else this fallback) releases it. */
  if (self->vt.completion_populate)
    self->vt.completion_populate(context, task, self->user);
  else {
    g_task_return_pointer(task, NULL, NULL);
    g_object_unref(task);
  }
}

static GListModel *
kat_populate_finish(GtkSourceCompletionProvider *provider,
                    GAsyncResult *result, GError **error)
{
  (void)provider;
  return g_task_propagate_pointer(G_TASK(result), error);
}

static void
kat_display(GtkSourceCompletionProvider *provider,
            GtkSourceCompletionContext *context,
            GtkSourceCompletionProposal *proposal,
            GtkSourceCompletionCell *cell)
{
  KatProvider *self = (KatProvider *)provider;
  if (self->vt.proposal_display)
    self->vt.proposal_display(context, proposal, cell, self->user);
}

static void
kat_activate(GtkSourceCompletionProvider *provider,
             GtkSourceCompletionContext *context,
             GtkSourceCompletionProposal *proposal)
{
  KatProvider *self = (KatProvider *)provider;
  if (self->vt.proposal_activate)
    self->vt.proposal_activate(context, proposal, self->user);
}

static gboolean
kat_is_trigger(GtkSourceCompletionProvider *provider,
               const GtkTextIter *iter, gunichar ch)
{
  KatProvider *self = (KatProvider *)provider;
  return self->vt.is_trigger ? self->vt.is_trigger(iter, ch, self->user) : FALSE;
}

static void
kat_refilter(GtkSourceCompletionProvider *provider,
             GtkSourceCompletionContext *context,
             GListModel *model)
{
  KatProvider *self = (KatProvider *)provider;
  if (self->vt.refilter)
    self->vt.refilter(context, model, self->user);
}

static void
kat_completion_iface_init(GtkSourceCompletionProviderInterface *iface)
{
  iface->populate_async  = kat_populate_async;
  iface->populate_finish = kat_populate_finish;
  iface->display         = kat_display;
  iface->activate        = kat_activate;
  iface->is_trigger      = kat_is_trigger;
  iface->refilter        = kat_refilter;
}

/* ---- hover vfuncs ---- */

static void
kat_hover_populate_async(GtkSourceHoverProvider *provider,
                         GtkSourceHoverContext *context,
                         GtkSourceHoverDisplay *display,
                         GCancellable *cancellable,
                         GAsyncReadyCallback callback, gpointer user_data)
{
  KatProvider *self = (KatProvider *)provider;
  GTask *task = g_task_new(provider, cancellable, callback, user_data);
  /* Ownership: see kat_populate_async — completer releases the task ref. */
  if (self->vt.hover_populate)
    self->vt.hover_populate(context, display, task, self->user);
  else {
    g_task_return_boolean(task, FALSE);
    g_object_unref(task);
  }
}

static gboolean
kat_hover_populate_finish(GtkSourceHoverProvider *provider,
                          GAsyncResult *result, GError **error)
{
  (void)provider;
  return g_task_propagate_boolean(G_TASK(result), error);
}

static void
kat_hover_iface_init(GtkSourceHoverProviderInterface *iface)
{
  iface->populate_async  = kat_hover_populate_async;
  iface->populate_finish = kat_hover_populate_finish;
}

/* Complete a hover/completion populate task as "this provider has nothing for
 * this position". MUST be used instead of g_task_return_boolean(task, FALSE) /
 * g_task_return_pointer(task, NULL, ...): those leave the GAsyncResult's error
 * unset, and GtkSourceView's populate_cb assumes a failed populate ALWAYS
 * carries an error — gtk_source_hover_context_populate_cb does
 * `g_debug("%s population failed", error->message)` and dereferences the NULL
 * error → SIGSEGV (seen when hovering a spot the server returns empty hover
 * for, e.g. a diagnostic squiggle). Returning G_IO_ERROR_NOT_SUPPORTED is the
 * canonical "declined" signal, which both the hover and completion contexts
 * special-case and swallow silently. */
void
kat_task_return_declined(GTask *task)
{
  g_task_return_new_error(task, G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED,
                          "no result for this position");
}

/* ---- exported constructor (called from Odin) ---- */

KatProvider *
kat_provider_new(const KatLspVtable *vt, void *user)
{
  KatProvider *self = g_object_new(kat_provider_get_type(), NULL);
  self->vt = *vt;
  self->user = user;
  return self;
}

/* ============================================================= *
 * KatProposal — a GObject implementing GtkSourceCompletionProposal
 * (a marker interface with no vfuncs). Carries one completion item's
 * data so Odin's display/activate handlers stay pure logic. Strings are
 * owned by the proposal and freed on finalize. Range fields are utf-8
 * byte offsets (0-based line, byte-index column); has_edit selects
 * textEdit-vs-word-replace at activation.
 * ============================================================= */

typedef struct {
  GObject parent_instance;
  char *label;
  char *detail;
  char *icon_name;
  char *insert_text;
  gboolean has_edit;
  int start_line, start_col, end_line, end_col;
} KatProposal;

typedef struct { GObjectClass parent_class; } KatProposalClass;

static void kat_proposal_iface_init(GtkSourceCompletionProposalInterface *iface) { (void)iface; }

G_DEFINE_TYPE_WITH_CODE(KatProposal, kat_proposal, G_TYPE_OBJECT,
  G_IMPLEMENT_INTERFACE(GTK_SOURCE_TYPE_COMPLETION_PROPOSAL, kat_proposal_iface_init))

static void
kat_proposal_finalize(GObject *object)
{
  KatProposal *self = (KatProposal *)object;
  g_free(self->label);
  g_free(self->detail);
  g_free(self->icon_name);
  g_free(self->insert_text);
  G_OBJECT_CLASS(kat_proposal_parent_class)->finalize(object);
}

static void kat_proposal_class_init(KatProposalClass *klass) {
  G_OBJECT_CLASS(klass)->finalize = kat_proposal_finalize;
}
static void kat_proposal_init(KatProposal *self) { (void)self; }

KatProposal *
kat_proposal_new(const char *label, const char *detail, const char *icon_name,
                 const char *insert_text, gboolean has_edit,
                 int start_line, int start_col, int end_line, int end_col)
{
  KatProposal *self = g_object_new(kat_proposal_get_type(), NULL);
  self->label       = g_strdup(label ? label : "");
  self->detail      = g_strdup(detail ? detail : "");
  self->icon_name   = g_strdup(icon_name ? icon_name : "");
  self->insert_text = g_strdup(insert_text ? insert_text : "");
  self->has_edit    = has_edit;
  self->start_line  = start_line;
  self->start_col   = start_col;
  self->end_line    = end_line;
  self->end_col     = end_col;
  return self;
}

/* Getters used by Odin's proposal_display / proposal_activate. */
const char *kat_proposal_label(KatProposal *p)       { return p->label; }
const char *kat_proposal_detail(KatProposal *p)      { return p->detail; }
const char *kat_proposal_icon_name(KatProposal *p)   { return p->icon_name; }
const char *kat_proposal_insert_text(KatProposal *p) { return p->insert_text; }
gboolean    kat_proposal_has_edit(KatProposal *p)    { return p->has_edit; }
int  kat_proposal_start_line(KatProposal *p) { return p->start_line; }
int  kat_proposal_start_col(KatProposal *p)  { return p->start_col; }
int  kat_proposal_end_line(KatProposal *p)   { return p->end_line; }
int  kat_proposal_end_col(KatProposal *p)    { return p->end_col; }

/* ============================================================= *
 * GObject property varargs helpers — owning the ceremony Odin FFI can't
 * express cleanly (SPEC §4.2 severity tags + gutter mark attributes).
 * ============================================================= */

/* Create (once) a squiggle tag: PANGO underline + optional underline color.
 * `rgba_spec` may be NULL (e.g. dotted/dim handled by caller via other props).
 */
void *
kat_make_squiggle_tag(GtkTextBuffer *buffer, const char *name,
                      int underline, const char *rgba_spec)
{
  GtkTextTag *tag;
  if (rgba_spec && *rgba_spec) {
    GdkRGBA rgba;
    gdk_rgba_parse(&rgba, rgba_spec);
    tag = gtk_text_buffer_create_tag(buffer, name,
                                     "underline", (PangoUnderline)underline,
                                     "underline-rgba", &rgba,
                                     NULL);
  } else {
    tag = gtk_text_buffer_create_tag(buffer, name,
                                     "underline", (PangoUnderline)underline,
                                     NULL);
  }
  return tag;
}

/* Register a gutter mark category's icon + priority on the view. */
void
kat_setup_mark_attrs(GtkSourceView *view, const char *category,
                     const char *icon_name, int priority)
{
  GtkSourceMarkAttributes *attrs = gtk_source_mark_attributes_new();
  gtk_source_mark_attributes_set_icon_name(attrs, icon_name);
  gtk_source_view_set_mark_attributes(view, category, attrs, priority);
  /* view keeps its own ref */
  g_object_unref(attrs);
}
