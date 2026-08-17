package ols_lsp

// Adapted from OLS (github.com/DanielGavin/ols), MIT — see THIRD_PARTY.md
//
// Content-Length header parsing (from server/requests.odin:read_and_parse_header)
// and the framed-write pattern (from server/response.odin:send_*). Only the
// header-parse + framed-write helpers are lifted; server request dispatch,
// the thread pool and config handling are intentionally dropped (see
// THIRD_PARTY.md). The upstream log.error calls on EOF were removed so orderly
// shutdown (a normal EOF) does not spam stderr; parse failures still return
// ok=false and the caller degrades softly.

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sync"

Header :: struct {
	content_length: int,
	content_type:   string,
}

// Reads one message header block terminated by a blank CRLF line. Returns
// ok=false on EOF or a malformed header (the framing layer treats that as
// end-of-stream). Case- and Content-Type-tolerant per LSP.
read_and_parse_header :: proc(reader: ^Reader) -> (Header, bool) {
	header: Header

	builder := strings.builder_make(context.temp_allocator)

	found_content_length := false

	for true {
		strings.builder_reset(&builder)

		if !read_until_delimiter(reader, '\n', &builder) {
			return header, false
		}

		message := strings.to_string(builder)

		if len(message) < 2 || message[len(message) - 2] != '\r' {
			return header, false
		}

		if len(message) == 2 {
			break
		}

		index := strings.last_index_byte(message, ':')

		if index == -1 {
			return header, false
		}

		header_name := message[0:index]
		header_value := message[len(header_name) + 2:len(message) - 2]

		if strings.compare(header_name, "Content-Length") == 0 {
			if len(header_value) == 0 {
				return header, false
			}

			value, ok := strconv.parse_int(header_value)

			if !ok {
				return header, false
			}

			header.content_length = value

			found_content_length = true
		} else if strings.compare(header_name, "Content-Type") == 0 {
			if len(header_value) == 0 {
				return header, false
			}
		}
	}

	return header, found_content_length
}

// Framed write of a complete JSON body: Content-Length header + body under a
// SINGLE lock so that concurrent writers (our main thread sending requests and
// the reader thread sending `initialized`/server-request replies) never
// interleave the two halves of a frame. NOTE: this deliberately holds
// writer_mutex across both writer_fn calls rather than calling write_sized
// twice (which locks per-call) — the LSP wire needs header and body contiguous.
write_frame :: proc(writer: ^Writer, body: []u8) -> bool {
	header := fmt.tprintf("Content-Length: %d\r\n\r\n", len(body))

	sync.mutex_lock(&writer.writer_mutex)
	defer sync.mutex_unlock(&writer.writer_mutex)

	if _, err := writer.writer_fn(writer.writer_context, transmute([]u8)header); err != 0 {
		return false
	}
	if _, err := writer.writer_fn(writer.writer_context, body); err != 0 {
		return false
	}
	return true
}
