// Derived from Odin's core:encoding/json at dev-2026-08 (8412dc3), Copyright (c) 2016-2025
// Ginger Bill, under the zlib licence in third_party/odin/LICENSE.
// Altered for amber-json: null only
// into what can hold nothing; enum values checked; a failed union variant leaves nothing; the
// whole document checked first; numbers only into fields that hold
// them exactly; no quoted numbers; duplicate fields seen; unknown enum names refused; integer map
// keys range-checked; a Raw field filled with its text as written.
// Each change is marked "amber-json:" where it is made.

package json

import "core:mem"
import "core:mem/virtual"
import "core:math"
import "core:reflect"
import "core:strconv"
import "core:strings"
import "base:runtime"
import "base:intrinsics"

Unmarshal_Data_Error :: enum {
	Invalid_Data,
	Invalid_Parameter,
	Non_Pointer_Parameter,
	Multiple_Use_Field,
	// amber-json: a number the field cannot hold (core truncated or wrapped it).
	Out_Of_Range,
	// amber-json: a number with a fraction, into an integer field.
	Not_Integral,
	// amber-json: null into a field that cannot hold nothing (core zeroed it, so "exp":null
	// read as 0). It goes into a union with a nil state, a pointer, a Value and an any.
	Unexpected_Null,
}

Unsupported_Type_Error :: struct {
	id:    typeid,
	token: Token,
}

Unmarshal_Error :: union {
	Error,
	Unmarshal_Data_Error,
	Unsupported_Type_Error,
}

User_Unmarshaler :: #type proc(p: ^Parser, v: any) -> Unmarshal_Error

Register_User_Unmarshaler_Error :: enum {
	None,
	No_User_Unmarshaler,
	Unmarshaler_Previously_Found,
}

// NOTE(Jeroen): This is a pointer to prevent accidental additions
// it is prefixed with `_` rather than marked with a private attribute so that users can access it if necessary
_user_unmarshalers: ^map[typeid]User_Unmarshaler

// Sets user-defined unmarshalers for custom json unmarshaling of specific types
//
// Inputs:
// - m: A pointer to a map of typeids to User_Unmarshaler procs.
//
// NOTE: Must be called before using `register_user_unmarshaler`.
//
set_user_unmarshalers :: proc(m: ^map[typeid]User_Unmarshaler) {
	assert(_user_unmarshalers == nil, "set_user_unmarshalers must not be called more than once.")
	_user_unmarshalers = m
}

/*
Registers a user-defined unmarshaler for a specific `typeid`.

WARNING: set_user_unmarshalers must be called before using this procedure.

Inputs:
- id: The `typeid` of the custom type.
- unmarshaler: The `User_Unmarshaler` function for the custom type.

Example:
	import "core:fmt"
	import "json:json"
	import "core:strconv"

	// Custom Unmarshaler for `int`
	some_unmarshaler :: proc(p: ^json.Parser, v: any) -> json.Unmarshal_Error {
		token := p.curr_token.text
		i, ok := strconv.parse_i64_of_base(token, 2)
		if !ok {
			return .Invalid_Data
		}

		(^int)(v.data)^ = int(i)

		json.advance_token(p)
		return nil
	}

	register_user_unmarshaler_example :: proc() {
		// Ensure the `json._user_unmarshalers` map is initialized.
		json.set_user_unmarshalers(new(map[typeid]json.User_Unmarshaler))
		reg_err := json.register_user_unmarshaler(typeid_of(int), some_unmarshaler)
		assert(reg_err == .None)

		data := `{"value":101010}`
		SomeType :: struct {
			value: int,
		}
		y: SomeType

		unmarshal_err := json.unmarshal(transmute([]byte)data, &y)
		fmt.println(y, unmarshal_err)
	}

Output:
	SomeType{value = 42} nil
*/
register_user_unmarshaler :: proc(id: typeid, unmarshaler: User_Unmarshaler) -> Register_User_Unmarshaler_Error {
	if _user_unmarshalers == nil {
		return .No_User_Unmarshaler
	}
	if prev, found := _user_unmarshalers[id]; found && prev != nil {
		return .Unmarshaler_Previously_Found
	}
	_user_unmarshalers[id] = unmarshaler
	return .None
}

