package markup

// markup.odin — language-server hover text → Pango markup for a GtkLabel.
//
// Servers send Markdown (ols: a fenced ```odin block with the signature, a `---`
// rule, then the doc comment) or plain text. Pango understands neither, so this
// renders the few constructs a hover uses:
//
//   fenced (``` / ~~~) and indented code blocks  → <tt> block, fence lines gone
//   `---` / `***` / `___` rules                  → dropped (blocks are separated
//                                                  by a blank line anyway)
//   # headings                                   → <b>
//   paragraphs                                   → text, line breaks kept
//   - / * / + list items                         → "• "
//   `code`, **bold**, __bold__, *italic*, _italic_ → <tt>, <b>, <i>
//   [text](url), ![alt](url), <scheme:url>        → the text / alt / url
//   \* backslash escapes                          → the literal character
//
// Anything else stays literal. Safety: every byte of server text goes through
// write_escaped, which escapes & < > " ' and replaces invalid UTF-8 and control
// characters (GMarkup rejects both, and the label would come up empty). The
// only tags in the output are the ones written here, each opened and closed in
// the same call over an independently rendered substring, so the result is
// well-formed whatever the input: raw HTML such as <b> shows as literal text.
//
// Pure Odin, no GTK: tested headless (markup_test.odin).

import "core:strings"
import "core:unicode/utf8"

Kind :: enum {
	Markdown,
	Plaintext,
}

// to_pango renders `text` as Pango markup. The result is allocated with
// `allocator`; an input with no visible content gives "".
to_pango :: proc(text: string, kind: Kind, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	switch kind {
	case .Plaintext:
		write_escaped(&b, strings.trim_right_space(strings.trim_left(text, "\r\n")))
	case .Markdown:
		write_markdown(&b, text)
	}
	return strings.to_string(b)
}

// with_font wraps Pango markup from to_pango in a span set in `font` (a Pango
// font description such as "Cantarell 11"); code keeps its <tt> monospace. An
// empty font returns a copy of the markup.
with_font :: proc(pango, font: string, allocator := context.allocator) -> string {
	if len(font) == 0 do return strings.clone(pango, allocator)
	b := strings.builder_make(allocator)
	strings.write_string(&b, "<span font_desc=\"")
	write_escaped(&b, font)
	strings.write_string(&b, "\">")
	strings.write_string(&b, pango)
	strings.write_string(&b, "</span>")
	return strings.to_string(b)
}

// ---------------------------------------------------------------- blocks ---

@(private = "file")
Blocks :: struct {
	b:       ^strings.Builder,
	started: bool,       // a block has been written: the next one needs a gap
	para:    [dynamic]string, // pending paragraph lines
}

@(private = "file")
write_markdown :: proc(b: ^strings.Builder, src: string) {
	lines := strings.split_lines(src, context.temp_allocator)
	for &l in lines do l = strings.trim_right(l, "\r")

	w := Blocks{b = b, para = make([dynamic]string, context.temp_allocator)}
	i := 0
	for i < len(lines) {
		line := lines[i]
		if ch, n, indent, ok := fence_open(line); ok {
			flush_para(&w)
			begin_block(&w)
			strings.write_string(b, "<tt>")
			j := i + 1
			for ; j < len(lines) && !fence_close(lines[j], ch, n); j += 1 {
				if j > i + 1 do strings.write_byte(b, '\n')
				write_escaped(b, strip_indent(lines[j], indent))
			}
			strings.write_string(b, "</tt>")
			i = j + 1 // past the closing fence (or EOF: an unclosed fence runs to the end)
			continue
		}
		if is_blank(line) {
			flush_para(&w)
			i += 1
			continue
		}
		// An indented code block cannot interrupt a paragraph (CommonMark).
		if len(w.para) == 0 && code_indent(line) > 0 {
			i = indented_code(&w, lines, i)
			continue
		}
		trimmed := strings.trim_space(line)
		if is_rule(trimmed) {
			flush_para(&w)
			i += 1
			continue
		}
		if text, ok := heading(trimmed); ok {
			flush_para(&w)
			begin_block(&w)
			strings.write_string(b, "<b>")
			write_inline(b, text)
			strings.write_string(b, "</b>")
			i += 1
			continue
		}
		append(&w.para, line)
		i += 1
	}
	flush_para(&w)
}

