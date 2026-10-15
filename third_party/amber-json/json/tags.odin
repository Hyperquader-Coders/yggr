// amber-json's own: struct tags as amber-toml reads them. field_rule, the enum word matching,
// nearest, edit_distance, did_you_mean, check_schema and rule_misfit are copied from
// amber-toml's toml/tags.odin (same author) and changed only where JSON differs: the tag key is
// `json`, its flags are required, label and omitempty, and an enum's words are listed as
// declared, since that is what marshal writes.

package json

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:math"
import "core:reflect"
import "core:strconv"
import "core:strings"

// What an object may hold beyond the keys a struct names.
Unknown_Policy :: enum u8 {
	Ignore,
	Warn,
	Refuse,
}

// One struct field's tags, read once: its key, what it requires. `bad` is set when a tag cannot
// be read, and says why.
@(private)
Field_Rule :: struct {
	name:                 string,
	skip:                 bool,
	required:             bool,
	label:                bool,
	omitempty:            bool,
	has_lo, has_hi:       bool,
	lo, hi:               f64,
	// The bounds as whole numbers, when they are written as one: an integer field is compared
	// with these, exactly, past where an f64 is.
	lo_is_int, hi_is_int: bool,
	lo_int, hi_int:       i64,
	clamp:                bool,
	has_len_lo:           bool,
	has_len_hi:           bool,
	len_lo, len_hi:       int,
	one_of:               []string,
	unknown:              Maybe(Unknown_Policy),
	bad:                  string,
}

// The rule for a field named `field` with tags `tags`:
//
//   json:"name,required,label,omitempty"   range:"lo,hi[,clamp]"
//   len:"lo,hi"                             unknown:"ignore|warn|refuse"
//   one_of:"a|b|c"
//
// An empty name is the field's own; `json:"-"` leaves the field out.
@(private)
field_rule :: proc(field: string, tags: string) -> (rule: Field_Rule) {
	tag := reflect.Struct_Tag(tags)
	rule.name = field
	if v, ok := reflect.struct_tag_lookup(tag, "json"); ok {
		if v == "-" {
			rule.skip = true
			return
		}
		parts := strings.split(v, ",", context.temp_allocator)
		if parts[0] != "" {
			rule.name = parts[0]
		}
		for flag in parts[1:] {
			switch flag {
			case "required":  rule.required = true
			case "label":     rule.label = true
			case "omitempty": rule.omitempty = true
			case:
				rule.bad = fmt.tprintf("json flag %q is not required, label or omitempty", flag)
				return
			}
		}
	}
	if v, ok := reflect.struct_tag_lookup(tag, "range"); ok {
		parts := strings.split(v, ",", context.temp_allocator)
		if len(parts) < 2 || len(parts) > 3 || (len(parts) == 3 && parts[2] != "clamp") {
			rule.bad = fmt.tprintf("range %q is not lo,hi or lo,hi,clamp", v)
			return
		}
		if parts[0] != "" {
			rule.lo, rule.has_lo = strconv.parse_f64(parts[0])
			if !rule.has_lo || math.is_nan(rule.lo) || math.is_inf(rule.lo) {
				rule.bad = fmt.tprintf("range %q: %q is not a number", v, parts[0])
				return
			}
			rule.lo_int, rule.lo_is_int = strconv.parse_i64(parts[0])
		}
		if parts[1] != "" {
			rule.hi, rule.has_hi = strconv.parse_f64(parts[1])
			if !rule.has_hi || math.is_nan(rule.hi) || math.is_inf(rule.hi) {
				rule.bad = fmt.tprintf("range %q: %q is not a number", v, parts[1])
				return
			}
			rule.hi_int, rule.hi_is_int = strconv.parse_i64(parts[1])
		}
		rule.clamp = len(parts) == 3
		switch {
		case !rule.has_lo && !rule.has_hi:
			rule.bad = fmt.tprintf("range %q has no bound", v)
		case rule.clamp && !(rule.has_lo && rule.has_hi):
			rule.bad = fmt.tprintf("range %q clamps, so it needs both bounds", v)
		case rule.has_lo && rule.has_hi && rule.lo > rule.hi:
			rule.bad = fmt.tprintf("range %q is empty", v)
		}
		if rule.bad != "" {
			return
		}
	}
	if v, ok := reflect.struct_tag_lookup(tag, "len"); ok {
		parts := strings.split(v, ",", context.temp_allocator)
		if len(parts) != 2 {
			rule.bad = fmt.tprintf("len %q is not lo,hi", v)
			return
		}
		if parts[0] != "" {
			rule.len_lo, rule.has_len_lo = strconv.parse_int(parts[0])
		}
		if parts[1] != "" {
			rule.len_hi, rule.has_len_hi = strconv.parse_int(parts[1])
		}
		if (parts[0] != "" && !rule.has_len_lo) || (parts[1] != "" && !rule.has_len_hi) || (!rule.has_len_lo && !rule.has_len_hi) {
			rule.bad = fmt.tprintf("len %q is not two whole numbers, one of them optional", v)
			return
		}
		if rule.has_len_lo && rule.has_len_hi && rule.len_lo > rule.len_hi {
			rule.bad = fmt.tprintf("len %q is empty", v)
			return
		}
	}
	if v, ok := reflect.struct_tag_lookup(tag, "one_of"); ok {
		if v == "" {
			rule.bad = "one_of names no word"
			return
		}
		rule.one_of = strings.split(v, "|", context.temp_allocator)
		for w in rule.one_of {
			if w == "" {
				rule.bad = fmt.tprintf("one_of %q has an empty word", v)
				return
			}
		}
	}
	if v, ok := reflect.struct_tag_lookup(tag, "unknown"); ok {
		switch v {
		case "ignore": rule.unknown = .Ignore
		case "warn":   rule.unknown = .Warn
		case "refuse": rule.unknown = .Refuse
		case:
			rule.bad = fmt.tprintf("unknown %q is not ignore, warn or refuse", v)
		}
	}
	return
}