unmarshal_any :: proc(data: []byte, v: any, spec := DEFAULT_SPECIFICATION, allocator := context.allocator, max_depth := DEFAULT_MAX_DEPTH) -> Unmarshal_Error {
	v := v
	if v == nil || v.id == nil {
		return .Invalid_Parameter
	}
	v = reflect.any_base(v)
	ti := type_info_of(v.id)
	if !reflect.is_pointer(ti) || ti.id == rawptr {
		return .Non_Pointer_Parameter
	}
	PARSE_INTEGERS :: true

	// amber-json: the whole document is parsed first, into an arena freed here, so duplicate
	// keys, trailing data, nesting past max_depth, bad strings and bad numbers are refused
	// before a field is written, with parse's error in place of .Invalid_Data, and the walk
	// below reads only valid input. Core skipped its check when any user unmarshaler was
	// registered; here it always runs.
	if err := check(data, spec, PARSE_INTEGERS, max_depth); err != nil {
		return err
	}
	p := make_parser(data, spec, PARSE_INTEGERS, allocator, max_depth)
	
	data := any{(^rawptr)(v.data)^, ti.variant.(reflect.Type_Info_Pointer).elem.id}
	if v.data == nil {
		return .Invalid_Parameter
	}
	
	context.allocator = p.allocator
	
	if p.spec == .MJSON {
		#partial switch p.curr_token.kind {
		case .Ident, .String:
			unmarshal_object(&p, data, .EOF) or_return
			if err := expect_end(&p); err != nil {
				return err
			}
			return nil
		}
	}

	unmarshal_value(&p, data) or_return
	// A user unmarshaler can stop short of its value.
	if err := expect_end(&p); err != nil {
		return err
	}
	return nil
}


// amber-json: unmarshal_report (fill.odin) is the form that collects every issue, with its path
// and line, in a Report. These two are core's, and stop at the first error.
unmarshal :: proc(data: []byte, ptr: ^$T, spec := DEFAULT_SPECIFICATION, allocator := context.allocator, max_depth := DEFAULT_MAX_DEPTH) -> Unmarshal_Error {
	return unmarshal_any(data, ptr, spec, allocator, max_depth)
}

unmarshal_string :: proc(data: string, ptr: ^$T, spec := DEFAULT_SPECIFICATION, allocator := context.allocator, max_depth := DEFAULT_MAX_DEPTH) -> Unmarshal_Error {
	return unmarshal_any(transmute([]byte)data, ptr, spec, allocator, max_depth)
}


@(private)
assign_bool :: proc(val: any, b: bool) -> bool {
	v := reflect.any_core(val)
	switch &dst in v {
	case bool: dst = bool(b)
	case b8:   dst = b8  (b)
	case b16:  dst = b16 (b)
	case b32:  dst = b32 (b)
	case b64:  dst = b64 (b)
	case: return false
	}
	return true
}
@(private)
assign_int :: proc(val: any, i: $T) -> bool {
	v := reflect.any_core(val)
	switch &dst in v {
	case i8:      dst = i8     (i)
	case i16:     dst = i16    (i)
	case i16le:   dst = i16le  (i)
	case i16be:   dst = i16be  (i)
	case i32:     dst = i32    (i)
	case i32le:   dst = i32le  (i)
	case i32be:   dst = i32be  (i)
	case i64:     dst = i64    (i)
	case i64le:   dst = i64le  (i)
	case i64be:   dst = i64be  (i)
	case i128:    dst = i128   (i)
	case i128le:  dst = i128le (i)
	case i128be:  dst = i128be (i)
	case u8:      dst = u8     (i)
	case u16:     dst = u16    (i)
	case u16le:   dst = u16le  (i)
	case u16be:   dst = u16be  (i)
	case u32:     dst = u32    (i)
	case u32le:   dst = u32le  (i)
	case u32be:   dst = u32be  (i)
	case u64:     dst = u64    (i)
	case u64le:   dst = u64le  (i)
	case u64be:   dst = u64be  (i)
	case u128:    dst = u128   (i)
	case u128le:  dst = u128le (i)
	case u128be:  dst = u128be (i)
	case int:     dst = int    (i)
	case uint:    dst = uint   (i)
	case uintptr: dst = uintptr(i)
	case:
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

		ti := type_info_of(v.id)
		if info, ok := ti.variant.(runtime.Type_Info_Bit_Set); ok {
			do_byte_swap := is_bit_set_different_endian_to_platform(info.underlying)
			switch ti.size * 8 {
			case 0: // no-op.
			case 8:
				x := (^u8)(v.data)
				x^ = u8(i)
			case 16:
				x := (^u16)(v.data)
				x^ = do_byte_swap ? intrinsics.byte_swap(u16(i)) : u16(i)
			case 32:
				x := (^u32)(v.data)
				x^ = do_byte_swap ? intrinsics.byte_swap(u32(i)) : u32(i)
			case 64:
				x := (^u64)(v.data)
				x^ = do_byte_swap ? intrinsics.byte_swap(u64(i)) : u64(i)
			case:
				panic("unknown bit_size size")
			}
			return true
		}
		return false
	}
	return true
}
@(private)
assign_float :: proc(val: any, f: $T) -> bool {
	v := reflect.any_core(val)
	switch &dst in v {
	case f16:     dst = f16  (f)
	case f16le:   dst = f16le(f)
	case f16be:   dst = f16be(f)
	case f32:     dst = f32  (f)
	case f32le:   dst = f32le(f)
	case f32be:   dst = f32be(f)
	case f64:     dst = f64  (f)
	case f64le:   dst = f64le(f)
	case f64be:   dst = f64be(f)
	
	case complex32:  dst = complex(f16(f), 0)
	case complex64:  dst = complex(f32(f), 0)
	case complex128: dst = complex(f64(f), 0)
	
	case quaternion64:  dst = quaternion(w=f16(f), x=0, y=0, z=0)
	case quaternion128: dst = quaternion(w=f32(f), x=0, y=0, z=0)
	case quaternion256: dst = quaternion(w=f64(f), x=0, y=0, z=0)
	
	case: return false
	}
	return true
}