@(private = "file")
begin_block :: proc(w: ^Blocks) {
	if w.started do strings.write_string(w.b, "\n\n")
	w.started = true
}

@(private = "file")
flush_para :: proc(w: ^Blocks) {
	if len(w.para) == 0 do return
	begin_block(w)
	for line, k in w.para {
		if k > 0 do strings.write_byte(w.b, '\n')
		write_para_line(w.b, line)
	}
	clear(&w.para)
}

// A paragraph line keeps its leading whitespace (doc comments align things with
// it); a list marker becomes a bullet.
@(private = "file")
write_para_line :: proc(b: ^strings.Builder, line: string) {
	rest := strings.trim_left(line, " \t")
	lead := line[:len(line) - len(rest)]
	if len(rest) >= 2 && (rest[0] == '-' || rest[0] == '*' || rest[0] == '+') && (rest[1] == ' ' || rest[1] == '\t') {
		strings.write_string(b, lead)
		strings.write_string(b, "• ")
		write_inline(b, strings.trim_left(rest[2:], " \t"))
		return
	}
	strings.write_string(b, lead)
	write_inline(b, rest)
}

// Consumes an indented code block starting at lines[i]; blank lines inside it
// are kept when more indented lines follow. Returns the next line index.
@(private = "file")
indented_code :: proc(w: ^Blocks, lines: []string, i: int) -> int {
	end := i // one past the last indented line
	for j := i; j < len(lines); j += 1 {
		if code_indent(lines[j]) > 0 {
			end = j + 1
		} else if !is_blank(lines[j]) {
			break
		}
	}
	begin_block(w)
	strings.write_string(w.b, "<tt>")
	for j in i ..< end {
		if j > i do strings.write_byte(w.b, '\n')
		line := lines[j]
		write_escaped(w.b, line[code_indent(line):])
	}
	strings.write_string(w.b, "</tt>")
	return end
}

// Bytes of indentation that make `line` an indented code line: a tab, or four
// spaces (up to three spaces then a tab also count). 0 if it is not one.
@(private = "file")
code_indent :: proc(line: string) -> int {
	if is_blank(line) do return 0
	for k in 0 ..< min(4, len(line)) {
		switch line[k] {
		case '\t': return k + 1
		case ' ':  if k == 3 do return 4
		case:      return 0
		}
	}
	return 0
}

// An opening code fence: up to three spaces, then three or more ` or ~. A
// backtick fence's info string (the language) may not contain a backtick.
@(private = "file")
fence_open :: proc(line: string) -> (ch: byte, n: int, indent: int, ok: bool) {
	for indent < len(line) && indent < 4 && line[indent] == ' ' do indent += 1
	if indent > 3 || indent >= len(line) do return
	ch = line[indent]
	if ch != '`' && ch != '~' do return
	n = run_length(line, indent)
	if n < 3 do return
	if ch == '`' && strings.contains_rune(line[indent + n:], '`') do return
	return ch, n, indent, true
}

// A closing fence: up to three spaces, at least n of the opening character,
// then only whitespace.
@(private = "file")
fence_close :: proc(line: string, ch: byte, n: int) -> bool {
	k := 0
	for k < len(line) && k < 4 && line[k] == ' ' do k += 1
	if k > 3 || k >= len(line) || line[k] != ch do return false
	m := run_length(line, k)
	return m >= n && is_blank(line[k + m:])
}

// Removes up to `indent` leading spaces (the fence's own indentation).
@(private = "file")
strip_indent :: proc(line: string, indent: int) -> string {
	k := 0
	for k < indent && k < len(line) && line[k] == ' ' do k += 1
	return line[k:]
}

