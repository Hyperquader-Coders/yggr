// amber-json's own: unmarshal with a Report, as amber-toml's toml/unmarshal.odin does it (same
// author; its walk, range, len, one_of, enum and bit_set checks are copied and changed where
// JSON differs). The document is parsed once, into a tree with positions in a scratch arena, and
// only a document that parses is walked, so nothing is written to the struct for a document that
// is not JSON.

package json

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:mem/virtual"
import "core:reflect"
import "core:strings"
import "core:unicode/utf8"

// How unmarshal reads the document, and what it does with what the struct does not describe.
Options :: struct {
	unknown:   Unknown_Policy, // keys the struct does not name; nested objects inherit it
	spec:      Specification,  // .JSON unless asked
	max_depth: int,            // 0 is DEFAULT_MAX_DEPTH
}

// unmarshal_report fills the struct at `ptr` from the document `data` and adds what is wrong to
// `r`, each issue naming the JSON path of the value and the line and column it was written at.
// It is amber-toml's unmarshal for JSON; core's unmarshal and unmarshal_string, which stop at the
// first error, keep core's signatures.
//
// The struct is the schema: a field takes the key of its name or of its `json:"name"` tag, and
// its tags say what it requires — see docs/VALIDATION.md. A field the object has no key for keeps
// its value, so a struct set to its defaults comes out with what the document changed. After an
// Error the field keeps its value and unmarshal goes on, unless the report stops at the first.
// `null` goes only into a Maybe, a pointer, a union with a nil state and a Value; into anything
// else it is an Error, never a silent zero. True when it added no Error; Warnings allowed.
//
// A document that does not parse is one Parse Error at the line and column where it stopped, and
// nothing in the struct is written. It fills strings, integers and floats of every size, bools,
// enums from their words or their values, bit_sets from arrays of words or from their bits,
// nested structs, `using _: T` fields from the same object, slices, dynamic and fixed arrays,
// maps with string keys, pointers, Maybe and other unions (the first variant the value fills
// without an Error), a Source field with where the struct came from, and a Value field with the
// value as parse would give it.
//
// Every string, slice, dynamic array, map, pointer and Value it writes is allocated with
// `allocator` and belongs to the caller; after an Error some of it is out of the struct's reach,
// so give it an arena.
unmarshal_report :: proc(data: []byte, ptr: ^$T, r: ^Report, allocator := context.allocator, options := Options{}) -> bool where intrinsics.type_is_struct(T) {
	return unmarshal_document(string(data), ptr, type_info_of(T), r, allocator, options)
}

unmarshal_report_string :: proc(data: string, ptr: ^$T, r: ^Report, allocator := context.allocator, options := Options{}) -> bool where intrinsics.type_is_struct(T) {
	return unmarshal_document(data, ptr, type_info_of(T), r, allocator, options)
}

// The body of unmarshal_report, not polymorphic, so the checker reads it whether or not anything
// in the package calls it.
@(private)
unmarshal_document :: proc(data: string, ptr: rawptr, ti: ^runtime.Type_Info, r: ^Report, allocator: runtime.Allocator, options: Options) -> bool {
	errors := r.errors
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		report_add(r, .Parse, .Error, {}, "", "%s", error_message(.Out_Of_Memory))
		return false
	}
	defer virtual.arena_destroy(&arena)
	max_depth := options.max_depth == 0 ? DEFAULT_MAX_DEPTH : options.max_depth
	root, err, at, detail := parse_document(data, options.spec, max_depth, virtual.arena_allocator(&arena))
	if err != nil {
		parse_issue(r, data, err, at, detail)
		return false
	}
	u := Unmarshaller{r = r, allocator = allocator, data = data}
	if root.kind != .Object {
		issue(&u, .Type_Mismatch, .Error, root.offset, nil, "the document is %s, not an object", node_kind_name(&root))
		return false
	}
	fill_struct(&u, &root, ptr, ti, nil, options.unknown)
	return r.errors == errors
}

@(private)
Unmarshaller :: struct {
	r:         ^Report,
	allocator: runtime.Allocator,
	data:      string,
}

@(private)
stopped :: proc(u: ^Unmarshaller) -> bool {
	return u.r.stop_at_error && u.r.errors > 0
}

