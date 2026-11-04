// Derived from Odin's core:encoding/json at dev-2026-08 (8412dc3), Copyright (c) 2016-2025
// Ginger Bill, under the zlib licence in third_party/odin/LICENSE.
// Altered for amber-json: floats in the fewest digits and never Infinity or NaN in JSON; strings
// and keys that are not UTF-8 refused; keys escaped as JSON strings; a Source field left out;
// a Raw written as it is, once valid; omitempty leaves out zero scalars.
// Each change is marked "amber-json:" where it is made.

package json

import "core:mem"
import "core:math"
import "core:math/bits"
import "base:runtime"
import "core:strconv"
import "core:strings"
import "core:reflect"
import "core:io"
import "core:slice"
import "core:unicode/utf8"

Marshal_Data_Error :: enum {
	None,
	Unsupported_Type,
	Invalid_UTF8,
	// amber-json: a Raw that is not one value of the output's specification.
	Invalid_Raw,
}

Marshal_Error :: union #shared_nil {
	Marshal_Data_Error,
	io.Error,
}

// careful with MJSON maps & non quotes usage as keys with whitespace will lead to bad results
Marshal_Options :: struct {
	// output based on spec
	spec: Specification,

	// Use line breaks & tabs/spaces
	pretty: bool,

	// Use spaces for indentation instead of tabs
	use_spaces: bool,

	// Given use_spaces true, use this many spaces per indent level. 0 means 4 spaces.
	spaces: int,

	// Output uint as hex in JSON5 & MJSON
	write_uint_as_hex: bool,

	// If spec is MJSON and this is true, then keys will be quoted.
	//
	// WARNING: If your keys contain whitespace and this is false, then the
	// output will be bad.
	mjson_keys_use_quotes: bool,

	// If spec is MJSON and this is true, then use '=' as delimiter between
	// keys and values, otherwise ':' is used.
	mjson_keys_use_equal_sign: bool,

	// When outputting a map, sort the output by key.
	//
	// NOTE: This will temp allocate and sort a list for each map.
	sort_maps_by_key: bool,

	// Output enum value's name instead of its underlying value.
	//
	// NOTE: If a name isn't found it'll use the underlying value.
	use_enum_names: bool,

	// Internal state
	indentation: int,
	mjson_skipped_first_braces_start: bool,
	mjson_skipped_first_braces_end: bool,
}

User_Marshaler :: #type proc(w: io.Writer, v: any, opt: ^Marshal_Options) -> Marshal_Error

Register_User_Marshaler_Error :: enum {
	None,
	No_User_Marshaler,
	Marshaler_Previously_Found,
}

// Example User Marshaler:
// Custom Marshaler for `int`
// Some_Marshaler :: proc(w: io.Writer, v: any, opt: ^json.Marshal_Options) -> json.Marshal_Error {
// 	io.write_string(w, fmt.tprintf("%b", v))
// 	return json.Marshal_Data_Error.None
// }
//
// main :: proc() {
//	// Ensure the json._user_marshaler map is initialized
//	json.set_user_marshalers(new(map[typeid]json.User_Marshaler))
//	reg_err := json.register_user_marshaler(type_info_of(int).id, Some_Marshaler)
//	assert(reg_err == .None)
//
//
// 	// Use the custom marshaler
// 	SomeType :: struct {
// 		value: int,
// 	}
//
// 	x := SomeType{42}
// 	data, marshal_err := json.marshal(x)
// 	assert(marshal_err == nil)
// 	defer delete(data)
//
// 	fmt.println("Custom output:", string(data)) // Custom output: {"value":101010}
// }

// NOTE(Jeroen): This is a pointer to prevent accidental additions
// it is prefixed with `_` rather than marked with a private attribute so that users can access it if necessary
_user_marshalers: ^map[typeid]User_Marshaler

