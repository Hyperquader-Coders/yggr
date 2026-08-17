package ols_lsp

// Adapted from OLS (github.com/DanielGavin/ols), MIT — see THIRD_PARTY.md
//
// Mutex-guarded framed writer over a caller-supplied write function. This
// replaces the ad-hoc write_mu + os2.write pair that used to live in
// src/lsp/transport.odin (see THIRD_PARTY.md). Unchanged from upstream.

import "core:sync"

WriterFn :: proc(_: rawptr, _: []byte) -> (int, int)

Writer :: struct {
	writer_fn:      WriterFn,
	writer_context: rawptr,
	writer_mutex:   sync.Mutex,
}

make_writer :: proc(writer_fn: WriterFn, writer_context: rawptr) -> Writer {
	writer := Writer {
		writer_context = writer_context,
		writer_fn      = writer_fn,
	}
	return writer
}

write_sized :: proc(writer: ^Writer, data: []byte) -> bool {
	sync.mutex_lock(&writer.writer_mutex)
	defer sync.mutex_unlock(&writer.writer_mutex)

	written, err := writer.writer_fn(writer.writer_context, data)

	if (err != 0) {
		return false
	}

	return true
}