// Whether a struct field is `using _: T`, whose fields are the struct's own keys, as core's
// marshal writes them. A `using` field with a name is an object under that name, as core
// writes it, so marshal and unmarshal agree.
@(private)
is_embedded :: proc(info: runtime.Type_Info_Struct, i: int) -> bool {
	if !info.usings[i] || info.names[i] != "_" {
		return false
	}
	_, is_struct := runtime.type_info_base(info.types[i]).variant.(runtime.Type_Info_Struct)
	return is_struct
}

// Enum words. A JSON word names a member when the two are equal with ASCII case ignored and `-`
// read as `_`: "image" is .Image, "local-read" is .Local_Read.
@(private)
fold :: proc(c: u8) -> u8 {
	switch {
	case c >= 'A' && c <= 'Z': return c + ('a' - 'A')
	case c == '-':             return '_'
	}
	return c
}

@(private)
words_equal :: proc(a, b: string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		if fold(a[i]) != fold(b[i]) {
			return false
		}
	}
	return true
}

// The member `word` names, as its index in the enum's names.
@(private)
enum_index :: proc(names: []string, word: string) -> (int, bool) {
	for name, i in names {
		if words_equal(name, word) {
			return i, true
		}
	}
	return -1, false
}

// The candidate nearest `word`, when it is near enough to be a slip rather than another word:
// one edit for every four characters, at least one, and fewer than the word has, so a
// one-letter word is never a slip for another. Folded as enum words are, so `Port` is near
// `port`.
@(private)
nearest :: proc(word: string, candidates: []string) -> (best: string, found: bool) {
	most := min(max(1, len(word) / 4), len(word) - 1)
	if most < 1 {
		return "", false
	}
	best_d := most + 1
	for c in candidates {
		if d := edit_distance(word, c, best_d); d < best_d {
			best, best_d = c, d
		}
	}
	return best, best_d <= most
}