// Sets user-defined marshalers for custom json marshaling of specific types
//
// Inputs:
// - m: A pointer to a map of typeids to User_Marshaler procs.
//
// NOTE: Must be called before using register_user_marshaler.
//
set_user_marshalers :: proc(m: ^map[typeid]User_Marshaler) {
	assert(_user_marshalers == nil, "set_user_marshalers must not be called more than once.")
	_user_marshalers = m
}

// Registers a user-defined marshaler for a specific typeid
//
// Inputs:
// - id: The typeid of the custom type.
// - formatter: The User_Marshaler function for the custom type.
//
// Returns: A Register_User_Marshaler_Error value indicating the success or failure of the operation.
//
// WARNING: set_user_marshalers must be called before using this procedure.
//
register_user_marshaler :: proc(id: typeid, marshaler: User_Marshaler) -> Register_User_Marshaler_Error {
	if _user_marshalers == nil {
		return .No_User_Marshaler
	}
	if prev, found := _user_marshalers[id]; found && prev != nil {
		return .Marshaler_Previously_Found
	}
	_user_marshalers[id] = marshaler
	return .None
}

@(require_results)
marshal :: proc(v: any, opt: Marshal_Options = {}, allocator := context.allocator, loc := #caller_location) -> (data: []byte, err: Marshal_Error) {
	b := strings.builder_make(allocator, loc)
	defer if err != nil {
		strings.builder_destroy(&b)
	}
	
	// temp guard in case we are sorting map keys, which will use temp allocations
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore = allocator == context.temp_allocator)

	opt := opt
	marshal_to_builder(&b, v, &opt) or_return
	
	if len(b.buf) != 0 {
		data = b.buf[:]
	}

	return data, nil
}

marshal_to_builder :: proc(b: ^strings.Builder, v: any, opt: ^Marshal_Options) -> Marshal_Error {
	return marshal_to_writer(strings.to_writer(b), v, opt)
}

