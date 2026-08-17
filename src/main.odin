package main

// main.odin — entry point. Everything GTK lives in package ui (src/ui); the
// headless-testable LSP client core lives in package lsp (src/lsp). This file
// only parses argv and hands off to ui.run.

import "core:os"
import ui "ui"

main :: proc() {
	// A file is optional: with none, open an empty "Untitled" buffer (so a
	// bare launch / .desktop / double-click shows a window instead of exiting).
	path := os.args[1] if len(os.args) >= 2 else ""
	ui.run(path)
}
