package lsp

// Headless tests — SPEC acceptance criteria 1–3.
// Run: odin test src/lsp

import "core:testing"
import "core:sync"
import "core:time"
import "core:encoding/json"
import ols "vendor_ols"

// In-memory ols.Reader source. `chunk` bounds how many bytes each read
// returns: chunk == 0 hands back everything available (coalesced case);
// chunk == 1 drips one byte per read (split-across-reads case).
Mem_Src :: struct {
	data:  []u8,
	pos:   int,
	chunk: int,
}

mem_read_fn :: proc(ctx: rawptr, buf: []byte) -> (int, int) {
	m := (^Mem_Src)(ctx)
	if m.pos >= len(m.data) do return 0, 1 // EOF
	avail := len(m.data) - m.pos
	take := min(len(buf), avail)
	if m.chunk > 0 do take = min(take, m.chunk)
	n := copy(buf, m.data[m.pos:m.pos + take])
	m.pos += n
	return n, 0
}

// Acceptance criterion 2, now exercising the vendored OLS framing (rule 10):
// a message split across many reads, and two messages coalesced in one read.
@(test)
test_frame_split_and_coalesced :: proc(t: ^testing.T) {
	msg1 := "Content-Length: 2\r\n\r\n{}"
	msg2 := "Content-Length: 7\r\n\r\n\"hello\""

	read_one :: proc(reader: ^ols.Reader) -> (string, bool) {
		h, ok := ols.read_and_parse_header(reader)
		if !ok do return "", false
		body := make([]u8, h.content_length)
		if !ols.read_sized(reader, body) {
			delete(body)
			return "", false
		}
		return string(body), true
	}

	// Coalesced: both messages available in one buffer; drained one frame at a
	// time. chunk == 0 → each underlying read returns as much as fits.
	{
		combined := make([dynamic]u8)
		defer delete(combined)
		append(&combined, msg1)
		append(&combined, msg2)
		src := Mem_Src{data = combined[:]}
		r := ols.make_reader(mem_read_fn, &src)

		b1, ok1 := read_one(&r)
		testing.expect(t, ok1 && b1 == "{}", "first coalesced frame")
		delete(b1)
		b2, ok2 := read_one(&r)
		testing.expect(t, ok2 && b2 == "\"hello\"", "second coalesced frame")
		delete(b2)
		_, ok3 := read_one(&r)
		testing.expect(t, !ok3, "no third frame")
	}

	// Split: the same message delivered one byte per read.
	{
		data := make([dynamic]u8)
		defer delete(data)
		append(&data, msg2)
		src := Mem_Src{data = data[:], chunk = 1}
		r := ols.make_reader(mem_read_fn, &src)

		body, ok := read_one(&r)
		testing.expect(t, ok && body == "\"hello\"", "split frame reassembled")
		delete(body)
	}
}

@(test)
test_utf16_conversion :: proc(t: ^testing.T) {
	// "héllo 🦀 wörld"
	// bytes:  h(1) é(2) l l o sp = 7 bytes to crab; crab 🦀 = 4 bytes (2 utf-16 units)
	// utf16:  h é l l o sp = 6 units to crab
	line := "héllo 🦀 wörld"

	testing.expect_value(t, byte_to_utf16(line, 0), 0)
	testing.expect_value(t, utf16_to_byte(line, 0), 0)

	// offset of the crab
	crab_byte := 7 // h=1 + é=2 + l=1 + l=1 + o=1 + sp=1
	testing.expect_value(t, byte_to_utf16(line, crab_byte), 6)
	testing.expect_value(t, utf16_to_byte(line, 6), crab_byte)

	// just after the crab: +4 bytes, +2 units
	testing.expect_value(t, byte_to_utf16(line, crab_byte + 4), 8)
	testing.expect_value(t, utf16_to_byte(line, 8), crab_byte + 4)

	// clamping
	testing.expect_value(t, utf16_to_byte(line, 999), len(line))
}