// integer_target gives the width and signedness of the integer `val` holds: an integer, an
// enum's backing integer, or a bit_set's bits. is_int is false for anything else.
@(private)
integer_target :: proc(val: any) -> (bits: int, signed: bool, is_int: bool) {
	ti := reflect.type_info_core(type_info_of(val.id))
	#partial switch info in ti.variant {
	case reflect.Type_Info_Integer:
		return 8*ti.size, info.signed, true
	case reflect.Type_Info_Bit_Set:
		return 8*ti.size, false, ti.size > 0
	}
	return
}

// is_decimal_integer is true for an optional '-' and one or more decimal digits.
@(private)
is_decimal_integer :: proc(s: string) -> bool {
	s := s
	if len(s) > 0 && s[0] == '-' {
		s = s[1:]
	}
	if len(s) == 0 {
		return false
	}
	for c in transmute([]byte)s {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

// float_to_integer gives a whole f64 below 2^127 in magnitude as a sign and a magnitude.
// Odin's i128(f) gives -2^63 for 2^63, so a large one is built from its mantissa and exponent.
@(private)
float_to_integer :: proc(f: f64) -> (neg: bool, mag: u128) {
	neg = f < 0
	a := abs(f)
	if a < 0h4340000000000000 { // 2^53: exact as a u64
		return neg, u128(u64(a))
	}
	frac, e := math.frexp(a) // a = frac * 2^e, frac in [0.5, 1)
	m := u64(math.ldexp(frac, 53))
	return neg, u128(m) << uint(e - 53)
}

// integer_fits is true when the integer -mag (neg) or mag fits `bits` bits.
@(private)
integer_fits :: proc(neg: bool, mag: u128, bits: int, signed: bool) -> bool {
	if bits <= 0 || bits > 128 {
		return false
	}
	if !signed {
		if neg {
			return mag == 0
		}
		return bits == 128 || mag <= (u128(1) << uint(bits)) - 1
	}
	limit := u128(1) << uint(bits - 1) // -limit ..< limit
	if neg {
		return mag <= limit
	}
	return mag < limit
}

// enum_member is true unless `val` is an enum and the integer is none of its values. amber-json:
// core took any integer that fit, so `"alg": 7` went into an enum of two members.
@(private)
enum_member :: proc(val: any, neg: bool, mag: u128) -> bool {
	e, is_enum := reflect.type_info_base(type_info_of(val.id)).variant.(reflect.Type_Info_Enum)
	if !is_enum {
		return true
	}
	for value in e.values {
		if v := i128(value); (v < 0) == neg && u128(abs(v)) == mag {
			return true
		}
	}
	return false
}

// assign_integer writes an integer integer_fits has passed, through core's assign_int.
@(private)
assign_integer :: proc(val: any, neg: bool, mag: u128) {
	if neg {
		assign_int(val, -i128(mag))
	} else {
		assign_int(val, mag)
	}
}

// float_fits is true when `val` holds floats and `f` is finite in its width: 1e39 into an f32
// is an error, where core stored +Inf. is_float is false for anything else.
@(private)
float_fits :: proc(val: any, f: f64) -> (fits: bool, is_float: bool) {
	ti := reflect.type_info_core(type_info_of(val.id))
	width := 0
	#partial switch _ in ti.variant {
	case reflect.Type_Info_Float:      width = ti.size
	case reflect.Type_Info_Complex:    width = ti.size / 2
	case reflect.Type_Info_Quaternion: width = ti.size / 4
	case: return false, false
	}
	switch width {
	case 2: return !math.is_inf(f16(f)), true
	case 4: return !math.is_inf(f32(f)), true
	}
	return !math.is_inf(f), true
}

@(private)
unmarshal_string_token :: proc(p: ^Parser, val: any, token: Token, ti: ^reflect.Type_Info) -> (ok: bool, err: Error) {
	str: string
	switch {
	case token.kind == .String:
		str = unquote_string(token, p.spec, p.allocator) or_return
	case:
		str = clone_string(token.text, p.allocator) or_return
	}
	defer if !ok || (val.id != string && val.id != cstring) {
		delete(str, p.allocator)
	}

	switch &dst in val {
	case string:
		dst = str
		return true, nil
	case cstring:  
		if str == "" {
			a_err: runtime.Allocator_Error
			dst, a_err = strings.clone_to_cstring("", p.allocator)
			#partial switch a_err {
			case nil:
				// okay
			case .Out_Of_Memory:
				err = .Out_Of_Memory
			case:
				err = .Invalid_Allocator
			}
			if err != nil {
				return
			}
		} else {
			// NOTE: This is valid because 'clone_string' appends a NUL terminator
			dst = cstring(raw_data(str)) 
		}
		ok = true
		return
	case rune:
		for rne, i in str {
			if i > 0 {
				dst = {}
				return false, .Invalid_Rune
			}
			dst = rne
		}
		return true, nil
	}
	
	// amber-json: a name that is not one of the enum's is an error (core left the field as it
	// was and said nothing), and a quoted number is never read into a number field (core read
	// "1700000000" into an i64), since a string and a number are different things to whoever
	// wrote them.
	#partial switch variant in ti.variant {
	case reflect.Type_Info_Enum:
		for name, i in variant.names {
			if name == str {
				assign_int(val, variant.values[i])
				return true, nil
			}
		}
	}
	
	return false, nil
}