// Adds an issue whose message is the frame's path followed by `format`: `exp` and
// ` is missing` make `claims.exp is missing`.
@(private)
issue :: proc(u: ^Unmarshaller, kind: Issue_Kind, severity: Severity, at: int, frame: ^Path_Frame, format: string, args: ..any) {
	path := frame_name(frame, context.temp_allocator)
	report_add(u.r, kind, severity, offset_position(u.data, at), path, "%s%s", path, fmt.tprintf(format, ..args))
}

// What a field is, and what it takes, for a message.
@(private)
Field :: struct {
	frame: ^Path_Frame, // the value's own path
	at:    int,         // where the value starts, or -1
	rule:  ^Field_Rule,
}

@(private)
fill_struct :: proc(u: ^Unmarshaller, n: ^Node, data: rawptr, ti: ^runtime.Type_Info, frame: ^Path_Frame, policy: Unknown_Policy) {
	known := make([dynamic]string, context.temp_allocator)
	collect_known(ti, &known)
	if frame != nil && frame.index >= 0 && frame.label == "" {
		frame.label, frame.label_key = label_of(n, ti)
	}
	if policy != .Ignore {
		for key, i in n.keys {
			if !contains(known[:], key) {
				path := frame_name(frame, context.temp_allocator)
				hint := did_you_mean(key, known[:], context.temp_allocator)
				severity: Severity = policy == .Refuse ? .Error : .Warning
				at := offset_position(u.data, n.key_offsets[i])
				member := join_path(path, key, context.temp_allocator)
				if path == "" {
					report_add(u.r, .Unknown_Key, severity, at, member, "unknown key %q%s", key, hint)
				} else {
					report_add(u.r, .Unknown_Key, severity, at, member, "%s: unknown key %q%s", path, key, hint)
				}
				if stopped(u) do return
			}
		}
	}
	fill_fields(u, n, data, ti, frame, policy)
}

@(private)
fill_fields :: proc(u: ^Unmarshaller, n: ^Node, data: rawptr, ti: ^runtime.Type_Info, frame: ^Path_Frame, policy: Unknown_Policy) {
	info := runtime.type_info_base(ti).variant.(runtime.Type_Info_Struct)
	for i in 0 ..< int(info.field_count) {
		if stopped(u) do return
		ft := info.types[i]
		field := rawptr(uintptr(data) + info.offsets[i])
		if ft.id == Source {
			(^Source)(field)^ = make_source(u, n, frame)
			continue
		}
		if is_embedded(info, i) {
			fill_fields(u, n, field, ft, frame, policy)
			continue
		}
		rule := field_rule(info.names[i], info.tags[i])
		if rule.skip {
			continue
		}
		key_frame := Path_Frame{parent = frame, key = rule.name, index = -1}
		// What check_schema would say, said here too: a tag that cannot apply is otherwise a
		// rule that silently does nothing. Once, however many elements of an array share the
		// struct.
		problem := rule.bad
		if problem == "" {
			problem = rule_misfit(&rule, ft)
		}
		if problem != "" {
			message := fmt.tprintf("%s: %s", info.names[i], problem)
			if !reported(u.r, .Bad_Tag, message) {
				report_add(u.r, .Bad_Tag, .Error, {}, frame_name(&key_frame, context.temp_allocator), "%s", message)
			}
			continue
		}
		j := node_find(n, rule.name)
		if j < 0 {
			if rule.required {
				issue(u, .Missing_Key, .Error, n.offset, &key_frame, " is missing")
			}
			continue
		}
		f := Field{frame = &key_frame, at = n.items[j].offset, rule = &rule}
		fill(u, &n.items[j], field, ft, &f, rule.unknown.? or_else policy)
	}
}

// The keys a struct names, through its `using _` fields.
@(private)
collect_known :: proc(ti: ^runtime.Type_Info, known: ^[dynamic]string) {
	info := runtime.type_info_base(ti).variant.(runtime.Type_Info_Struct)
	for i in 0 ..< int(info.field_count) {
		if info.types[i].id == Source {
			continue
		}
		if is_embedded(info, i) {
			collect_known(info.types[i], known)
			continue
		}
		rule := field_rule(info.names[i], info.tags[i])
		if !rule.skip {
			append(known, rule.name)
		}
	}
}