// Edits between two words over folded bytes — an insertion, a deletion, a substitution, or two
// neighbours swapped, which is the slip a hand makes most — or `limit` once it cannot be less.
@(private)
edit_distance :: proc(a, b: string, limit: int) -> int {
	if abs(len(a) - len(b)) >= limit {
		return limit
	}
	w := len(b) + 1
	d := make([]int, (len(a) + 1) * w, context.temp_allocator)
	for j in 0 ..= len(b) {
		d[j] = j
	}
	for i in 1 ..= len(a) {
		d[i * w] = i
		row_min := i
		for j in 1 ..= len(b) {
			cost := fold(a[i - 1]) == fold(b[j - 1]) ? 0 : 1
			v := min(d[(i - 1) * w + j] + 1, d[i * w + j - 1] + 1, d[(i - 1) * w + j - 1] + cost)
			if i > 1 && j > 1 && fold(a[i - 1]) == fold(b[j - 2]) && fold(a[i - 2]) == fold(b[j - 1]) {
				v = min(v, d[(i - 2) * w + j - 2] + 1)
			}
			d[i * w + j] = v
			row_min = min(row_min, v)
		}
		if row_min >= limit {
			return limit
		}
	}
	return d[len(a) * w + len(b)]
}

// `; did you mean "port"?` when a candidate is near, else "".
@(private)
did_you_mean :: proc(word: string, candidates: []string, allocator: runtime.Allocator) -> string {
	if c, ok := nearest(word, candidates); ok {
		return fmt.aprintf("; did you mean %q?", c, allocator = allocator)
	}
	return ""
}

// check_schema reports every tag in T that cannot be read or cannot apply, through nested
// structs, arrays and maps, without a document. A tag is an unchecked string, so a consumer's
// unit test calls this: a typo in one is otherwise a rule that silently does nothing. True when
// it added nothing.
check_schema :: proc($T: typeid, r: ^Report) -> bool where intrinsics.type_is_struct(T) {
	errors := r.errors
	seen := make([dynamic]typeid, context.temp_allocator)
	check_struct(type_info_of(T), r, "", &seen)
	return r.errors == errors
}

@(private)
check_struct :: proc(ti: ^runtime.Type_Info, r: ^Report, at: string, seen: ^[dynamic]typeid) {
	for id in seen {
		if id == ti.id {
			return
		}
	}
	append(seen, ti.id)
	info := runtime.type_info_base(ti).variant.(runtime.Type_Info_Struct)
	sources := 0
	for i in 0 ..< int(info.field_count) {
		ft := info.types[i]
		if ft.id == Source {
			sources += 1
			continue
		}
		if is_embedded(info, i) {
			check_struct(ft, r, at, seen)
			continue
		}
		rule := field_rule(info.names[i], info.tags[i])
		if rule.skip {
			continue
		}
		path := at == "" ? info.names[i] : fmt.tprintf("%s.%s", at, info.names[i])
		problem := rule.bad
		if problem == "" {
			problem = rule_misfit(&rule, ft)
		}
		if problem != "" {
			report_add(r, .Bad_Tag, .Error, {}, rule.name, "%s: %s", path, problem)
		}
		check_type(ft, r, path, seen)
	}
	if sources > 1 {
		report_add(r, .Bad_Tag, .Error, {}, "", "%s: more than one Source field", at == "" ? "the struct" : at)
	}
}