// A thematic break: three or more of the same -, * or _, spaces allowed between.
@(private = "file")
is_rule :: proc(trimmed: string) -> bool {
	if len(trimmed) == 0 do return false
	c := trimmed[0]
	if c != '-' && c != '*' && c != '_' do return false
	count := 0
	for k in 0 ..< len(trimmed) {
		if trimmed[k] == c {
			count += 1
		} else if trimmed[k] != ' ' && trimmed[k] != '\t' {
			return false
		}
	}
	return count >= 3
}

// An ATX heading: one to six #, then a space or the end. Returns its text with
// an optional closing run of # removed.
@(private = "file")
heading :: proc(trimmed: string) -> (text: string, ok: bool) {
	n := run_length(trimmed, 0)
	if len(trimmed) == 0 || trimmed[0] != '#' || n > 6 do return
	if n < len(trimmed) && trimmed[n] != ' ' && trimmed[n] != '\t' do return
	text = strings.trim_space(trimmed[n:])
	closing := strings.trim_right(text, "#")
	if len(closing) == 0 {
		text = ""
	} else if closing[len(closing) - 1] == ' ' || closing[len(closing) - 1] == '\t' {
		text = strings.trim_space(closing)
	}
	return text, true
}

// ---------------------------------------------------------------- inline ---

@(private = "file")
write_inline :: proc(b: ^strings.Builder, s: string) {
	i := 0
	for i < len(s) {
		c := s[i]
		switch c {
		case '\\':
			if i + 1 < len(s) && is_ascii_punct(s[i + 1]) {
				write_escaped(b, s[i + 1:i + 2])
				i += 2
				continue
			}
		case '`':
			n := run_length(s, i)
			if end, ok := find_run(s, i + n, '`', n); ok {
				code := s[i + n:end]
				// One space either side is padding when both are there and the
				// span is not all spaces: `` `x` `` shows `x`.
				if len(code) >= 2 && code[0] == ' ' && code[len(code) - 1] == ' ' && strings.trim_space(code) != "" {
					code = code[1:len(code) - 1]
				}
				strings.write_string(b, "<tt>")
				write_escaped(b, code)
				strings.write_string(b, "</tt>")
				i = end + n
			} else {
				strings.write_string(b, s[i:i + n]) // unmatched: literal backticks
				i += n
			}
			continue
		case '*', '_':
			if next, ok := emphasis(b, s, i); ok {
				i = next
				continue
			}
			n := run_length(s, i) // no closer: the whole run is literal
			strings.write_string(b, s[i:i + n])
			i += n
			continue
		case '[':
			if text, next, ok := link(s, i); ok {
				write_inline(b, text)
				i = next
				continue
			}
		case '!':
			if i + 1 < len(s) && s[i + 1] == '[' {
				if alt, next, ok := link(s, i + 1); ok {
					write_inline(b, alt)
					i = next
					continue
				}
			}
		case '<':
			if end := autolink_end(s, i); end > 0 {
				write_escaped(b, s[i + 1:end])
				i = end + 1
				continue
			}
		}
		// One rune, escaped (multi-byte runes pass through whole).
		_, size := utf8.decode_rune_in_string(s[i:])
		write_escaped(b, s[i:i + size])
		i += size
	}
}

// **strong** / __strong__ (a run of two or more) or *em* / _em_ at s[i]. The
// content must not start or end with whitespace; `_` does not open or close
// inside a word (snake_case stays literal). Returns the index after the closer.
@(private = "file")
emphasis :: proc(b: ^strings.Builder, s: string, i: int) -> (next: int, ok: bool) {
	d := s[i]
	n := 2 if run_length(s, i) >= 2 else 1
	if d == '_' && i > 0 && is_word(s[i - 1]) do return
	open_end := i + n
	if open_end >= len(s) || is_space(s[open_end]) do return

	for from := open_end + 1; from <= len(s) - n; {
		end, found := find_run(s, from, d, n, exact = n == 1)
		if !found do return
		if !is_space(s[end - 1]) && !(d == '_' && end + n < len(s) && is_word(s[end + n])) {
			tag := "b" if n == 2 else "i"
			strings.write_string(b, "<")
			strings.write_string(b, tag)
			strings.write_string(b, ">")
			write_inline(b, s[open_end:end])
			strings.write_string(b, "</")
			strings.write_string(b, tag)
			strings.write_string(b, ">")
			return end + n, true
		}
		from = end + 1
	}
	return
}

