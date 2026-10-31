// amber-json's own: reading a parsed Value by path, as amber-toml's toml/get.odin reads a table
// (same author). A path step is a key or, unlike TOML's, an index into an array.

package json

// get returns the value at `path` below `v`: a string steps into an object by key, an int into
// an array by index, and the last step names the value. An empty path is `v` itself. The value
// is the tree's, borrowed: it lives as long as the tree. A `null` is found, as Null.
@(require_results)
get :: proc(v: Value, path: ..Match_Key_Variant) -> (value: Value, ok: bool) {
	cur := v
	for step in path {
		switch k in step {
		case string:
			o := cur.(Object) or_return
			cur = o[k] or_return
		case int:
			a := cur.(Array) or_return
			if k < 0 || k >= len(a) {
				return nil, false
			}
			cur = a[k]
		}
	}
	return cur, true
}

// get_string returns the string at `path`, borrowed as get says.
@(require_results)
get_string :: proc(v: Value, path: ..Match_Key_Variant) -> (value: string, ok: bool) {
	x := get(v, ..path) or_return
	return x.(String)
}

// get_int returns the integer at `path`: an Integer, or a Float that is a whole number below
// 2^53 in size — parse reads every number as a Float unless asked for integers, and below 2^53
// an integer written is the Float it reads as. Past that it is false, rather than a neighbour of
// the number written; parse with parse_integers to read one.
@(require_results)
get_int :: proc(v: Value, path: ..Match_Key_Variant) -> (value: i64, ok: bool) {
	x := get(v, ..path) or_return
	#partial switch n in x {
	case Integer:
		return n, true
	case Float:
		if abs(n) < 0h4340000000000000 && n == Float(i64(n)) { // 2^53; false for a NaN
			return i64(n), true
		}
	}
	return 0, false
}

// get_float returns the number at `path` as a float, an Integer included.
@(require_results)
get_float :: proc(v: Value, path: ..Match_Key_Variant) -> (value: f64, ok: bool) {
	x := get(v, ..path) or_return
	#partial switch n in x {
	case Float:
		return n, true
	case Integer:
		return f64(n), true
	}
	return 0, false
}

@(require_results)
get_bool :: proc(v: Value, path: ..Match_Key_Variant) -> (value: bool, ok: bool) {
	x := get(v, ..path) or_return
	return x.(Boolean)
}

@(require_results)
get_object :: proc(v: Value, path: ..Match_Key_Variant) -> (value: Object, ok: bool) {
	x := get(v, ..path) or_return
	return x.(Object)
}

@(require_results)
get_array :: proc(v: Value, path: ..Match_Key_Variant) -> (value: Array, ok: bool) {
	x := get(v, ..path) or_return
	return x.(Array)
}

// get_strings returns the array at `path`, if every item in it is a string. The slice is
// allocated with `allocator`; the strings in it are borrowed from the tree.
@(require_results)
get_strings :: proc(v: Value, path: ..Match_Key_Variant, allocator := context.allocator) -> (list: []string, ok: bool) {
	a := get_array(v, ..path) or_return
	list = make([]string, len(a), allocator)
	for item, i in a {
		s, is_string := item.(String)
		if !is_string {
			delete(list, allocator)
			return nil, false
		}
		list[i] = s
	}
	return list, true
}
