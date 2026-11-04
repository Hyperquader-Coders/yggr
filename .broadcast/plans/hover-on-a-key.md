+++
title = "Hover on a keybinding"
size = "S"
base = "main"
check = ["make ci"]
paths = ["src/ui/editor.odin", "src/ui/providers.odin", "docs/SPEC.md", "MoSCoW.md"]
status = "open"
+++

# Hover on a keybinding

Hover shows only when the pointer rests on a word (GtkSourceView's own hover, SPEC §4.3), so a
keyboard user never sees it. Add a key that shows the hover for the word at the cursor.

## What to do

- Ctrl+K shows the hover popover for the symbol at the insertion cursor, using the same request,
  markup and escaping as the pointer hover (`src/ui/providers.odin`, `src/markup/`). Add it in
  `on_key_pressed` in `src/ui/editor.odin` beside Ctrl+S and Ctrl+Shift+F.
- Escape, typing, or moving the cursor closes it.
- No server, or a server without `hoverProvider`: the key does nothing, silently, as the pointer
  hover does.
- Server text is escaped exactly as it is now. Never pass it to Pango unescaped.

## Done when

- `make ci` passes.
- By hand: in an Odin file, put the cursor on `fmt.println` and press Ctrl+K; the same doc
  string appears as on pointer dwell, and Escape closes it.
- SPEC §4.3 lists the key (rewritten in place), and the MoSCoW item "Hover on a keybinding"
  is removed.