// The value of the struct's `label` field, when the object has it, and its key: what names this
// item of an array in an issue.
@(private)
label_of :: proc(n: ^Node, ti: ^runtime.Type_Info) -> (label, key: string) {
	info := runtime.type_info_base(ti).variant.(runtime.Type_Info_Struct)
	for i in 0 ..< int(info.field_count) {
		rule := field_rule(info.names[i], info.tags[i])
		if rule.label && !rule.skip {
			if j := node_find(n, rule.name); j >= 0 && n.items[j].kind == .String {
				return n.items[j].text, rule.name
			}
		}
	}
	return "", ""
}

@(private)
make_source :: proc(u: ^Unmarshaller, n: ^Node, frame: ^Path_Frame) -> Source {
	src := Source{
		name      = frame_name(frame, u.allocator),
		position  = offset_position(u.data, n.offset),
		keys      = make([]string, len(n.keys), u.allocator),
		positions = make([]Position, len(n.keys), u.allocator),
	}
	for key, i in n.keys {
		src.keys[i] = strings.clone(key, u.allocator)
		src.positions[i] = offset_position(u.data, n.key_offsets[i])
	}
	return src
}

@(private)
contains :: proc(list: []string, s: string) -> bool {
	for x in list {
		if x == s {
			return true
		}
	}
	return false
}

@(private)
mismatch :: proc(u: ^Unmarshaller, n: ^Node, f: ^Field, want: string) -> bool {
	issue(u, .Type_Mismatch, .Error, f.at, f.frame, " is %s, not %s", node_kind_name(n), want)
	return false
}

// What a field of type `ti` takes, for a message.
@(private)
wanted :: proc(ti: ^runtime.Type_Info) -> string {
	if ti.id == Value || ti.id == Raw {
		return "a value"
	}
	#partial switch info in runtime.type_info_base(ti).variant {
	case runtime.Type_Info_String:  return "a string"
	case runtime.Type_Info_Boolean: return "a boolean"
	case runtime.Type_Info_Integer: return "an integer"
	case runtime.Type_Info_Float:   return "a number"
	case runtime.Type_Info_Enum:    return "a string or an integer"
	case runtime.Type_Info_Bit_Set: return "an array of words"
	case runtime.Type_Info_Struct, runtime.Type_Info_Map:
		return "an object"
	case runtime.Type_Info_Slice, runtime.Type_Info_Dynamic_Array, runtime.Type_Info_Array:
		return "an array"
	case runtime.Type_Info_Pointer:
		if info.elem != nil {
			return wanted(info.elem)
		}
	case runtime.Type_Info_Union:
		words := make([dynamic]string, context.temp_allocator)
		for v in info.variants {
			w := wanted(v)
			if !contains(words[:], w) {
				append(&words, w)
			}
		}
		return strings.join(words[:], " or ", context.temp_allocator)
	}
	return "a value unmarshal fills"
}