marshal_to_writer :: proc(w: io.Writer, v: any, opt: ^Marshal_Options) -> (err: Marshal_Error) {
	if v == nil {
		io.write_string(w, "null") or_return
		return
	}

	if _user_marshalers != nil {
		marshaler := _user_marshalers[v.id]
		if marshaler != nil {
			return marshaler(w, v, opt)
		}
	}

	// amber-json: a Raw is written as it is, once parse reads it as one value: a key given twice,
	// trailing data, bad UTF-8 or JSON5 into JSON are .Invalid_Raw, never written. Empty is null.
	if v.id == Raw {
		text := string((^Raw)(v.data)^)
		if text == "" {
			io.write_string(w, "null") or_return
			return
		}
		if check(transmute([]byte)text, opt.spec) != nil {
			return .Invalid_Raw
		}
		io.write_string(w, text) or_return
		return
	}

	ti := runtime.type_info_base(type_info_of(v.id))
	a := any{v.data, ti.id}

	switch info in ti.variant {
	case runtime.Type_Info_Named:
		unreachable()

	case runtime.Type_Info_Integer:
		buf: [40]byte
		u := cast_any_int_to_u128(a)

		s: string

		// allow uints to be printed as hex
		if opt.write_uint_as_hex && (opt.spec == .JSON5 || opt.spec == .MJSON) {
			switch i in a {
			case u8, u16, u32, u64, u128:
				s = strconv.write_bits_128(buf[:], u, 16, info.signed, 8*ti.size, "0123456789abcdef", { .Prefix })

			case:
				s = strconv.write_bits_128(buf[:], u, 10, info.signed, 8*ti.size, "0123456789", nil)
			}
		} else {
			s = strconv.write_bits_128(buf[:], u, 10, info.signed, 8*ti.size, "0123456789", nil)
		}

		io.write_string(w, s) or_return


	case runtime.Type_Info_Rune:
		r := a.(rune)
		io.write_byte(w, '"')                             or_return
		io.write_escaped_rune(w, r, '"', for_json = true) or_return
		io.write_byte(w, '"')                             or_return

	case runtime.Type_Info_Float:
		switch f in a {
		case f16: write_float(w, f64(f), 32, opt.spec) or_return
		case f32: write_float(w, f64(f), 32, opt.spec) or_return
		case f64: write_float(w, f, 64, opt.spec) or_return
		case: return .Unsupported_Type
		}

	case runtime.Type_Info_Complex:
		r, i: f64
		switch z in a {
		case complex32:  r, i = f64(real(z)), f64(imag(z))
		case complex64:  r, i = f64(real(z)), f64(imag(z))
		case complex128: r, i = f64(real(z)), f64(imag(z))
		case: return .Unsupported_Type
		}

		io.write_byte(w, '[')                or_return
		write_float(w, r, 64, opt.spec)      or_return
		io.write_string(w, ", ")             or_return
		write_float(w, i, 64, opt.spec)      or_return
		io.write_byte(w, ']')                or_return

	case runtime.Type_Info_Quaternion:
		return .Unsupported_Type

	case runtime.Type_Info_String:
		switch s in a {
		case string:  write_string(w, s)         or_return
		case cstring: write_string(w, string(s)) or_return
		}

	case runtime.Type_Info_Boolean:
		val: bool
		switch b in a {
		case bool: val = bool(b)
		case b8:   val = bool(b)
		case b16:  val = bool(b)
		case b32:  val = bool(b)
		case b64:  val = bool(b)
		}
		io.write_string(w, val ? "true" : "false") or_return

	case runtime.Type_Info_Any:
		return .Unsupported_Type

	case runtime.Type_Info_Type_Id:
		return .Unsupported_Type

	case runtime.Type_Info_Pointer:
		if v.id == typeid_of(Null) {
			io.write_string(w, "null") or_return
		} else {
			return .Unsupported_Type
		}

	case runtime.Type_Info_Multi_Pointer:
		return .Unsupported_Type

	case runtime.Type_Info_Soa_Pointer:
		return .Unsupported_Type

	case runtime.Type_Info_Procedure:
		return .Unsupported_Type

	case runtime.Type_Info_Parameters:
		return .Unsupported_Type

	case runtime.Type_Info_Simd_Vector:
		return .Unsupported_Type
		
	case runtime.Type_Info_Matrix:
		return .Unsupported_Type

	case runtime.Type_Info_Bit_Field:
		return .Unsupported_Type

	case runtime.Type_Info_Array:
		opt_write_start(w, opt, '[') or_return
		for i in 0..<info.count {
			opt_write_iteration(w, opt, i == 0) or_return
			data := uintptr(v.data) + uintptr(i*info.elem_size)
			marshal_to_writer(w, any{rawptr(data), info.elem.id}, opt) or_return
		}
		opt_write_end(w, opt, ']') or_return
		
	case runtime.Type_Info_Enumerated_Array:
		index_type := reflect.type_info_base(info.index)
		enum_type := index_type.variant.(reflect.Type_Info_Enum)

		opt_write_start(w, opt, '{') or_return
		for i in 0..<info.count {
			value := cast(runtime.Type_Info_Enum_Value)i
			index, found := slice.linear_search(enum_type.values, value)
			if !found {
				continue
			}

			opt_write_iteration(w, opt, i == 0) or_return
			opt_write_key(w, opt, enum_type.names[index]) or_return
			data := uintptr(v.data) + uintptr(i*info.elem_size)
			marshal_to_writer(w, any{rawptr(data), info.elem.id}, opt) or_return
		}
		opt_write_end(w, opt, '}') or_return
		
	case runtime.Type_Info_Dynamic_Array:
		opt_write_start(w, opt, '[') or_return
		array := cast(^mem.Raw_Dynamic_Array)v.data
		for i in 0..<array.len {
			opt_write_iteration(w, opt, i == 0) or_return
			data := uintptr(array.data) + uintptr(i*info.elem_size)
			marshal_to_writer(w, any{rawptr(data), info.elem.id}, opt) or_return
		}
		opt_write_end(w, opt, ']') or_return

	case runtime.Type_Info_Fixed_Capacity_Dynamic_Array:
		opt_write_start(w, opt, '[') or_return
		len := (^int)(uintptr(v.data) + info.len_offset)^
		for i in 0..<len {
			opt_write_iteration(w, opt, i == 0) or_return
			data := uintptr(v.data) + uintptr(i*info.elem_size)
			marshal_to_writer(w, any{rawptr(data), info.elem.id}, opt) or_return
		}
		opt_write_end(w, opt, ']') or_return

	case runtime.Type_Info_Slice:
		opt_write_start(w, opt, '[') or_return
		slice := cast(^mem.Raw_Slice)v.data
		for i in 0..<slice.len {
			opt_write_iteration(w, opt, i == 0) or_return
			data := uintptr(slice.data) + uintptr(i*info.elem_size)
			marshal_to_writer(w, any{rawptr(data), info.elem.id}, opt) or_return
		}
		opt_write_end(w, opt, ']') or_return

	case runtime.Type_Info_Map:
		m := (^mem.Raw_Map)(v.data)
		opt_write_start(w, opt, '{') or_return

		if m != nil {
			if info.map_info == nil {
				return .Unsupported_Type
			}
			map_cap := uintptr(runtime.map_cap(m^))
			ks, vs, hs, _, _ := runtime.map_kvh_data_dynamic(m^, info.map_info)

			if !opt.sort_maps_by_key {
				i := 0
				for bucket_index in 0..<map_cap {
					runtime.map_hash_is_valid(hs[bucket_index]) or_continue

					opt_write_iteration(w, opt, i == 0) or_return
					i += 1

					key   := rawptr(runtime.map_cell_index_dynamic(ks, info.map_info.ks, bucket_index))
					value := rawptr(runtime.map_cell_index_dynamic(vs, info.map_info.vs, bucket_index))

					// check for string type
					{
						kv  := any{key, info.key.id}
						kti := runtime.type_info_base(type_info_of(kv.id))
						ka  := any{kv.data, kti.id}
						name: string

						#partial switch info in kti.variant {
						case runtime.Type_Info_String:
							switch s in ka {
							case string: name = s
							case cstring: name = string(s)
							}
							check_utf8(name) or_return
							opt_write_key(w, opt, name) or_return
						case runtime.Type_Info_Integer:
							buf: [40]byte
							u := cast_any_int_to_u128(ka)
							name = strconv.write_bits_128(buf[:], u, 10, info.signed, 8*kti.size, "0123456789", nil)
							
							opt_write_key(w, opt, name) or_return
						case: return .Unsupported_Type
						}
					}

					marshal_to_writer(w, any{value, info.value.id}, opt) or_return
				}
			} else {
				Entry :: struct {
					key: string,
					value: any,
				}

				// If we are sorting the map by key, then we temp alloc an array
				// and sort it, then output the result.
				sorted := make([dynamic]Entry, 0, map_cap, context.temp_allocator)
				for bucket_index in 0..<map_cap {
					runtime.map_hash_is_valid(hs[bucket_index]) or_continue

					key   := rawptr(runtime.map_cell_index_dynamic(ks, info.map_info.ks, bucket_index))
					value := rawptr(runtime.map_cell_index_dynamic(vs, info.map_info.vs, bucket_index))
					name: string

					// check for string type
					{
						kv  := any{key, info.key.id}
						kti := runtime.type_info_base(type_info_of(kv.id))
						ka  := any{kv.data, kti.id}

						#partial switch info in kti.variant {
						case runtime.Type_Info_String:
							switch s in ka {
							case string: name = s
							case cstring: name = string(s)
							}

						case: return .Unsupported_Type
						}
					}

					append(&sorted, Entry { key = name, value = any{value, info.value.id}})
				}

				slice.sort_by(sorted[:], proc(i, j: Entry) -> bool { return i.key < j.key })

				for s, i in sorted {
					check_utf8(s.key) or_return
					opt_write_iteration(w, opt, i == 0) or_return
					opt_write_key(w, opt, s.key) or_return
					marshal_to_writer(w, s.value, opt) or_return
				}
			}
		}

		opt_write_end(w, opt, '}') or_return

	case runtime.Type_Info_Struct:
		// amber-json: the zero of every scalar is empty too — 0, -0.0, false, the zero rune and an
		// enum whose value is 0 — as in Go and amber-lib's wrapper; core wrote them. A distinct
		// string (a Raw among them) is read as its core type, which core's switch missed. A struct
		// and a fixed array are never empty, as in Go.
		is_omitempty :: proc(v: any) -> bool {
			v := v
			if v == nil {
				return true
			}
			ti := runtime.type_info_core(type_info_of(v.id))
			core := any{v.data, ti.id}
			#partial switch info in ti.variant {
			case runtime.Type_Info_Integer:
				return cast_any_int_to_u128(core) == 0
			case runtime.Type_Info_Rune:
				return (^rune)(v.data)^ == 0
			case runtime.Type_Info_Float:
				switch x in core {
				case f16:   return x == 0
				case f32:   return x == 0
				case f64:   return x == 0
				case f16le: return x == 0
				case f32le: return x == 0
				case f64le: return x == 0
				case f16be: return x == 0
				case f32be: return x == 0
				case f64be: return x == 0
				}
			case runtime.Type_Info_Boolean:
				return mem.check_zero(([^]byte)(v.data)[:ti.size])
			case runtime.Type_Info_Enum:
				return cast_any_int_to_u128(any{v.data, runtime.type_info_core(info.base).id}) == 0
			case runtime.Type_Info_String:
				switch x in core {
				case string:    return x == ""
				case cstring:   return x == nil || x == ""
				case string16:  return x == ""
				case cstring16: return x == nil || x == ""
				}
			case runtime.Type_Info_Any:
				return v.(any) == nil
			case runtime.Type_Info_Type_Id:
				return v.(typeid) == nil
			case runtime.Type_Info_Pointer,
			     runtime.Type_Info_Multi_Pointer,
			     runtime.Type_Info_Procedure:
				return (^rawptr)(v.data)^ == nil
			case runtime.Type_Info_Dynamic_Array:
				return (^runtime.Raw_Dynamic_Array)(v.data).len == 0
			case runtime.Type_Info_Slice:
				return (^runtime.Raw_Slice)(v.data).len == 0
			case runtime.Type_Info_Union,
			     runtime.Type_Info_Bit_Set,
			     runtime.Type_Info_Soa_Pointer:
				return reflect.is_nil(v)
			case runtime.Type_Info_Map:
				return (^runtime.Raw_Map)(v.data).len == 0
			}
			return false
		}

		// amber-json: `first` is shared with the fields of a `using _: T` group, so a separator is
		// written only before a field that is written; core wrote one before the group itself, and
		// a group that wrote nothing left `{,"b":1}`.
		marshal_struct_fields :: proc(w: io.Writer, v: any, opt: ^Marshal_Options, first: ^bool) -> (err: Marshal_Error) {
			ti := runtime.type_info_base(type_info_of(v.id))
			info := ti.variant.(runtime.Type_Info_Struct)
			for name, i in info.names[:info.field_count] {
				omitempty := false

				json_name, extra := json_name_from_tag_value(reflect.struct_tag_get(reflect.Struct_Tag(info.tags[i]), "json"))

				if json_name == "-" {
					continue
				}

				for flag in strings.split_iterator(&extra, ",") {
					switch flag {
					case "omitempty":
						omitempty = true
					}
				}

				id := info.types[i].id
				// amber-json: a Source is where unmarshal read the struct from, not part of it.
				if id == Source {
					continue
				}
				data := rawptr(uintptr(v.data) + info.offsets[i])
				the_value := any{data, id}

				if omitempty && is_omitempty(the_value) {
					continue
				}

				// Marshal the fields of 'using _: T' fields directly into the parent struct
				if json_name == "" && info.usings[i] && name == "_" {
					marshal_struct_fields(w, the_value, opt, first) or_return
					continue
				}

				opt_write_iteration(w, opt, first^) or_return
				first^ = false

				if opt.pretty {
					comment := reflect.struct_tag_get(reflect.Struct_Tag(info.tags[i]), "jsoncomment")
					opt_write_comment(w, opt, &comment) or_return
				}

				opt_write_key(w, opt, json_name if json_name != "" else name) or_return


				marshal_to_writer(w, the_value, opt) or_return
			}
			return
		}
		
		opt_write_start(w, opt, '{') or_return
		first := true
		marshal_struct_fields(w, v, opt, &first) or_return
		opt_write_end(w, opt, '}') or_return

	case runtime.Type_Info_Union:
		if len(info.variants) == 0 || v.data == nil {
			io.write_string(w, "null") or_return
			return nil
		}

		tag_ptr := uintptr(v.data) + info.tag_offset
		tag_any := any{rawptr(tag_ptr), info.tag_type.id}

		tag: i64 = -1
		switch i in tag_any {
		case u8:   tag = i64(i)
		case i8:   tag = i64(i)
		case u16:  tag = i64(i)
		case i16:  tag = i64(i)
		case u32:  tag = i64(i)
		case i32:  tag = i64(i)
		case u64:  tag = i64(i)
		case i64:  tag = i64(i)
		case: panic("Invalid union tag type")
		}

		if !info.no_nil {
			if tag == 0 {
				io.write_string(w, "null") or_return
				return nil
			}
			tag -= 1
		}
		id := info.variants[tag].id
		return marshal_to_writer(w, any{v.data, id}, opt)

	case runtime.Type_Info_Enum:
		if !opt.use_enum_names || len(info.names) == 0 {
			return marshal_to_writer(w, any{v.data, info.base.id}, opt)
		} else {
			name, found := reflect.enum_name_from_value_any(v)
			if found {
				return marshal_to_writer(w, name, opt)
			} else {
				return marshal_to_writer(w, any{v.data, info.base.id}, opt)
			}
		}

	case runtime.Type_Info_Bit_Set:
		is_bit_set_different_endian_to_platform :: proc(ti: ^runtime.Type_Info) -> bool {
			if ti == nil {
				return false
			}
			t := runtime.type_info_base(ti)
			#partial switch info in t.variant {
			case runtime.Type_Info_Integer:
				switch info.endianness {
				case .Platform: return false
				case .Little:   return ODIN_ENDIAN != .Little
				case .Big:      return ODIN_ENDIAN != .Big
				}
			}
			return false
		}

		bit_data: u64
		bit_size := u64(8*ti.size)

		do_byte_swap := is_bit_set_different_endian_to_platform(info.underlying)

		switch bit_size {
		case  0: bit_data = 0
		case  8:
			x := (^u8)(v.data)^
			bit_data = u64(x)
		case 16:
			x := (^u16)(v.data)^
			if do_byte_swap {
				x = bits.byte_swap(x)
			}
			bit_data = u64(x)
		case 32:
			x := (^u32)(v.data)^
			if do_byte_swap {
				x = bits.byte_swap(x)
			}
			bit_data = u64(x)
		case 64:
			x := (^u64)(v.data)^
			if do_byte_swap {
				x = bits.byte_swap(x)
			}
			bit_data = u64(x)
		case: panic("unknown bit_size size")
		}
		io.write_u64(w, bit_data) or_return
	}

	return
}

