+++
title = "Restart a crashed language server"
size = "M"
base = "main"
check = ["make ci"]
paths = ["src/ui/editor.odin", "src/lsp/", "docs/SPEC.md", "MoSCoW.md", "docs/DECISIONS.md"]
status = "open"
+++

# Restart a crashed language server

Today a language server that exits or breaks its stream is reaped, its diagnostics are cleared,
and LSP stays off until the file is opened again (SPEC §5, `src/ui/editor.odin` around the
"language server exited; LSP disabled" line). Bring it back on its own, without letting a server
that crashes on start loop forever.

## What to do

- When the server dies, start it again through `editor_start_client`, as opening the file does:
  `initialize`, then `didOpen` with the buffer's current text, so diagnostics come back for what
  is on screen, unsaved edits included.
- At most one restart a minute. A server that dies again within the minute stays off for the
  rest of the session, with one stderr line saying so, as now.
- Keep the decision headless and testable: a small policy in `src/lsp/` (for example
  `restart_allowed(last_restart, now) -> bool`) that the UI calls, with tests in
  `src/lsp/lsp_test.odin`: the first death restarts, a second within 60 s does not, one after
  60 s does.
- Nothing modal, and nothing in the window: one stderr line per restart.

## Done when

- `make ci` passes; the new tests run in `make test` with no GTK.
- By hand: open an Odin file, `pkill ols`, and diagnostics return within a few seconds; kill it
  twice within a minute and LSP stays off.
- SPEC §5 says what happens now (rewritten in place), the MoSCoW item "Restart a crashed
  language server" is removed, and `docs/DECISIONS.md` gets an entry: why once a minute.