// One value into the field at `data` of type `ti`. False when it was not set, which is also
// when an issue was added.
@(private)
fill :: proc(u: ^Unmarshaller, n: ^Node, data: rawptr, ti: ^runtime.Type_Info, f: ^Field, policy: Unknown_Policy) -> bool {
	if ti.id == Value {
		// A key whose type the program decides, as parse would give it.
		(^Value)(data)^ = node_to_value(n, u.allocator)
		return true
	}
	if ti.id == Raw {
		// The value's text as written; parse has already checked it, duplicate keys included.
		(^Raw)(data)^ = Raw(strings.clone(u.data[n.offset:n.end], u.allocator))
		return true
	}
	base := runtime.type_info_base(ti)
	if n.kind == .Null {
		// null is "nothing" only where the field can hold nothing. Anywhere else a zero would be
		// a value the document never said: `"exp": null` is not an expiry of 1970.
		#partial switch info in base.variant {
		case runtime.Type_Info_Union:
			if !info.no_nil {
				mem.zero(data, ti.size)
				return true
			}
		case runtime.Type_Info_Pointer:
			(^rawptr)(data)^ = nil
			return true
		}
		return mismatch(u, n, f, wanted(ti))
	}
	#partial switch info in base.variant {
	case runtime.Type_Info_String:
		if n.kind != .String || info.is_cstring || info.encoding != .UTF_8 {
			if n.kind == .String do return unsupported(u, ti, f)
			return mismatch(u, n, f, "a string")
		}
		s := n.text
		if !check_len(u, f, utf8.rune_count_in_string(s), "characters") do return false
		if f.rule.one_of != nil && !contains(f.rule.one_of, s) {
			issue(u, .Unknown_Enum, .Error, f.at, f.frame, " %q is not one of (%s)%s", s,
				strings.join(f.rule.one_of, ", ", context.temp_allocator), did_you_mean(s, f.rule.one_of, context.temp_allocator))
			return false
		}
		(^string)(data)^ = strings.clone(s, u.allocator)
	case runtime.Type_Info_Boolean:
		if n.kind != .True && n.kind != .False do return mismatch(u, n, f, "a boolean")
		write_bool(data, base.size, n.kind == .True)
	case runtime.Type_Info_Integer:
		neg, mag := read_integer(u, n, f) or_return
		check_int_range(u, f, &neg, &mag) or_return
		if !integer_fits(neg, mag, 8 * base.size, info.signed) {
			issue(u, .Out_Of_Range, .Error, f.at, f.frame, " %s is not in %s", number_text(n), type_bounds(8 * base.size, info.signed))
			return false
		}
		assign_integer(any{data, ti.id}, neg, mag)
	case runtime.Type_Info_Float:
		x: f64
		#partial switch n.kind {
		case .Integer:
			neg, mag, ok := parse_integer_text(n.text)
			v, _ := number_to_float(n.text, neg, mag, ok)
			x = f64(v.(Float))
		case .Float:
			v, _ := number_to_float(n.text)
			x = f64(v.(Float))
		case .Infinity, .NaN:
			x = f64(special_float(n))
		case:
			return mismatch(u, n, f, "a number")
		}
		if !check_range(u, f, &x) do return false
		// Past what the field holds is an error, as it is for an integer, not an infinity the
		// document never wrote.
		if fits, _ := float_fits(any{data, ti.id}, x); !fits && !math.is_inf(x) {
			issue(u, .Out_Of_Range, .Error, f.at, f.frame, " %s is past what a %d-bit float holds", number_text(n), base.size * 8)
			return false
		}
		if !assign_float(any{data, ti.id}, x) do return unsupported(u, ti, f)
	case runtime.Type_Info_Enum:
		return fill_enum(u, n, data, info, f)
	case runtime.Type_Info_Bit_Set:
		return fill_bit_set(u, n, data, base, info, f)
	case runtime.Type_Info_Struct:
		if n.kind != .Object do return mismatch(u, n, f, "an object")
		if .raw_union in info.flags do return unsupported(u, ti, f)
		errors := u.r.errors
		fill_struct(u, n, data, ti, f.frame, policy)
		return u.r.errors == errors
	case runtime.Type_Info_Slice:
		if n.kind != .Array do return mismatch(u, n, f, "an array")
		if !check_len(u, f, len(n.items), "items") do return false
		items, count, refused := fill_items(u, n, info.elem, f, policy)
		if refused do return false
		(^runtime.Raw_Slice)(data)^ = runtime.Raw_Slice{data = items, len = count}
	case runtime.Type_Info_Dynamic_Array:
		if n.kind != .Array do return mismatch(u, n, f, "an array")
		if !check_len(u, f, len(n.items), "items") do return false
		items, count, refused := fill_items(u, n, info.elem, f, policy)
		if refused do return false
		(^runtime.Raw_Dynamic_Array)(data)^ = runtime.Raw_Dynamic_Array{
			data = items, len = count, cap = count, allocator = u.allocator,
		}
	case runtime.Type_Info_Array:
		if n.kind != .Array do return mismatch(u, n, f, "an array")
		if len(n.items) != info.count {
			issue(u, .Length_Mismatch, .Error, f.at, f.frame, " has %d items, not %d", len(n.items), info.count)
			return false
		}
		// Filled in scratch and copied in whole, so a refused item leaves the array as it was.
		scratch, aerr := mem.alloc(info.count * info.elem_size, info.elem.align, context.temp_allocator)
		if aerr != nil do return unsupported(u, ti, f)
		mem.copy(scratch, data, info.count * info.elem_size)
		no_len := f.rule^
		no_len.has_len_lo, no_len.has_len_hi = false, false
		for &item, i in n.items {
			item_frame := Path_Frame{parent = f.frame, index = i}
			ef := Field{frame = &item_frame, at = item.offset, rule = &no_len}
			if !fill(u, &item, rawptr(uintptr(scratch) + uintptr(i * info.elem_size)), info.elem, &ef, policy) {
				return false
			}
		}
		mem.copy(data, scratch, info.count * info.elem_size)
	case runtime.Type_Info_Map:
		return fill_map(u, n, data, info, f, policy)
	case runtime.Type_Info_Pointer:
		if info.elem == nil do return unsupported(u, ti, f)
		// A new value, so a refused one leaves the field pointing where it did.
		p, aerr := mem.alloc(info.elem.size, info.elem.align, u.allocator)
		if aerr != nil do return unsupported(u, ti, f)
		if !fill(u, n, p, info.elem, f, policy) {
			_, of_struct := runtime.type_info_base(info.elem).variant.(runtime.Type_Info_Struct)
			if n.kind == .Object && of_struct {
				// An object keeps the keys it could read, as a struct field does.
				(^rawptr)(data)^ = p
			} else {
				mem.free(p, u.allocator)
			}
			return false
		}
		(^rawptr)(data)^ = p
	case runtime.Type_Info_Union:
		if len(info.variants) == 1 {
			return fill_maybe(u, n, data, ti, info, f, policy)
		}
		return fill_union(u, n, data, ti, info, f, policy)
	case:
		return unsupported(u, ti, f)
	}
	return true
}