@(private)
unmarshal_value :: proc(p: ^Parser, v: any) -> (err: Unmarshal_Error) {
	UNSUPPORTED_TYPE := Unsupported_Type_Error{v.id, p.curr_token}
	token := p.curr_token

	if _user_unmarshalers != nil {
		unmarshaler := _user_unmarshalers[v.id]
		if unmarshaler != nil {
			return unmarshaler(p, v)
		}
	}

	v := v
	ti := reflect.type_info_base(type_info_of(v.id))
	if u, ok := ti.variant.(reflect.Type_Info_Union); ok && token.kind != .Null {
		// NOTE: If it's a union with only one variant, then treat it as that variant
		if len(u.variants) == 1 {
			variant := u.variants[0]
			v.id = variant.id
			ti = reflect.type_info_base(variant)
			if !reflect.is_pointer_internally(variant) {
				tag := any{rawptr(uintptr(v.data) + u.tag_offset), u.tag_type.id}
				assign_int(tag, 1)
			}
		} else if v.id != Value {
			// amber-json: each variant is tried first on a copy of the parser, into scratch memory
			// from an arena freed here, and only the one that fills is filled for real. Core
			// filled the field itself, so a variant that failed partway left what it allocated,
			// and its bytes, behind.
			for variant, i in u.variants {
				if !variant_unmarshals(p, variant) {
					continue
				}
				mem.zero(v.data, ti.size)
				unmarshal_value(p, any{v.data, variant.id}) or_return
				raw_tag := i
				if !u.no_nil { raw_tag += 1 }
				tag := any{rawptr(uintptr(v.data) + u.tag_offset), u.tag_type.id}
				assign_int(tag, raw_tag)
				return
			}
			return UNSUPPORTED_TYPE
		}
	}

	switch &dst in v {
	// Handle json.Value as an unknown type
	case Value:
		dst = parse_value(p) or_return
		return
	// amber-json: the value's text as written. unmarshal_any has parsed the whole document, so it
	// is one valid value and skip_value steps over exactly it.
	case Raw:
		start := token.offset
		skip_value(p)
		end := token_end_pos(p.prev_token).offset
		text, aerr := strings.clone(p.tok.data[start:end], p.allocator)
		if aerr != nil {
			return Error.Out_Of_Memory
		}
		dst = Raw(text)
		return
	}
	
	#partial switch token.kind {
	case .Null:
		advance_token(p)
		#partial switch info in ti.variant {
		case reflect.Type_Info_Union:
			if info.no_nil {
				return .Unexpected_Null
			}
		case reflect.Type_Info_Pointer, reflect.Type_Info_Multi_Pointer, reflect.Type_Info_Any:
		case:
			return .Unexpected_Null
		}
		mem.zero(v.data, ti.size)
		return
	case .False, .True:
		advance_token(p)
		if assign_bool(v, token.kind == .True) {
			return
		}
		return UNSUPPORTED_TYPE

	// amber-json: a number goes into a field only when the field holds it exactly. Core wrapped
	// an integer past the field's range (strconv's ok was ignored, and assign_int casts).
	case .Integer:
		advance_token(p)
		neg, mag, ok := parse_integer_text(token.text)
		if !ok {
			return .Out_Of_Range
		}
		if bits, signed, is_int := integer_target(v); is_int {
			if !integer_fits(neg, mag, bits, signed) || !enum_member(v, neg, mag) {
				return .Out_Of_Range
			}
			assign_integer(v, neg, mag)
			return
		}
		f := f64(mag)
		if neg {
			f = -f
		}
		if fits, is_float := float_fits(v, f); is_float {
			if !fits {
				return .Out_Of_Range
			}
			assign_float(v, f)
			return
		}
		return UNSUPPORTED_TYPE
	case .Float:
		advance_token(p)
		f, ok := strconv.parse_f64(token.text)
		if !ok || math.is_inf(f) || math.is_nan(f) {
			// JSON5's hexadecimal, when parse_integers is off.
			neg, mag, iok := parse_integer_text(token.text)
			if !iok {
				return .Out_Of_Range
			}
			f = f64(mag)
			if neg {
				f = -f
			}
		}
		if fits, is_float := float_fits(v, f); is_float {
			if !fits {
				return .Out_Of_Range
			}
			assign_float(v, f)
			return
		}
		// Into an integer field, only a whole number: 1.7e9 and 1700000000.0 are 1700000000,
		// and 1700000300.5 is an error. A NumericDate that may have a fraction goes into f64.
		if bits, signed, is_int := integer_target(v); is_int {
			if _, fract := math.modf(f); fract != 0 {
				return .Not_Integral
			}
			if f <= -0h47E0000000000000 || f >= 0h47E0000000000000 { // ±2^127
				return .Out_Of_Range
			}
			neg, mag := float_to_integer(f)
			if !integer_fits(neg, mag, bits, signed) || !enum_member(v, neg, mag) {
				return .Out_Of_Range
			}
			assign_integer(v, neg, mag)
			return
		}
		return UNSUPPORTED_TYPE
		
	case .Ident:
		advance_token(p)
		if p.spec == .MJSON {
			if unmarshal_string_token(p, any{v.data, ti.id}, token, ti) or_return {
				return nil
			}
		}
		return UNSUPPORTED_TYPE
		
	case .String:
		advance_token(p)
		if unmarshal_string_token(p, any{v.data, ti.id}, token, ti) or_return {
			return nil
		}
		return UNSUPPORTED_TYPE

	case .Open_Brace:
		return unmarshal_object(p, v, .Close_Brace)

	case .Open_Bracket:
		return unmarshal_array(p, v)

	case:
		if p.spec != .JSON {
			#partial switch token.kind {
			case .Infinity:
				advance_token(p)
				f: f64 = 0h7ff0000000000000
				if token.text[0] == '-' {
					f = 0hfff0000000000000
				}
				if assign_float(v, f) {
					return
				}
				return UNSUPPORTED_TYPE
			case .NaN:
				advance_token(p)
				f: f64 = 0h7ff7ffffffffffff
				if token.text[0] == '-' {
					f = 0hfff7ffffffffffff
				}
				if assign_float(v, f) {
					return
				}
				return UNSUPPORTED_TYPE
			}
		}
	}

	advance_token(p)
	return UNSUPPORTED_TYPE
}