// [text](destination) at s[i] ('['). Brackets may nest in the text; the
// destination is skipped whole, parentheses balanced. Returns the text and the
// index after ')'.
@(private = "file")
link :: proc(s: string, i: int) -> (text: string, next: int, ok: bool) {
	depth := 0
	close := -1
	scan: for k := i; k < len(s); k += 1 {
		switch s[k] {
		case '\\': k += 1
		case '[':  depth += 1
		case ']':
			depth -= 1
			if depth == 0 { close = k; break scan }
		}
	}
	if close < 0 || close + 1 >= len(s) || s[close + 1] != '(' do return
	depth = 0
	for k := close + 1; k < len(s); k += 1 {
		switch s[k] {
		case '\\': k += 1
		case '(':  depth += 1
		case ')':
			depth -= 1
			if depth == 0 do return s[i + 1:close], k + 1, true
		}
	}
	return
}

// <scheme:rest> or <user@host> at s[i] ('<'): returns the index of '>', or 0.
// No spaces or '<' inside, so raw HTML such as <b> is never taken for one.
@(private = "file")
autolink_end :: proc(s: string, i: int) -> int {
	has_mark := false
	for k := i + 1; k < len(s); k += 1 {
		switch s[k] {
		case '>':        return k if has_mark && k > i + 1 else 0
		case ':', '@':   has_mark = true
		case ' ', '\t', '<': return 0
		}
	}
	return 0
}

// First run of the delimiter at or after `from`: exactly n long, or (exact =
// false) at least n long, in which case the last n of the run are used
// (`***x***` closes strong at the last two, leaving `*x*` inside). Emphasis
// delimiters inside a code span do not count. Returns the run's start.
@(private = "file")
find_run :: proc(s: string, from: int, d: byte, n: int, exact := true) -> (int, bool) {
	k := from
	for k < len(s) {
		if s[k] == '`' && d != '`' {
			m := run_length(s, k)
			end, ok := find_run(s, k + m, '`', m)
			k = end + m if ok else k + m
			continue
		}
		if s[k] != d {
			k += 1
			continue
		}
		m := run_length(s, k)
		if m == n do return k, true
		if !exact && m > n do return k + m - n, true
		k += m
	}
	return 0, false
}

// ---------------------------------------------------------------- escape ---

// Writes s as Pango text: & < > " ' as entities, invalid UTF-8 and control
// characters other than tab and newline as U+FFFD.
@(private = "file")
write_escaped :: proc(b: ^strings.Builder, s: string) {
	for r in s {
		switch r {
		case '&':  strings.write_string(b, "&amp;")
		case '<':  strings.write_string(b, "&lt;")
		case '>':  strings.write_string(b, "&gt;")
		case '"':  strings.write_string(b, "&quot;")
		case '\'': strings.write_string(b, "&apos;")
		case '\t', '\n':
			strings.write_rune(b, r)
		case:
			if r < 0x20 || r == 0x7f || r == utf8.RUNE_ERROR || (r >= 0x80 && r < 0xa0) {
				strings.write_rune(b, utf8.RUNE_ERROR)
			} else {
				strings.write_rune(b, r)
			}
		}
	}
}

// ---------------------------------------------------------------- bytes ----

@(private = "file")
run_length :: proc(s: string, i: int) -> int {
	if i >= len(s) do return 0
	k := i
	for k < len(s) && s[k] == s[i] do k += 1
	return k - i
}

@(private = "file")
is_blank :: proc(s: string) -> bool {
	return len(strings.trim_space(s)) == 0
}

@(private = "file")
is_space :: proc(c: byte) -> bool {
	return c == ' ' || c == '\t' || c == '\n'
}

@(private = "file")
is_word :: proc(c: byte) -> bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c >= 0x80
}

@(private = "file")
is_ascii_punct :: proc(c: byte) -> bool {
	return c >= '!' && c <= '/' || c >= ':' && c <= '@' || c >= '[' && c <= '`' || c >= '{' && c <= '~'
}