// Maybe(T): the one variant, filled in scratch and set as the union's value, which also sets its
// tag. An object is set even when a key in it was refused, as a struct field is: the object is
// there, and its other keys were read. Any other value that was refused leaves it as it was.
@(private)
fill_maybe :: proc(u: ^Unmarshaller, n: ^Node, data: rawptr, ti: ^runtime.Type_Info, info: runtime.Type_Info_Union, f: ^Field, policy: Unknown_Policy) -> bool {
	variant := info.variants[0]
	scratch, aerr := mem.alloc(variant.size, variant.align, context.temp_allocator)
	if aerr != nil do return unsupported(u, ti, f)
	filled := fill(u, n, scratch, variant, f, policy)
	_, of_struct := runtime.type_info_base(variant).variant.(runtime.Type_Info_Struct)
	if !filled && !(n.kind == .Object && of_struct) do return false
	reflect.set_union_value(any{data, ti.id}, any{scratch, variant.id})
	return filled
}

// A union of several types: the first variant the value fills without an Error, tried in a
// scratch arena of its own and freed, then filled for real. So a variant that fails partway
// leaves nothing behind and writes nothing to the field: `aud` as a string or an array.
@(private)
fill_union :: proc(u: ^Unmarshaller, n: ^Node, data: rawptr, ti: ^runtime.Type_Info, info: runtime.Type_Info_Union, f: ^Field, policy: Unknown_Policy) -> bool {
	for variant in info.variants {
		if !variant_fills(u, n, variant, f, policy) {
			continue
		}
		scratch, aerr := mem.alloc(variant.size, variant.align, context.temp_allocator)
		if aerr != nil do return unsupported(u, ti, f)
		if !fill(u, n, scratch, variant, f, policy) do return false
		reflect.set_union_value(any{data, ti.id}, any{scratch, variant.id})
		return true
	}
	return mismatch(u, n, f, wanted(ti))
}

// Whether `n` fills a `variant` with no Error, found without touching the report or the
// caller's allocator.
@(private)
variant_fills :: proc(u: ^Unmarshaller, n: ^Node, variant: ^runtime.Type_Info, f: ^Field, policy: Unknown_Policy) -> bool {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		return false
	}
	defer virtual.arena_destroy(&arena)
	a := virtual.arena_allocator(&arena)
	r: Report
	report_init(&r, true, a)
	trial := Unmarshaller{r = &r, allocator = a, data = u.data}
	scratch, aerr := mem.alloc(variant.size, variant.align, a)
	if aerr != nil {
		return false
	}
	return fill(&trial, n, scratch, variant, f, policy) && r.errors == 0
}

@(private)
unsupported :: proc(u: ^Unmarshaller, ti: ^runtime.Type_Info, f: ^Field) -> bool {
	issue(u, .Unsupported_Type, .Error, f.at, f.frame, ": unmarshal does not fill a field of type %v", ti.id)
	return false
}