// variant_unmarshals is true when the value at the parser fills `variant` without an error,
// found on a copy of the parser and into an arena freed before it returns.
@(private)
variant_unmarshals :: proc(p: ^Parser, variant: ^reflect.Type_Info) -> bool {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		return false
	}
	defer virtual.arena_destroy(&arena)
	a := virtual.arena_allocator(&arena)
	scratch, aerr := mem.alloc(variant.size, variant.align, a)
	if aerr != nil {
		return false
	}
	trial := p^
	trial.allocator = a
	context.allocator = a
	return unmarshal_value(&trial, any{scratch, variant.id}) == nil
}

@(private)
unmarshal_expect_token :: proc(p: ^Parser, kind: Token_Kind, loc := #caller_location) -> Token {
	prev := p.curr_token
	err := expect_token(p, kind)
	assert(err == nil, "unmarshal_expect_token")
	return prev
}

// Struct tags can include not only the name of the JSON key, but also a tag such as `omitempty`.
// Example: `json:"key_name,omitempty"`
// This returns the first field as `json_name`, and the rest are returned as `extra`.
@(private)
json_name_from_tag_value :: proc(value: string) -> (json_name, extra: string) {
	json_name = value
	if comma_index := strings.index_byte(json_name, ','); comma_index >= 0 {
		json_name = json_name[:comma_index]
		extra = value[1 + comma_index:]
	}
	return
}


