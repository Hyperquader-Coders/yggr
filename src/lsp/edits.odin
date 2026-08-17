package lsp

// edits.odin — TextEdit ordering + a pure-Odin application mirror.
// NO GTK. The GTK formatting path (src/ui) reuses `sort_edits_desc` and then
// resolves each range to buffer iters; this file additionally provides
// `apply_edits_to_text`, a headless equivalent used by tests and any
// non-GTK caller. Positions are utf-8 byte offsets (utf8_pos mode).

import "core:slice"
import "core:strings"

// Sort descending by (start.line, start.character) so edits apply bottom-up
// without invalidating the offsets of edits not yet applied (ARCHITECTURE §4).
sort_edits_desc :: proc(edits: []Text_Edit) {
	slice.sort_by(edits, proc(a, b: Text_Edit) -> bool {
		if a.range.start.line != b.range.start.line {
			return a.range.start.line > b.range.start.line
		}
		return a.range.start.character > b.range.start.character
	})
}

// (line, byte-char) → absolute byte offset in `text`. Clamps char past the
// line's end and lines past EOF, matching the GTK iter clamping (ARCH §5).
line_char_to_offset :: proc(text: string, line, char: int) -> int {
	off := 0
	cur := 0
	for cur < line {
		idx := strings.index_byte(text[off:], '\n')
		if idx < 0 do return len(text)
		off += idx + 1
		cur += 1
	}
	line_end := off
	for line_end < len(text) && text[line_end] != '\n' {
		line_end += 1
	}
	target := off + char
	return min(target, line_end)
}

// Apply LSP TextEdits to a flat string, bottom-up. Result is freshly
// allocated in `allocator`. Mirrors the buffer edit loop the UI runs.
apply_edits_to_text :: proc(text: string, edits: []Text_Edit, allocator := context.allocator) -> string {
	tmp := make([]Text_Edit, len(edits), context.temp_allocator)
	copy(tmp, edits)
	sort_edits_desc(tmp)

	buf: [dynamic]u8
	defer delete(buf)
	append(&buf, text)

	for e in tmp {
		cur := string(buf[:])
		s := line_char_to_offset(cur, e.range.start.line, e.range.start.character)
		en := line_char_to_offset(cur, e.range.end.line, e.range.end.character)
		if s > en do s = en // defensive: reversed/degenerate range

		tail := slice.clone(buf[en:], context.temp_allocator)
		resize(&buf, s)
		append(&buf, e.new_text)
		append(&buf, ..tail)
	}
	return strings.clone(string(buf[:]), allocator)
}