// The items of an array, in one allocation, and how many there are. An object item keeps the
// keys it could read, as a struct field does; any other item refused makes `refused` true, and
// the caller keeps the field as it was — a list missing an item is not the list that was written.
@(private)
fill_items :: proc(u: ^Unmarshaller, n: ^Node, elem: ^runtime.Type_Info, f: ^Field, policy: Unknown_Policy) -> (items: rawptr, count: int, refused: bool) {
	if len(n.items) == 0 {
		return nil, 0, false
	}
	aerr: mem.Allocator_Error
	items, aerr = mem.alloc(elem.size * len(n.items), elem.align, u.allocator)
	if aerr != nil {
		issue(u, .Unsupported_Type, .Error, f.at, f.frame, ": out of memory")
		return nil, 0, true
	}
	no_len := f.rule^
	no_len.has_len_lo, no_len.has_len_hi = false, false
	_, of_struct := runtime.type_info_base(elem).variant.(runtime.Type_Info_Struct)
	for &item, i in n.items {
		slot := rawptr(uintptr(items) + uintptr(i * elem.size))
		item_frame := Path_Frame{parent = f.frame, index = i}
		if item.kind == .Object && of_struct {
			fill_struct(u, &item, slot, elem, &item_frame, policy)
			if stopped(u) do break
			continue
		}
		ef := Field{frame = &item_frame, at = item.offset, rule = &no_len}
		if !fill(u, &item, slot, elem, &ef, policy) {
			refused = true
		}
		if stopped(u) do break
	}
	if refused {
		mem.free(items, u.allocator)
		return nil, 0, true
	}
	return items, len(n.items), false
}

// Every key of the object, for members a struct cannot list in advance. Each value is filled in
// scratch and copied in by the runtime's own insert.
@(private)
fill_map :: proc(u: ^Unmarshaller, n: ^Node, data: rawptr, info: runtime.Type_Info_Map, f: ^Field, policy: Unknown_Policy) -> bool {
	if n.kind != .Object do return mismatch(u, n, f, "an object")
	if !reflect.is_string(info.key) || reflect.is_cstring(info.key) {
		issue(u, .Unsupported_Type, .Error, f.at, f.frame, ": a map's keys must be strings")
		return false
	}
	if !check_len(u, f, len(n.keys), "keys") do return false
	raw := (^runtime.Raw_Map)(data)
	if raw.allocator.procedure == nil {
		raw.allocator = u.allocator
	}
	scratch, aerr := mem.alloc(info.value.size, info.value.align, context.temp_allocator)
	if aerr != nil do return false
	errors := u.r.errors
	for key, i in n.keys {
		mem.zero(scratch, info.value.size)
		entry_frame := Path_Frame{parent = f.frame, key = key, index = -1}
		entry := Field{frame = &entry_frame, at = n.items[i].offset, rule = &Field_Rule{name = key}}
		if !fill(u, &n.items[i], scratch, info.value, &entry, policy) {
			if stopped(u) do return false
			continue
		}
		// A key the map already holds keeps the key it has: the map owns that one, and a second
		// copy would be one nothing frees.
		k := key
		if slot := runtime.__dynamic_map_get(raw, info.map_info, info.map_info.key_hasher(&k, runtime.map_seed(raw^)), &k); slot != nil {
			mem.copy(slot, scratch, info.value.size)
			continue
		}
		k = strings.clone(key, u.allocator)
		runtime.__dynamic_map_set_without_hash(raw, info.map_info, &k, scratch)
	}
	return u.r.errors == errors
}

// An enum from a word, folded as enum_index says, or from an integer that is one of its values.
@(private)
fill_enum :: proc(u: ^Unmarshaller, n: ^Node, data: rawptr, info: runtime.Type_Info_Enum, f: ^Field) -> bool {
	#partial switch n.kind {
	case .String:
		i, found := enum_index(info.names, n.text)
		if !found {
			unknown_word(u, f, n.text, info.names)
			return false
		}
		assign_int(any{data, info.base.id}, i64(info.values[i]))
		return true
	case .Integer, .Float:
		// The value marshal writes without use_enum_names, and only a member's: `"alg": 7` into
		// an enum of two is not an algorithm.
		neg, mag := read_integer(u, n, f) or_return
		for value in info.values {
			if v := i128(value); (v < 0) == neg && u128(abs(v)) == mag {
				assign_int(any{data, info.base.id}, i64(value))
				return true
			}
		}
		issue(u, .Unknown_Enum, .Error, f.at, f.frame, " %s is not the value of one of (%s)", number_text(n),
			strings.join(info.names, ", ", context.temp_allocator))
		return false
	}
	return mismatch(u, n, f, "a string or an integer")
}

