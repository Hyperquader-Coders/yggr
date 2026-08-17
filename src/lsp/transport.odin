package lsp

// transport.odin — subprocess management + JSON-RPC framing over stdio.
// NO GTK. Headless-testable against scripts/fake_lsp.py.
//
// Framing (Content-Length header parse, byte-wise read, mutex-guarded framed
// write) is delegated to the vendored OLS code in src/lsp/vendor_ols
// (see THIRD_PARTY.md).
// What stays here is what OLS (a server, not a client) does not cover:
// spawning the child process and tearing it down without orphans.
//
// os2 note: the early-2026 core:os/os2 package was merged into core:os in the
// dev-2026-07 nightly, so we alias `os2 "core:os"`. See docs/TOOLCHAIN.md.

import "base:runtime"
import os2 "core:os"
import "core:sync"
import "core:time"
import ols "vendor_ols"

Transport :: struct {
	process:  os2.Process,
	stdin_w:  ^os2.File, // we write requests here (owned by ols.Writer)
	stdout_r: ^os2.File, // reader thread reads frames here (owned by ols.Reader)
	reader:   ols.Reader,
	writer:   ols.Writer,
	close_mu: sync.Mutex,
	closed:   bool,
}

Transport_Error :: enum {
	None,
	Spawn_Failed,
	Broken_Pipe,
	Bad_Header,
	EOF,
}

// Spawn `argv` (e.g. {"foundry","lsp","run","go"}) with cwd = root_dir.
transport_spawn :: proc(argv: []string, root_dir: string) -> (t: ^Transport, err: Transport_Error) {
	// Persistent transport memory lives on the process heap, never the ambient
	// context allocator: the reader thread reads through this struct and a
	// tracking/temp allocator shared across threads would race (ARCH §2).
	t = new(Transport, runtime.heap_allocator())

	stdin_r, stdin_w, e1 := os2.pipe()
	stdout_r, stdout_w, e2 := os2.pipe()
	if e1 != nil || e2 != nil {
		free(t, runtime.heap_allocator())
		return nil, .Spawn_Failed
	}

	desc := os2.Process_Desc{
		command     = argv,
		working_dir = root_dir,
		stdin       = stdin_r,
		stdout      = stdout_w,
		stderr      = os2.stderr, // let server logs flow to our stderr
	}
	p, perr := os2.process_start(desc)
	if perr != nil {
		free(t, runtime.heap_allocator())
		return nil, .Spawn_Failed
	}
	// Parent closes the child-side ends.
	os2.close(stdin_r)
	os2.close(stdout_w)

	t.process  = p
	t.stdin_w  = stdin_w
	t.stdout_r = stdout_r
	t.reader   = ols.make_reader(transport_reader_fn, stdout_r)
	t.writer   = ols.make_writer(transport_writer_fn, stdin_w)
	return t, .None
}

// ols.ReaderFn / ols.WriterFn adapters over os2 files. Return (n, err_code)
// where err_code == 0 means success; n == 0 with code 0 is EOF, which we
// surface as code 1 so the framing layer stops cleanly.
@(private)
transport_reader_fn :: proc(ctx: rawptr, buf: []byte) -> (int, int) {
	f := (^os2.File)(ctx)
	n, e := os2.read(f, buf)
	if e != nil || n == 0 {
		return n, 1
	}
	return n, 0
}

@(private)
transport_writer_fn :: proc(ctx: rawptr, buf: []byte) -> (int, int) {
	f := (^os2.File)(ctx)
	n, e := os2.write(f, buf)
	if e != nil {
		return n, 1
	}
	return n, 0
}

// Thread-safe framed write of a complete JSON body (header + body under one
// lock, via the vendored writer).
transport_write :: proc(t: ^Transport, body: []u8) -> Transport_Error {
	sync.mutex_lock(&t.close_mu)
	closed := t.closed
	sync.mutex_unlock(&t.close_mu)
	if closed do return .Broken_Pipe
	return .None if ols.write_frame(&t.writer, body) else .Broken_Pipe
}

// Blocking read of one framed message. Reader-thread only. The returned body
// is heap-allocated (context.allocator on the reader thread is pinned to the
// heap in reader_loop) and owned by the caller. Handles header split across
// reads and multiple messages per read (vendored reader is byte/stream based).
transport_read_frame :: proc(t: ^Transport) -> (body: []u8, err: Transport_Error) {
	header, ok := ols.read_and_parse_header(&t.reader)
	if !ok do return nil, .EOF
	if header.content_length <= 0 do return nil, .Bad_Header

	body = make([]u8, header.content_length)
	if !ols.read_sized(&t.reader, body) {
		delete(body)
		return nil, .EOF
	}
	return body, .None
}

// Graceful close of our write side (server sees EOF after `exit`).
transport_close_stdin :: proc(t: ^Transport) {
	sync.mutex_lock(&t.close_mu)
	defer sync.mutex_unlock(&t.close_mu)
	if !t.closed {
		t.closed = true
		os2.close(t.stdin_w)
	}
}

// Tear the child process down, escalating politeness → force (SPEC §4.1):
// 2 s grace for a clean exit, then SIGTERM (process_terminate), 1 s, then
// SIGKILL (process_kill). Caller must have already closed stdin and joined
// the reader thread. Acceptance criterion 8 depends on this being reliable.
transport_shutdown :: proc(t: ^Transport) {
	if t == nil do return

	// The server should exit on its own after `exit` + stdin EOF.
	_, werr := os2.process_wait(t.process, 2 * time.Second)
	if werr == os2.General_Error.Timeout {
		_ = os2.process_terminate(t.process) // SIGTERM
		_, werr = os2.process_wait(t.process, 1 * time.Second)
		if werr == os2.General_Error.Timeout {
			_ = os2.process_kill(t.process)  // SIGKILL
			_, _ = os2.process_wait(t.process) // reap the zombie
		}
	}
	// stdin already closed by transport_close_stdin; close our read end.
	os2.close(t.stdout_r)
}