// Newlines are split into multiple comment lines
opt_write_comment :: proc(w: io.Writer, opt: ^Marshal_Options, comment: ^string) -> (err: io.Error) {
	if comment^ == "" {
		return nil
	}

	switch opt.spec {
	case .JSON5, .MJSON:
		for line in strings.split_iterator(comment, "\n") {
			io.write_string(w, "// ") or_return
			io.write_string(w, line) or_return
			io.write_rune(w, '\n') or_return
			opt_write_indentation(w, opt) or_return
		}
	case .JSON: return nil
	}

	return nil
}

// write key as quoted string or with optional quotes in mjson
opt_write_key :: proc(w: io.Writer, opt: ^Marshal_Options, name: string) -> (err: io.Error)  {
	// amber-json: a key is escaped as a JSON string is (core wrote Odin's escapes, such as \x01,
	// which no JSON reader takes). The caller checks it is UTF-8.
	switch opt.spec {
	case .JSON, .JSON5:
		io.write_quoted_string(w, name, '"', nil, true) or_return
		io.write_string(w, ": " if opt.pretty else ":") or_return

	case .MJSON:
		if opt.mjson_keys_use_quotes {
			io.write_quoted_string(w, name, '"', nil, true) or_return
		} else {
			io.write_string(w, name) or_return
		}

		if opt.mjson_keys_use_equal_sign {
			io.write_string(w, " = " if opt.pretty else "=") or_return
		} else {
			io.write_string(w, ": " if opt.pretty else ":") or_return
		}
	}	

	return
}