// An array of words into a bit_set of an enum, a word named twice noted; or the set's bits as
// one integer, as marshal writes them, with no bit outside the set.
@(private)
fill_bit_set :: proc(u: ^Unmarshaller, n: ^Node, data: rawptr, base: ^runtime.Type_Info, info: runtime.Type_Info_Bit_Set, f: ^Field) -> bool {
	if n.kind == .Integer || n.kind == .Float {
		neg, mag := read_integer(u, n, f) or_return
		width := u128(info.upper - info.lower + 1)
		if neg || !integer_fits(neg, mag, 8 * base.size, false) || (width < 128 && mag >> width != 0) {
			issue(u, .Out_Of_Range, .Error, f.at, f.frame, " %s has a bit outside the set", number_text(n))
			return false
		}
		assign_integer(any{data, base.id}, false, mag)
		return true
	}
	if n.kind != .Array do return mismatch(u, n, f, "an array of words")
	e, is_enum := runtime.type_info_base(info.elem).variant.(runtime.Type_Info_Enum)
	if !is_enum do return unsupported(u, base, f)
	bits: u64
	refused := false
	for &item, i in n.items {
		item_frame := Path_Frame{parent = f.frame, index = i}
		ef := Field{frame = &item_frame, at = item.offset, rule = f.rule}
		if item.kind != .String {
			mismatch(u, &item, &ef, "a word")
			refused = true
			continue
		}
		j, found := enum_index(e.names, item.text)
		if !found {
			unknown_word(u, &ef, item.text, e.names)
			refused = true
			continue
		}
		bit := u64(1) << u64(i64(e.values[j]) - info.lower)
		if bits & bit != 0 {
			issue(u, .Duplicate, .Warning, item.offset, f.frame, " names %q twice", item.text)
		}
		bits |= bit
	}
	// A set with a word refused is not the set that was written, so the field keeps what it
	// had, as any other refused value does.
	if refused {
		return false
	}
	switch base.size {
	case 1: (^u8)(data)^ = u8(bits)
	case 2: (^u16)(data)^ = u16(bits)
	case 4: (^u32)(data)^ = u32(bits)
	case 8: (^u64)(data)^ = bits
	}
	return true
}

// A word that names no member of the enum: the members there are, and the nearest when it
// looks like a slip.
@(private)
unknown_word :: proc(u: ^Unmarshaller, f: ^Field, s: string, names: []string) {
	issue(u, .Unknown_Enum, .Error, f.at, f.frame, " %q is not one of (%s)%s", s,
		strings.join(names, ", ", context.temp_allocator), did_you_mean(s, names, context.temp_allocator))
}

// A number as an integer: a sign and a magnitude. A whole number in any notation is one
// (`1.7e9`); a fraction is not, and neither is anything that is not a number.
@(private)
read_integer :: proc(u: ^Unmarshaller, n: ^Node, f: ^Field) -> (neg: bool, mag: u128, ok: bool) {
	#partial switch n.kind {
	case .Integer:
		neg, mag, ok = parse_integer_text(n.text)
		if !ok {
			issue(u, .Out_Of_Range, .Error, f.at, f.frame, " %s is past what any integer field holds", n.text)
		}
		return
	case .Float:
		v, _ := number_to_float(n.text)
		x := f64(v.(Float))
		if _, fract := math.modf(x); fract != 0 {
			issue(u, .Type_Mismatch, .Error, f.at, f.frame, " %s is not a whole number", n.text)
			return
		}
		if x <= -0h47E0000000000000 || x >= 0h47E0000000000000 { // ±2^127
			issue(u, .Out_Of_Range, .Error, f.at, f.frame, " %s is past what any integer field holds", n.text)
			return
		}
		neg, mag = float_to_integer(x)
		return neg, mag, true
	}
	mismatch(u, n, f, "an integer")
	return
}

// A number as it was written, for a message.
@(private)
number_text :: proc(n: ^Node) -> string {
	return n.text
}