// Acceptance criterion 7 (headless mirror): reverse-order TextEdit
// application. Edits are supplied in ASCENDING order and overlap in offset
// space such that naive top-down application with original offsets would
// corrupt the result — proving the descending sort is load-bearing.
@(test)
test_reverse_order_textedits :: proc(t: ^testing.T) {
	text := "0123456789"
	edits := []Text_Edit{
		{range = {{0, 0}, {0, 2}}, new_text = ""},   // delete "01"
		{range = {{0, 5}, {0, 7}}, new_text = "XY"}, // replace "56" -> "XY"
	}
	got := apply_edits_to_text(text, edits)
	defer delete(got)
	testing.expect_value(t, got, "234XY789")

	// Multi-line format-style edit (insert a header line at the top).
	text2 := "package main\nfunc main(){}\n"
	edits2 := []Text_Edit{
		{range = {{0, 0}, {0, 0}}, new_text = "// formatted\n"},
	}
	got2 := apply_edits_to_text(text2, edits2)
	defer delete(got2)
	testing.expect_value(t, got2, "// formatted\npackage main\nfunc main(){}\n")
}

// Correlation / lifecycle test — spawns scripts/fake_lsp.py through the real
// transport + reader thread, runs the initialize handshake, then fires a
// hover request and asserts the response is routed back to the right
// callback. Requires python3 (README: fake_lsp is the headless test server);
// no GTK/Foundry needed (acceptance criterion 1).
Corr_Sync :: struct {
	mu:               sync.Mutex,
	init_done:        bool,
	hover_done:       bool,
	hover_has_result: bool,
}

@(test)
test_request_correlation :: proc(t: ^testing.T) {
	argv := []string{"python3", "scripts/fake_lsp.py"}
	cs := Corr_Sync{}
	handler := Notification_Handler{user = &cs}
	c, ok := client_start(argv, ".", handler)
	if !ok {
		testing.fail_now(t, "could not spawn python3 scripts/fake_lsp.py (needed for headless test)")
	}

	client_initialize(c, "file:///tmp/proj", proc(user: rawptr) {
		s := (^Corr_Sync)(user)
		sync.mutex_lock(&s.mu)
		s.init_done = true
		sync.mutex_unlock(&s.mu)
	}, &cs)

	testing.expect(t, wait_flag(&cs, proc(s: ^Corr_Sync) -> bool { return s.init_done }), "initialize timed out")
	testing.expect(t, c.initialized, "client not marked initialized")
	testing.expect(t, c.utf8_pos, "fake_lsp advertises utf-8; utf8_pos should be true")
	testing.expect(t, len(c.trigger_chars) == 1, "expected one trigger char")
	if len(c.trigger_chars) == 1 {
		testing.expect_value(t, c.trigger_chars[0], ".")
	}

	// Fire hover; assert the reply lands in OUR callback with a result.
	Hover_Params :: struct {
		text_document: Text_Document_Identifier `json:"textDocument"`,
		position:      Position                 `json:"position"`,
	}
	client_request(c, "textDocument/hover",
		Hover_Params{{"file:///tmp/proj/a.go"}, {0, 0}},
		proc(result: json.Value, is_error: bool, user: rawptr) {
			s := (^Corr_Sync)(user)
			sync.mutex_lock(&s.mu)
			s.hover_done = true
			_, is_obj := result.(json.Object)
			s.hover_has_result = !is_error && is_obj
			sync.mutex_unlock(&s.mu)
		}, &cs)

	testing.expect(t, wait_flag(&cs, proc(s: ^Corr_Sync) -> bool { return s.hover_done }), "hover timed out")
	testing.expect(t, cs.hover_has_result, "hover callback got no object result")

	client_shutdown(c)
}

// lsp-servers.conf parser (FLATPAK.md §3): comments, blank lines, spaces in
// the command, and a missing key.
@(test)
test_registry_lookup :: proc(t: ^testing.T) {
	conf := "# bundled servers\n\nodin = ols\nmarkdown=marksman --stdio\n  # comment\n"
	odin, ok1 := registry_lookup(conf, "odin")
	testing.expect(t, ok1, "odin key should match")
	testing.expect(t, len(odin) == 1 && odin[0] == "ols", "odin -> ols")
	delete(odin)

	md, ok2 := registry_lookup(conf, "markdown")
	testing.expect(t, ok2 && len(md) == 2 && md[0] == "marksman" && md[1] == "--stdio", "markdown -> marksman --stdio (split on spaces)")
	delete(md)

	_, ok3 := registry_lookup(conf, "python3")
	testing.expect(t, !ok3, "missing key -> ok=false")
}

@(private = "file")
wait_flag :: proc(cs: ^Corr_Sync, pred: proc(s: ^Corr_Sync) -> bool) -> bool {
	for _ in 0 ..< 200 { // up to ~5 s
		sync.mutex_lock(&cs.mu)
		done := pred(cs)
		sync.mutex_unlock(&cs.mu)
		if done do return true
		time.sleep(25 * time.Millisecond)
	}
	return false
}
