package lsp

// encoding.odin — LSP position encoding conversion (ARCHITECTURE §5).
// Used only when the server refused utf-8 in `initialize`.

import "core:unicode/utf8"

// utf-16 unit offset within `line` → utf-8 byte offset.
// Clamps: offsets past EOL return len(line).
utf16_to_byte :: proc(line: string, u16_off: int) -> int {
	units, bytes := 0, 0
	for r, i in line {
		if units >= u16_off do return i
		units += 1 if r < 0x10000 else 2
		bytes = i + utf8.rune_size(r)
	}
	return len(line) if units <= u16_off else bytes
}

// utf-8 byte offset within `line` → utf-16 unit offset. Clamps.
byte_to_utf16 :: proc(line: string, byte_off: int) -> int {
	units := 0
	for r, i in line {
		if i >= byte_off do return units
		units += 1 if r < 0x10000 else 2
	}
	return units
}
