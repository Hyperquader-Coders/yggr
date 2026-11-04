// Derived from Odin's core:encoding/json at dev-2026-08 (8412dc3), Copyright (c) 2016-2025
// Ginger Bill, under the zlib licence in third_party/odin/LICENSE.
// Altered for amber-json: floats and strings written as marshal writes them.
// Each change is marked "amber-json:" where it is made.

package json

import "base:runtime"
import "core:strings"
import "core:io"
import "core:slice"

Unparse_Error :: union #shared_nil {
	Marshal_Data_Error,
	io.Error,
	runtime.Allocator_Error,
}

@(require_results)
unparse :: proc(v: Value, opt: Marshal_Options = {}, allocator := context.allocator, loc := #caller_location) -> (data: string, err: Unparse_Error) {
	b := strings.builder_make(allocator, loc)
	defer if err != nil {
		strings.builder_destroy(&b)
	}

	// temp guard in case we are sorting map keys, which will use temp allocations
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore = allocator == context.temp_allocator)

	opt := opt
	unparse_to_builder(&b, v, &opt) or_return
	data = string(b.buf[:])
	return
}

@(require_results)
unparse_to_builder :: proc(b: ^strings.Builder, v: Value, opt: ^Marshal_Options) -> Unparse_Error {
	return unparse_to_writer(strings.to_writer(b), v, opt)
}

@(require_results)
unparse_to_writer :: proc(w: io.Writer, value: Value, opt: ^Marshal_Options) -> Unparse_Error {
	switch v in value {
	case nil, Null:
		io.write_string(w, "null") or_return
	case Integer:
		base := 16 if opt.write_uint_as_hex && (opt.spec == .JSON5 || opt.spec == .MJSON) else 10
		io.write_i64(w, v, base) or_return
	case Float:
		// amber-json: the fewest digits, and Infinity and NaN refused in JSON; see write_float.
		if merr := write_float(w, v, 64, opt.spec); merr != nil {
			return marshal_to_unparse_error(merr)
		}
	case Boolean:
		io.write_string(w, "true" if v else "false") or_return
	case String:
		check_utf8(v) or_return
		io.write_quoted_string(w, v, '"', nil, true) or_return
	case Array:
		opt_write_start(w, opt, '[') or_return
		for e, i in v {
			opt_write_iteration(w, opt, i == 0) or_return
			unparse_to_writer  (w, e,   opt)    or_return
		}
		opt_write_end(w, opt, ']') or_return
	case Object:
		if !opt.sort_maps_by_key {
			opt_write_start(w, opt, '{') or_return
			for first_iteration := true; key, val in v {
				check_utf8(key) or_return
				opt_write_iteration(w, opt, first_iteration) or_return
				opt_write_key      (w, opt, key)             or_return
				unparse_to_writer  (w, val, opt)             or_return
				first_iteration = false
			}
			opt_write_end(w, opt, '}') or_return
		} else {
			Map_Entry :: struct {
				key: string,
				value: Value,
			}

			entries := make([dynamic]Map_Entry, 0, len(v), context.temp_allocator) or_return
			for key, val in v {
				_, _ = append(&entries, Map_Entry{key, val})
			}

			slice.sort_by(entries[:], proc(i, j: Map_Entry) -> bool { return i.key < j.key })

			opt_write_start(w, opt, '{') or_return
			for e, i in entries {
				check_utf8(e.key) or_return
				opt_write_iteration(w, opt, i == 0)  or_return
				opt_write_key      (w, opt, e.key)   or_return
				unparse_to_writer  (w, e.value, opt) or_return
			}
			opt_write_end(w, opt, '}') or_return
		}
		return nil
	}
	return nil
}

@(private)
marshal_to_unparse_error :: proc(err: Marshal_Error) -> Unparse_Error {
	switch e in err {
	case Marshal_Data_Error: return e
	case io.Error:           return e
	}
	return nil
}
