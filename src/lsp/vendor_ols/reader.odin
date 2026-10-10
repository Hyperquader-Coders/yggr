package ols_lsp

// Adapted from OLS (github.com/DanielGavin/ols), MIT — see THIRD_PARTY.md
//
// Byte-wise reader abstraction over a caller-supplied read function. Headers
// are read a byte at a time up to a delimiter; bodies are read in bulk via
// read_sized. This replaces the equivalent framing-read scaffold that used to
// live in src/lsp/transport.odin (see THIRD_PARTY.md). Only unused imports and
// server-only helpers were dropped; the read logic is unchanged from upstream.

import "core:strings"

// (read, err_code): err_code == 0 means success. read == 0 with err_code == 0
// is treated as EOF by the framing layer.
ReaderFn :: proc(_: rawptr, _: []byte) -> (int, int)

Reader :: struct {
	reader_fn:      ReaderFn,
	reader_context: rawptr,
}

make_reader :: proc(reader_fn: ReaderFn, reader_context: rawptr) -> Reader {
	return Reader{reader_context = reader_context, reader_fn = reader_fn}
}

read_u8 :: proc(reader: ^Reader) -> (u8, bool) {
	value: [1]byte

	read, err := reader.reader_fn(reader.reader_context, value[:])

	if (err != 0 || read != 1) {
		return 0, false
	}

	return value[0], true
}

read_until_delimiter :: proc(reader: ^Reader, delimiter: u8, builder: ^strings.Builder) -> bool {
	for true {
		value, success := read_u8(reader)

		if (!success) {
			return false
		}

		strings.write_byte(builder, value)

		if (value == delimiter) {
			break
		}
	}

	return true
}

read_sized :: proc(reader: ^Reader, data: []u8) -> (ok: bool) {
	ok = true
	size := len(data)
	n := 0

	for n < size && ok {
		read: int
		err_code: int

		read, err_code = reader.reader_fn(reader.reader_context, data[n:])

		ok = err_code == 0

		n += read
	}

	if n >= size {
		ok = true
	}

	return
}
