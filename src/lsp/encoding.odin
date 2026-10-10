package lsp

// encoding.odin — LSP position encoding conversion (ARCHITECTURE §5).
// The utf-16 converters are used only when the server refused utf-8 in
// `initialize`.

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

// LSP `character` on `line` (the line's text without its terminator) → a utf-8
// byte offset safe to hand to gtk_text_iter_set_line_index: converted from
// utf-16 units unless the server negotiated utf-8, clamped to the line, and
// moved back to the start of a character. GTK aborts the process on an index
// past the line or inside a multi-byte character, so a server's off-by-one
// must never reach it unchecked.
character_to_byte :: proc(line: string, character: int, utf8_pos: bool) -> int {
	if character <= 0 do return 0
	off := character if utf8_pos else utf16_to_byte(line, character)
	if off >= len(line) do return len(line)
	for off > 0 && line[off] & 0xC0 == 0x80 do off -= 1
	return off
}
