#+test
package lsp

// Headless tests — SPEC acceptance criteria 1–3.
// Run: odin test src/lsp -out:build/lsp_test

import "base:runtime"
import "core:encoding/json"
import "core:log"
import "core:sync"
import "core:testing"
import "core:time"
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

	// Header names are case-insensitive and the value may come without a space.
	{
		data := make([dynamic]u8)
		defer delete(data)
		append(&data, "content-length:2\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n{}")
		src := Mem_Src{data = data[:]}
		r := ols.make_reader(mem_read_fn, &src)

		body, ok := read_one(&r)
		testing.expect(t, ok && body == "{}", "lower-case header, no space, Content-Type")
		delete(body)
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

// A server position becomes a byte index GTK accepts: clamped to the line and
// never inside a multi-byte character, in either encoding.
@(test)
test_character_to_byte :: proc(t: ^testing.T) {
	line := "héllo 🦀 wörld" // é = bytes 1..2, 🦀 = bytes 7..10
	testing.expect_value(t, character_to_byte(line, 1, true), 1)
	testing.expect_value(t, character_to_byte(line, 2, true), 1)  // inside é → its start
	testing.expect_value(t, character_to_byte(line, 9, true), 7)  // inside 🦀 → its start
	testing.expect_value(t, character_to_byte(line, 7, false), 11) // unit 7 is inside 🦀 (a surrogate pair) → after it
	testing.expect_value(t, character_to_byte(line, 8, false), 11)
	testing.expect_value(t, character_to_byte(line, -3, true), 0)
	testing.expect_value(t, character_to_byte(line, 999, true), len(line))
	testing.expect_value(t, character_to_byte(line, 999, false), len(line))
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

	// Inserts at the same position land in array order (LSP).
	edits3 := []Text_Edit{
		{range = {{0, 1}, {0, 1}}, new_text = "a"},
		{range = {{0, 1}, {0, 1}}, new_text = "b"},
		{range = {{0, 1}, {0, 1}}, new_text = "c"},
	}
	got3 := apply_edits_to_text("xy", edits3)
	defer delete(got3)
	testing.expect_value(t, got3, "xabcy")
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
	testing.expect(t, client_ready(c), "client not marked ready")
	testing.expect(t, c.utf8_pos, "fake_lsp advertises utf-8; utf8_pos should be true")
	testing.expect(t, c.can_hover && c.can_complete && c.can_format, "fake_lsp provides hover, completion and formatting")
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

// The reader thread frees its temp allocator after every message. Callbacks run
// on that thread and here each takes 256 KiB of temp memory, as hover
// rendering does; 400 replies would hold 100 MiB if nothing freed it. The
// arena's peak use and capacity must stay at about one message's worth.
Temp_Probe :: struct {
	mu:           sync.Mutex,
	init_done:    bool,
	replies:      int,
	default_temp: bool, // the reader thread runs on Odin's default temp allocator
	peak_used:    uint,
	peak_cap:     uint,
}

@(test)
test_reader_frees_temp_allocator :: proc(t: ^testing.T) {
	N :: 400
	PER_REPLY :: 256 * 1024

	probe := Temp_Probe{}
	c, ok := client_start([]string{"python3", "scripts/fake_lsp.py"}, ".", Notification_Handler{})
	if !ok do testing.fail_now(t, "could not spawn python3 scripts/fake_lsp.py")
	client_initialize(c, "file:///tmp/proj", proc(user: rawptr) {
		p := (^Temp_Probe)(user)
		sync.mutex_lock(&p.mu)
		p.init_done = true
		sync.mutex_unlock(&p.mu)
	}, &probe)
	testing.expect(t, wait_probe(&probe, proc(p: ^Temp_Probe) -> bool { return p.init_done }), "initialize timed out")

	Hover_Params :: struct {
		text_document: Text_Document_Identifier `json:"textDocument"`,
		position:      Position                 `json:"position"`,
	}
	for _ in 0 ..< N {
		client_request(c, "textDocument/hover", Hover_Params{{"file:///tmp/proj/a.go"}, {0, 0}},
			proc(_: json.Value, _: bool, user: rawptr) {
				p := (^Temp_Probe)(user)
				buf := make([]u8, PER_REPLY, context.temp_allocator)
				for i := 0; i < len(buf); i += 4096 do buf[i] = 1
				sync.mutex_lock(&p.mu)
				defer sync.mutex_unlock(&p.mu)
				p.replies += 1
				if context.temp_allocator.procedure == runtime.default_temp_allocator_proc {
					p.default_temp = true
					arena := &(^runtime.Default_Temp_Allocator)(context.temp_allocator.data).arena
					p.peak_used = max(p.peak_used, arena.total_used)
					p.peak_cap = max(p.peak_cap, arena.total_capacity)
				}
			}, &probe)
		free_all(context.temp_allocator) // this thread's own sends
	}
	testing.expect(t, wait_probe(&probe, proc(p: ^Temp_Probe) -> bool { return p.replies == N }), "hover replies timed out")
	client_shutdown(c)

	log.infof("reader temp arena over %d replies of %d KiB: peak used %d KiB, peak capacity %d KiB",
		probe.replies, PER_REPLY / 1024, probe.peak_used / 1024, probe.peak_cap / 1024)
	testing.expect(t, probe.default_temp, "reader thread should use the default temp allocator")
	testing.expectf(t, probe.peak_used <= 2 * PER_REPLY, "temp memory accumulates: peak used %d bytes", probe.peak_used)
	testing.expectf(t, probe.peak_cap <= 8 * 1024 * 1024, "temp arena grew to %d bytes", probe.peak_cap)
}

@(private = "file")
wait_probe :: proc(p: ^Temp_Probe, pred: proc(p: ^Temp_Probe) -> bool) -> bool {
	for _ in 0 ..< 400 { // up to ~10 s
		sync.mutex_lock(&p.mu)
		done := pred(p)
		sync.mutex_unlock(&p.mu)
		if done do return true
		time.sleep(25 * time.Millisecond)
	}
	return false
}

// A server that dies is reported once through on_server_exit; a request sent
// afterwards fails at once (no SIGPIPE, no hang), and shutdown still cleans up.
Exit_Probe :: struct {
	mu:          sync.Mutex,
	exited:      bool,
	late_failed: bool,
}

@(test)
test_server_exit :: proc(t: ^testing.T) {
	probe := Exit_Probe{}
	handler := Notification_Handler{
		on_server_exit = proc(user: rawptr) {
			p := (^Exit_Probe)(user)
			sync.mutex_lock(&p.mu)
			p.exited = true
			sync.mutex_unlock(&p.mu)
		},
		user = &probe,
	}
	c, ok := client_start([]string{"python3", "-c", "pass"}, ".", handler)
	if !ok do testing.fail_now(t, "could not spawn python3")

	exited := false
	for _ in 0 ..< 200 {
		sync.mutex_lock(&probe.mu)
		exited = probe.exited
		sync.mutex_unlock(&probe.mu)
		if exited do break
		time.sleep(25 * time.Millisecond)
	}
	testing.expect(t, exited, "on_server_exit not called")
	testing.expect(t, !client_ready(c), "a server that never answered is not ready")

	id := client_request(c, "textDocument/hover", struct {}{}, proc(_: json.Value, is_error: bool, user: rawptr) {
		p := (^Exit_Probe)(user)
		sync.mutex_lock(&p.mu)
		p.late_failed = is_error
		sync.mutex_unlock(&p.mu)
	}, &probe)
	testing.expect_value(t, id, i64(0))
	testing.expect(t, probe.late_failed, "a request to a dead server resolves at once as an error")
	client_shutdown(c)
}

// Replies to server-initiated requests echo the id as sent (string or number)
// and answer workspace/configuration with one null per item.
@(test)
test_server_request_reply :: proc(t: ^testing.T) {
	Case :: struct {
		msg:   string,
		reply: string,
	}
	cases := []Case{
		{`{"id":"cfg-1","method":"workspace/configuration","params":{"items":[{},{}]}}`,
		 `{"jsonrpc":"2.0","id":"cfg-1","result":[null,null]}`},
		{`{"id":7,"method":"client/registerCapability","params":{}}`,
		 `{"jsonrpc":"2.0","id":7,"result":null}`},
		{`{"id":"a\"b","method":"window/workDoneProgress/create","params":{}}`,
		 `{"jsonrpc":"2.0","id":"a\"b","error":{"code":-32601,"message":"method not supported"}}`},
	}
	for c in cases {
		v, err := json.parse_string(c.msg, .JSON, false)
		testing.expectf(t, err == nil, "parse %s", c.msg)
		obj := v.(json.Object)
		method, _ := obj["method"].(string)
		got := server_request_reply(obj["id"], method, obj["params"])
		testing.expectf(t, got == c.reply, "want %s, got %s", c.reply, got)
		json.destroy_value(v)
	}
	free_all(context.temp_allocator)
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

// Every shape Hover.contents takes normalizes to one string, with plaintext
// set only for a MarkupContent that is not markdown.
@(test)
test_hover_contents :: proc(t: ^testing.T) {
	Case :: struct {
		json:      string,
		text:      string,
		plaintext: bool,
	}
	cases := []Case{
		{`{"contents":{"kind":"markdown","value":"**x**"}}`, "**x**", false},
		{`{"contents":{"kind":"plaintext","value":"<b>"}}`, "<b>", true},
		{`{"contents":"just *md*"}`, "just *md*", false},
		{`{"contents":{"language":"odin","value":"x :: 1"}}`, "```odin\nx :: 1\n```", false},
		// A fence longer than any backtick run in the value.
		{"{\"contents\":{\"language\":\"md\",\"value\":\"a ``` b\"}}", "````md\na ``` b\n````", false},
		// Array items are separate blocks; empty items leave no gap.
		{`{"contents":[{"language":"go","value":"f()"},"","docs"]}`, "```go\nf()\n```\n\ndocs", false},
		{`{"contents":{"kind":"markdown","value":"  \n"}}`, "", false},
		{`{"contents":[]}`, "", false},
		{`null`, "", false},
		{`{}`, "", false},
	}
	for c in cases {
		v, err := json.parse_string(c.json)
		testing.expectf(t, err == nil, "parse %s", c.json)
		text, plaintext := hover_contents(v)
		testing.expectf(t, text == c.text && plaintext == c.plaintext,
			"%s: want %q plaintext=%v, got %q plaintext=%v", c.json, c.text, c.plaintext, text, plaintext)
		delete(text)
		json.destroy_value(v)
	}
}