@(private)
unmarshal_object :: proc(p: ^Parser, v: any, end_token: Token_Kind) -> (err: Unmarshal_Error) {
	UNSUPPORTED_TYPE := Unsupported_Type_Error{v.id, p.curr_token}
	
	if end_token == .Close_Brace {
		unmarshal_expect_token(p, .Open_Brace)
	}

	v := v
	ti := reflect.type_info_base(type_info_of(v.id))
	
	#partial switch t in ti.variant {
	case reflect.Type_Info_Struct:
		if .raw_union in t.flags {
			return UNSUPPORTED_TYPE
		}

		fields := reflect.struct_fields_zipped(ti.id)

		// One bit per byte offset of the struct, set as each field is filled. amber-json: core
		// zeroed this for every key and set `offset&7` rather than a bit, so it never saw a field
		// twice. The parse before the walk refuses duplicate keys already; this stays for a key
		// that reaches a field by two names.
		field_used_bytes := (reflect.size_of_typeid(ti.id)+7)/8
		field_used := ([^]byte)(intrinsics.alloca(field_used_bytes + 1, 1)) // + 1 to not overflow on size_of 0 types.
		intrinsics.mem_zero(field_used, field_used_bytes)
		
		struct_loop: for p.curr_token.kind != end_token {
			key := parse_object_key(p, p.allocator) or_return
			defer delete(key, p.allocator)
			
			unmarshal_expect_token(p, .Colon)						

			use_field_idx := -1
			
			for field, field_idx in fields {
				tag_value := reflect.struct_tag_get(field.tag, "json")
				json_name, _ := json_name_from_tag_value(tag_value)
				if key == json_name {
					use_field_idx = field_idx
					break
				}
			}
			
			if use_field_idx < 0 {
				for field, field_idx in fields {
					tag_value := reflect.struct_tag_get(field.tag, "json")
					json_name, _ := json_name_from_tag_value(tag_value)
					if json_name == "" && key == field.name {
						use_field_idx = field_idx
						break
					}
				}
			}
			
			check_children_using_fields :: proc(key: string, parent: typeid) -> (
				offset: uintptr,
				type: ^reflect.Type_Info,
				found: bool,
			) {
				for field in reflect.struct_fields_zipped(parent) {
					if field.is_using && field.name == "_" {
						offset, type, found = check_children_using_fields(key, field.type.id)
						if found {
							offset += field.offset
							return
						}
					}

					tag_value := reflect.struct_tag_get(field.tag, "json")
					json_name, _ := json_name_from_tag_value(tag_value)
					if (json_name == "" && field.name == key) || json_name == key {
						offset = field.offset
						type = field.type
						found = true
						return
					}
				}
				return
			}

			offset: uintptr
			type: ^reflect.Type_Info
			field_found: bool = use_field_idx >= 0

			if field_found {
				offset = fields[use_field_idx].offset
				type = fields[use_field_idx].type
			} else {
				offset, type, field_found = check_children_using_fields(key, ti.id)
			}

			if field_found {
				field_test :: #force_inline proc "contextless" (field_used: [^]byte, offset: uintptr) -> bool {
					bit := byte(1) << (offset&7)
					prev_set := field_used[offset/8] & bit != 0
					field_used[offset/8] |= bit
					return prev_set
				}
				// A field of size 0 shares its offset with the next one.
				if type.size > 0 && field_test(field_used, offset) {
					return .Multiple_Use_Field
				}
				
				field_ptr := rawptr(uintptr(v.data) + offset)
				field := any{field_ptr, type.id}
				unmarshal_value(p, field) or_return
					
				if parse_comma(p) {
					break struct_loop
				}
				continue struct_loop
			} else {
				// allows skipping unused struct fields
				skip_value(p)
				if parse_comma(p) {
					break struct_loop
				}
				continue struct_loop
			}
		}
		
	case reflect.Type_Info_Map:
		if !reflect.is_string(t.key) && !reflect.is_integer(t.key) {
			return UNSUPPORTED_TYPE
		}
		raw_map := (^mem.Raw_Map)(v.data)
		if raw_map.allocator.procedure == nil {
			raw_map.allocator = p.allocator
		}
		
		elem_backing := bytes_make(t.value.size, t.value.align, p.allocator) or_return
		defer delete(elem_backing, p.allocator)
		
		map_backing_value := any{raw_data(elem_backing), t.value.id}
		
		map_loop: for p.curr_token.kind != end_token {
			key, _ := parse_object_key(p, p.allocator)
			unmarshal_expect_token(p, .Colon)
			

			mem.zero_slice(elem_backing)
			if uerr := unmarshal_value(p, map_backing_value); uerr != nil {
				delete(key, p.allocator)
				return uerr
			}

			key_ptr: rawptr
			int_key: u128 // an integer key, at the key type's width

			#partial switch tk in t.key.variant {
				case runtime.Type_Info_String:
					assert(tk.encoding == .UTF_8)

					key_ptr = rawptr(&key)
					key_cstr: cstring
					if reflect.is_cstring(t.key) {
						key_cstr = cstring(raw_data(key))
						key_ptr = &key_cstr
					}
				case runtime.Type_Info_Integer:
					// amber-json: decimal digits with an optional '-', in the key type's range,
					// written at its width. Core used strconv.parse_i128, which wraps and takes
					// "+1", "0x10" and "1_0", and copied the key's bytes out of an i128, so
					// "300" into a map[u8] was 44.
					if !is_decimal_integer(key) {
						delete(key, p.allocator)
						return UNSUPPORTED_TYPE
					}
					neg, mag, ok := parse_integer_text(key)
					if !ok || !integer_fits(neg, mag, 8*t.key.size, tk.signed) {
						delete(key, p.allocator)
						return .Out_Of_Range
					}
					assign_integer(any{&int_key, t.key.id}, neg, mag)
					key_ptr = rawptr(&int_key)
				case: return UNSUPPORTED_TYPE
			}

			set_ptr := runtime.__dynamic_map_set_without_hash(raw_map, t.map_info, key_ptr, map_backing_value.data)
			if set_ptr == nil {
				delete(key, p.allocator)
			} 

			// there's no need to keep string value on the heap, since it was copied into map 
			if reflect.is_integer(t.key) {
				delete(key, p.allocator)
			}
			
			if parse_comma(p) {
				break map_loop
			}
		}
		
	case reflect.Type_Info_Enumerated_Array:
		index_type := reflect.type_info_base(t.index)
		enum_type := index_type.variant.(reflect.Type_Info_Enum)
	
		enumerated_array_loop: for p.curr_token.kind != end_token {
			key, _ := parse_object_key(p, p.allocator)
			unmarshal_expect_token(p, .Colon)
			defer delete(key, p.allocator)

			index := -1
			for name, i in enum_type.names {
				if key == name {
					index = int(enum_type.values[i] - t.min_value)
					break
				}
			}
			if index < 0 || index >= t.count {
				return UNSUPPORTED_TYPE
			}
						
			index_ptr := rawptr(uintptr(v.data) + uintptr(index*t.elem_size))
			index_any := any{index_ptr, t.elem.id}
			
			unmarshal_value(p, index_any) or_return
			
			if parse_comma(p) {
				break enumerated_array_loop
			}
		}

	case:
		return UNSUPPORTED_TYPE
	}
	
	if end_token == .Close_Brace {
		unmarshal_expect_token(p, .Close_Brace)
	}
	return
}