// insert start byte and increase indentation on pretty
opt_write_start :: proc(w: io.Writer, opt: ^Marshal_Options, c: byte) -> (err: io.Error)  {
	// Skip MJSON starting braces. We make sure to only do this for c == '{',
	// skipping a starting '[' is not allowed.
	if opt.spec == .MJSON && !opt.mjson_skipped_first_braces_start && opt.indentation == 0 && c == '{' {
		opt.mjson_skipped_first_braces_start = true
		return
	}

	io.write_byte(w, c) or_return
	opt.indentation += 1

	if opt.pretty {
		io.write_byte(w, '\n') or_return
	}

	return
}

// insert comma separation and write indentations
opt_write_iteration :: proc(w: io.Writer, opt: ^Marshal_Options, first_iteration: bool) -> (err: io.Error) {
	switch opt.spec {
	case .JSON, .JSON5:
		if !first_iteration {
			io.write_byte(w, ',') or_return

			if opt.pretty {
				io.write_byte(w, '\n') or_return
			}
		}

		opt_write_indentation(w, opt) or_return

	case .MJSON:
		if !first_iteration {
			// on pretty no commas necessary
			if opt.pretty {
				io.write_byte(w, '\n') or_return
			} else {
				// comma separation necessary for non pretty output!
				io.write_byte(w, ',') or_return
			}
		}

		opt_write_indentation(w, opt) or_return
	}

	return
}