// Into the types a field holds, for the structs and enums inside them.
@(private)
check_type :: proc(ti: ^runtime.Type_Info, r: ^Report, at: string, seen: ^[dynamic]typeid) {
	if ti.id == Source || ti.id == Value || ti.id == Raw {
		return
	}
	#partial switch info in runtime.type_info_base(ti).variant {
	case runtime.Type_Info_Struct:
		check_struct(ti, r, at, seen)
	case runtime.Type_Info_Slice:
		check_type(info.elem, r, at, seen)
	case runtime.Type_Info_Dynamic_Array:
		check_type(info.elem, r, at, seen)
	case runtime.Type_Info_Array:
		check_type(info.elem, r, at, seen)
	case runtime.Type_Info_Pointer:
		if info.elem != nil {
			check_type(info.elem, r, at, seen)
		}
	case runtime.Type_Info_Map:
		check_type(info.value, r, at, seen)
	case runtime.Type_Info_Union:
		for variant in info.variants {
			check_type(variant, r, at, seen)
		}
	case runtime.Type_Info_Enum:
		for name, i in info.names {
			for other in info.names[i + 1:] {
				if words_equal(name, other) {
					report_add(r, .Bad_Tag, .Error, {}, "", "%s: enum members %s and %s are the same word", at, name, other)
				}
			}
		}
	case runtime.Type_Info_Bit_Set:
		if info.elem != nil {
			check_type(info.elem, r, at, seen)
		}
	}
}

// Why a readable rule cannot apply to a field of type `ti`, or "".
@(private)
rule_misfit :: proc(rule: ^Field_Rule, ti: ^runtime.Type_Info) -> string {
	base := runtime.type_info_base(maybe_elem(ti))
	// A Raw is a value's text, not a string the document holds: its characters are not the
	// value's, so the tags that look at a string's do not apply.
	raw := maybe_elem(ti).id == Raw
	if rule.has_lo || rule.has_hi {
		elem := numeric_elem(ti)
		if !is_number(elem) {
			return "range applies to a number, or an array of numbers"
		}
		if _, is_int := runtime.type_info_base(elem).variant.(runtime.Type_Info_Integer); is_int {
			if (rule.has_lo && !rule.lo_is_int) || (rule.has_hi && !rule.hi_is_int) {
				return "range on an integer needs whole-number bounds"
			}
		}
	}
	if rule.has_len_lo || rule.has_len_hi {
		#partial switch _ in base.variant {
		case runtime.Type_Info_String, runtime.Type_Info_Slice, runtime.Type_Info_Dynamic_Array, runtime.Type_Info_Map:
			if raw {
				return "len applies to a string, an array or a map, not a Raw"
			}
		case:
			return "len applies to a string, an array or a map"
		}
	}
	if rule.one_of != nil {
		if _, is_string := runtime.type_info_base(numeric_elem(ti)).variant.(runtime.Type_Info_String); !is_string || numeric_elem(ti).id == Raw {
			return "one_of applies to a string, or an array of strings"
		}
	}
	if rule.required && maybe_elem(ti) != ti {
		return "required on a Maybe, which may be absent"
	}
	if rule.label {
		if _, is_string := base.variant.(runtime.Type_Info_String); !is_string || raw {
			return "label applies to a string"
		}
	}
	return ""
}

// The type inside a Maybe, or the type itself.
@(private)
maybe_elem :: proc(ti: ^runtime.Type_Info) -> ^runtime.Type_Info {
	if u, is_union := runtime.type_info_base(ti).variant.(runtime.Type_Info_Union); is_union && len(u.variants) == 1 {
		return u.variants[0]
	}
	return ti
}

// The type a range applies to: the field's own, or its elements'.
@(private)
numeric_elem :: proc(ti: ^runtime.Type_Info) -> ^runtime.Type_Info {
	#partial switch info in runtime.type_info_base(ti).variant {
	case runtime.Type_Info_Slice:         return info.elem
	case runtime.Type_Info_Dynamic_Array: return info.elem
	case runtime.Type_Info_Array:         return info.elem
	case runtime.Type_Info_Union:
		if len(info.variants) == 1 {
			return info.variants[0]
		}
	}
	return ti
}

@(private)
is_number :: proc(ti: ^runtime.Type_Info) -> bool {
	#partial switch _ in runtime.type_info_base(ti).variant {
	case runtime.Type_Info_Integer, runtime.Type_Info_Float:
		return true
	}
	return false
}