// skip_value steps over one value, which the parse in unmarshal_any has already checked, by its
// tokens alone. amber-json: core parsed it with a nil allocator, which threw away its keys, so a
// value skipped was never checked for anything.
@(private)
skip_value :: proc(p: ^Parser) {
	depth := 0
	for {
		#partial switch p.curr_token.kind {
		case .Open_Brace, .Open_Bracket:
			depth += 1
		case .Close_Brace, .Close_Bracket:
			depth -= 1
		case .EOF, .Invalid:
			return
		}
		advance_token(p)
		if depth <= 0 {
			return
		}
	}
}

@(private)
unmarshal_count_array :: proc(p: ^Parser) -> (length: uintptr) {
	p_backup := p^
	unmarshal_expect_token(p, .Open_Bracket)
	array_length_loop: for p.curr_token.kind != .Close_Bracket && p.curr_token.kind != .EOF {
		skip_value(p)
		length += 1
		
		if parse_comma(p) {
			break
		}
	}
	p^ = p_backup
	return
}

@(private)
unmarshal_array :: proc(p: ^Parser, v: any) -> (err: Unmarshal_Error) {
	assign_array :: proc(p: ^Parser, base: rawptr, elem: ^reflect.Type_Info, length: uintptr) -> Unmarshal_Error {
		unmarshal_expect_token(p, .Open_Bracket)
		
		for idx: uintptr = 0; p.curr_token.kind != .Close_Bracket; idx += 1 {
			assert(idx < length)
			
			elem_ptr := rawptr(uintptr(base) + idx*uintptr(elem.size))
			elem := any{elem_ptr, elem.id}
			
			unmarshal_value(p, elem) or_return
			
			if parse_comma(p) {
				break
			}	
		}
		
		unmarshal_expect_token(p, .Close_Bracket)
		
		
		return nil
	}

	UNSUPPORTED_TYPE := Unsupported_Type_Error{v.id, p.curr_token}
	
	ti := reflect.type_info_base(type_info_of(v.id))
	
	length := unmarshal_count_array(p)
	
	#partial switch t in ti.variant {
	case reflect.Type_Info_Slice:	
		raw := (^mem.Raw_Slice)(v.data)
		data := bytes_make(t.elem.size * int(length), t.elem.align, p.allocator) or_return
		raw.data = raw_data(data)
		raw.len = int(length)
			
		return assign_array(p, raw.data, t.elem, length)
		
	case reflect.Type_Info_Dynamic_Array:
		raw := (^mem.Raw_Dynamic_Array)(v.data)
		data := bytes_make(t.elem.size * int(length), t.elem.align, p.allocator) or_return
		raw.data = raw_data(data)
		raw.len = int(length)
		raw.cap = int(length)
		raw.allocator = p.allocator
		
		return assign_array(p, raw.data, t.elem, length)

	case reflect.Type_Info_Fixed_Capacity_Dynamic_Array:
		if int(length) > t.capacity {
			return UNSUPPORTED_TYPE
		}
		base_ptr := cast(uintptr)v.data
		len_ptr := base_ptr + t.len_offset
		len_val := cast(^int)len_ptr
		len_val^ = int(length)
		return assign_array(p, rawptr(base_ptr), t.elem, length)
		
	case reflect.Type_Info_Array:
		// NOTE(bill): Allow lengths which are less than the dst array
		if int(length) > t.count {
			return UNSUPPORTED_TYPE
		}
		
		return assign_array(p, v.data, t.elem, length)
		
	case reflect.Type_Info_Enumerated_Array:
		// NOTE(bill): Allow lengths which are less than the dst array
		if int(length) > t.count {
			return UNSUPPORTED_TYPE
		}
		
		return assign_array(p, v.data, t.elem, length)
		
	case reflect.Type_Info_Complex:
		// NOTE(bill): Allow lengths which are less than the dst array
		if int(length) > 2 {
			return UNSUPPORTED_TYPE
		}
	
		switch ti.id {
		case complex32:  return assign_array(p, v.data, type_info_of(f16), 2)
		case complex64:  return assign_array(p, v.data, type_info_of(f32), 2)
		case complex128: return assign_array(p, v.data, type_info_of(f64), 2)
		}
		
		return UNSUPPORTED_TYPE
		
	}
		
	return UNSUPPORTED_TYPE
}