// decrease indent, write spacing and insert end byte
opt_write_end :: proc(w: io.Writer, opt: ^Marshal_Options, c: byte) -> (err: io.Error)  {
	if opt.spec == .MJSON && opt.mjson_skipped_first_braces_start && !opt.mjson_skipped_first_braces_end && opt.indentation == 0 && c == '}' {
		opt.mjson_skipped_first_braces_end = true
		return
	}

	opt.indentation -= 1

	if opt.pretty {
		io.write_byte(w, '\n') or_return
		opt_write_indentation(w, opt) or_return
	}

	io.write_byte(w, c) or_return
	return
}

// writes current indentation level based on options
opt_write_indentation :: proc(w: io.Writer, opt: ^Marshal_Options) -> (err: io.Error) {
	if !opt.pretty {
		return
	}

	if opt.use_spaces {
		spaces := opt.spaces == 0 ? 4 : opt.spaces
		for _ in 0..<opt.indentation * spaces {
			io.write_byte(w, ' ') or_return
		}
	} else {
		for _ in 0..<opt.indentation {
			io.write_byte(w, '\t') or_return
		}
	}

	return
}

@(private)
cast_any_int_to_u128 :: proc(any_int_value: any) -> u128 {
	u: u128 = 0
	switch i in any_int_value {
	case i8:      u = u128(i)
	case i16:     u = u128(i)
	case i32:     u = u128(i)
	case i64:     u = u128(i)
	case i128:    u = u128(i)
	case int:     u = u128(i)
	case u8:      u = u128(i)
	case u16:     u = u128(i)
	case u32:     u = u128(i)
	case u64:     u = u128(i)
	case u128:    u = u128(i)
	case uint:    u = u128(i)
	case uintptr: u = u128(i)

	case i16le:  u = u128(i)
	case i32le:  u = u128(i)
	case i64le:  u = u128(i)
	case u16le:  u = u128(i)
	case u32le:  u = u128(i)
	case u64le:  u = u128(i)
	case u128le: u = u128(i)

	case i16be:  u = u128(i)
	case i32be:  u = u128(i)
	case i64be:  u = u128(i)
	case u16be:  u = u128(i)
	case u32be:  u = u128(i)
	case u64be:  u = u128(i)
	case u128be: u = u128(i)
	}

	return u
}