// `-128..127`: the bounds of an integer of `bits` bits.
@(private)
type_bounds :: proc(bits: int, signed: bool) -> string {
	if signed {
		hi := (u128(1) << uint(bits - 1)) - 1
		return fmt.tprintf("-%v..%v", hi + 1, hi)
	}
	hi := bits == 128 ? max(u128) : (u128(1) << uint(bits)) - 1
	return fmt.tprintf("0..%v", hi)
}

// A number against the field's range: refused, or with clamp, moved to the bound and noted. A
// NaN is in no range.
@(private)
check_range :: proc(u: ^Unmarshaller, f: ^Field, x: ^f64) -> bool {
	r := f.rule
	if !r.has_lo && !r.has_hi {
		return true
	}
	below := r.has_lo && (x^ < r.lo || math.is_nan(x^))
	above := r.has_hi && (x^ > r.hi || math.is_nan(x^))
	if !below && !above {
		return true
	}
	span: string
	switch {
	case r.has_lo && r.has_hi: span = fmt.tprintf("in %v..%v", r.lo, r.hi)
	case r.has_lo:             span = fmt.tprintf("at least %v", r.lo)
	case:                      span = fmt.tprintf("at most %v", r.hi)
	}
	if r.clamp && !math.is_nan(x^) {
		was := x^
		x^ = below ? r.lo : r.hi
		issue(u, .Clamped, .Warning, f.at, f.frame, " %v is not %s, so %v is used", was, span, x^)
		return true
	}
	issue(u, .Out_Of_Range, .Error, f.at, f.frame, " %v is not %s", x^, span)
	return false
}

// An integer against the field's range, compared as integers: the bounds of an integer field are
// whole numbers (rule_misfit), so nothing passes through an f64 and loses its last digits.
@(private)
check_int_range :: proc(u: ^Unmarshaller, f: ^Field, neg: ^bool, mag: ^u128) -> bool {
	r := f.rule
	if !r.has_lo && !r.has_hi {
		return true
	}
	// Past i128 is above every i64 bound.
	huge := !neg^ && mag^ > u128(max(i128))
	n: i128 = huge ? max(i128) : (neg^ ? -i128(mag^) : i128(mag^))
	below := r.has_lo && n < i128(r.lo_int)
	above := r.has_hi && n > i128(r.hi_int)
	if !below && !above {
		return true
	}
	span: string
	switch {
	case r.has_lo && r.has_hi: span = fmt.tprintf("in %d..%d", r.lo_int, r.hi_int)
	case r.has_lo:             span = fmt.tprintf("at least %d", r.lo_int)
	case:                      span = fmt.tprintf("at most %d", r.hi_int)
	}
	shown := neg^ ? fmt.tprintf("-%v", mag^) : fmt.tprintf("%v", mag^)
	if r.clamp {
		bound := below ? r.lo_int : r.hi_int
		neg^, mag^ = bound < 0, u128(abs(i128(bound)))
		issue(u, .Clamped, .Warning, f.at, f.frame, " %s is not %s, so %d is used", shown, span, bound)
		return true
	}
	issue(u, .Out_Of_Range, .Error, f.at, f.frame, " %s is not %s", shown, span)
	return false
}

@(private)
check_len :: proc(u: ^Unmarshaller, f: ^Field, count: int, what: string) -> bool {
	r := f.rule
	short := r.has_len_lo && count < r.len_lo
	long := r.has_len_hi && count > r.len_hi
	if !short && !long {
		return true
	}
	switch {
	case r.has_len_lo && r.has_len_hi:
		issue(u, .Length_Mismatch, .Error, f.at, f.frame, " has %d %s, not %d to %d", count, what, r.len_lo, r.len_hi)
	case short:
		issue(u, .Length_Mismatch, .Error, f.at, f.frame, " has %d %s, not at least %d", count, what, r.len_lo)
	case:
		issue(u, .Length_Mismatch, .Error, f.at, f.frame, " has %d %s, not at most %d", count, what, r.len_hi)
	}
	return false
}

@(private)
write_bool :: proc(data: rawptr, size: int, b: bool) {
	switch size {
	case 1: (^b8)(data)^ = b8(b)
	case 2: (^b16)(data)^ = b16(b)
	case 4: (^b32)(data)^ = b32(b)
	case 8: (^b64)(data)^ = b64(b)
	}
}