// check_utf8 refuses a string that is not UTF-8: JSON text is. amber-json: core wrote the bad bytes as
// Odin's \xff escapes, which no JSON reader takes.
@(private)
check_utf8 :: proc(s: string) -> Marshal_Data_Error {
	return nil if utf8.valid_string(s) else .Invalid_UTF8
}

// write_string writes `s` as a JSON string.
@(private)
write_string :: proc(w: io.Writer, s: string) -> Marshal_Error {
	check_utf8(s) or_return
	io.write_quoted_string(w, s, '"', nil, true) or_return
	return nil
}

// write_float writes `f` in the fewest digits that read back as the same number at `bit_size`
// (32 for f16 and f32), in decimal from 1e-6 up to 1e21 and in exponent form outside, as
// JavaScript does; a whole number keeps a ".0" so it reads back as a float. Infinity and NaN
// are an error in JSON, which has no word for them, and JSON5's words otherwise.
//
// amber-json: core wrote sixteen decimal places (`0.1000000000000000`), so 5e-324 came back
// as 0, 1e300 took 300 digits, and infinity came out as `+Inf`.
@(private)
write_float :: proc(w: io.Writer, f: f64, bit_size: int, spec: Specification) -> Marshal_Error {
	if math.is_nan(f) || math.is_inf(f) {
		if spec == .JSON {
			return .Unsupported_Type
		}
		word := "NaN"
		if math.is_inf(f) {
			word = "Infinity" if f > 0 else "-Infinity"
		}
		io.write_string(w, word) or_return
		return nil
	}

	buf: [64]byte
	e := strconv.write_float(buf[:], f, 'e', -1, bit_size) // "+d.ddde+XX", shortest
	neg := e[0] == '-'
	e = e[1:]
	at := strings.index_byte(e, 'e')
	mantissa, exp_text := e[:at], e[at+1:]
	exp, _ := strconv.parse_int(exp_text, 10)

	if neg {
		io.write_byte(w, '-') or_return
	}
	if exp < -6 || exp >= 21 {
		io.write_string(w, mantissa) or_return
		io.write_byte(w, 'e')        or_return
		io.write_string(w, exp_text) or_return
		return nil
	}

	digits_buf: [32]byte
	n := 0
	for c in transmute([]byte)mantissa {
		if c != '.' {
			digits_buf[n] = c
			n += 1
		}
	}
	digits := string(digits_buf[:n])
	if exp < 0 {
		io.write_string(w, "0.") or_return
		for _ in 0 ..< -exp-1 {
			io.write_byte(w, '0') or_return
		}
		io.write_string(w, digits) or_return
	} else if n <= exp+1 {
		io.write_string(w, digits) or_return
		for _ in 0 ..< exp+1-n {
			io.write_byte(w, '0') or_return
		}
		io.write_string(w, ".0") or_return
	} else {
		io.write_string(w, digits[:exp+1]) or_return
		io.write_byte(w, '.')               or_return
		io.write_string(w, digits[exp+1:])  or_return
	}
	return nil
}
