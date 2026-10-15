// amber-json's own: the document unmarshal with a Report reads, parsed once. The same rules as
// parse — the same tokenizer, string and number readers, depth limit, duplicate keys, trailing
// data — into a tree that keeps where each value was written and each object's keys in the
// order they were written, which json.Value's map does not. It lives in a scratch arena that
// unmarshal frees.

package json

import "base:runtime"
import "core:fmt"

@(private)
Node_Kind :: enum u8 {
	Null,
	False,
	True,
	Integer,  // `text` is the token: an integer of any size, read for the field it goes into
	Float,    // `text` is the token, known to be a finite f64
	Infinity, // JSON5 only; `text` is the token, with its sign
	NaN,
	String,   // `text` is the value, escapes read
	Array,
	Object,
}

@(private)
Node :: struct {
	kind:        Node_Kind,
	offset:      int,      // where the value starts in the document
	end:         int,      // where it ends: data[offset:end] is its text as written
	text:        string,
	items:       []Node,   // an array's items, or an object's values
	keys:        []string, // an object's keys, in document order
	key_offsets: []int,
}

@(private)
Doc_Parser :: struct {
	p:      Parser,
	a:      runtime.Allocator,
	err_at: int,    // where the first error was found, or -1
	detail: string, // for a duplicate key, the key
}

// error_message is the text for an Error, as an issue says it.
error_message :: proc(err: Error) -> string {
	switch err {
	case .None:                           return "no error"
	case .EOF:                            return "the document ends before the value does"
	case .Illegal_Character:              return "a character JSON does not allow here"
	case .Invalid_Number:                 return "a number JSON does not allow, or past what an f64 holds"
	case .String_Not_Terminated:          return "a string with no closing quote"
	case .Invalid_String:                 return "a string with a bad escape, a control character, a lone surrogate or bytes that are not UTF-8"
	case .Invalid_Rune:                   return "an invalid character"
	case .Unexpected_Token:               return "unexpected token"
	case .Expected_String_For_Object_Key: return "expected a string as the key"
	case .Duplicate_Object_Key:           return "a key given twice in one object"
	case .Expected_Colon_After_Key:       return "expected : after the key"
	case .Trailing_Data:                  return "something after the value"
	case .Nesting_Too_Deep:               return "nested deeper than the depth limit"
	case .Invalid_Allocator:              return "an invalid allocator"
	case .Out_Of_Memory:                  return "out of memory"
	}
	return "unknown error"
}

// The document as a tree of Nodes in `a`, or the error parse would give and where it was found.
@(private)
parse_document :: proc(data: string, spec: Specification, max_depth: int, a: runtime.Allocator) -> (root: Node, err: Error, at: int, detail: string) {
	d := Doc_Parser{a = a, err_at = -1}
	d.p = make_parser_from_string(data, spec, true, a, max_depth)
	if spec == .MJSON && (d.p.curr_token.kind == .Ident || d.p.curr_token.kind == .String) {
		// The root object of MJSON, without braces.
		root.offset = d.p.curr_token.offset
		if max_depth < 1 {
			err = node_fail(&d, .Nesting_Too_Deep, root.offset)
		} else {
			d.p.depth += 1
			err = node_object_body(&d, &root, .EOF)
			d.p.depth -= 1
			root.end = token_end_pos(d.p.prev_token).offset
		}
	} else {
		root, err = node_value(&d)
	}
	if err == nil {
		at = d.p.curr_token.offset
		err = expect_end(&d.p)
		if err != nil {
			d.err_at = at
		}
	}
	return root, err, d.err_at, d.detail
}

// Records where the first error was, which is the innermost, and passes it on.
@(private)
node_fail :: proc(d: ^Doc_Parser, err: Error, at: int) -> Error {
	if d.err_at < 0 {
		d.err_at = at
	}
	return err
}

@(private)
node_value :: proc(d: ^Doc_Parser) -> (n: Node, err: Error) {
	n, err = node_value_body(d)
	if err == nil {
		// The last token the value read is its last: a scalar's own, or the closing bracket.
		n.end = token_end_pos(d.p.prev_token).offset
	}
	return
}

@(private)
node_value_body :: proc(d: ^Doc_Parser) -> (n: Node, err: Error) {
	p := &d.p
	token := p.curr_token
	n.offset = token.offset
	#partial switch token.kind {
	case .Null:
		advance_token(p)
		n.kind = .Null
		return
	case .False, .True:
		advance_token(p)
		n.kind = token.kind == .True ? .True : .False
		return
	case .Integer:
		advance_token(p)
		neg, mag, ok := parse_integer_text(token.text)
		if _, fits := integer_to_i64(neg, mag); !ok || !fits {
			// Past i64 it must still be a finite f64, as parse requires.
			if _, ferr := number_to_float(token.text, neg, mag, ok); ferr != nil {
				return n, node_fail(d, ferr, token.offset)
			}
		}
		n.kind, n.text = .Integer, token.text
		return
	case .Float:
		advance_token(p)
		if _, ferr := number_to_float(token.text); ferr != nil {
			return n, node_fail(d, ferr, token.offset)
		}
		n.kind, n.text = .Float, token.text
		return
	case .String:
		advance_token(p)
		s, serr := unquote_string(token, p.spec, d.a)
		if serr != nil {
			return n, node_fail(d, serr, token.offset)
		}
		n.kind, n.text = .String, s
		return
	case .Ident:
		if p.spec == .MJSON {
			advance_token(p)
			n.kind, n.text = .String, token.text
			return
		}
	case .Open_Brace:
		if err = enter(p); err != nil {
			return n, node_fail(d, err, token.offset)
		}
		defer leave(p)
		advance_token(p)
		node_object_body(d, &n, .Close_Brace) or_return
		at := p.curr_token.offset
		if err = expect_token(p, .Close_Brace); err != nil {
			return n, node_fail(d, err, at)
		}
		return
	case .Open_Bracket:
		if err = enter(p); err != nil {
			return n, node_fail(d, err, token.offset)
		}
		defer leave(p)
		advance_token(p)
		node_array_body(d, &n) or_return
		at := p.curr_token.offset
		if err = expect_token(p, .Close_Bracket); err != nil {
			return n, node_fail(d, err, at)
		}
		return
	case .Infinity, .NaN:
		if p.spec != .JSON {
			advance_token(p)
			n.kind, n.text = token.kind == .Infinity ? .Infinity : .NaN, token.text
			return
		}
	}
	err = .Unexpected_Token
	if token.kind == .Invalid && p.curr_err != nil && p.curr_err != .EOF {
		err = p.curr_err
	}
	if token.kind == .EOF {
		err = .EOF
	}
	advance_token(p)
	return n, node_fail(d, err, token.offset)
}

@(private)
node_array_body :: proc(d: ^Doc_Parser, n: ^Node) -> Error {
	p := &d.p
	n.kind = .Array
	items := make([dynamic]Node, d.a)
	for p.curr_token.kind != .Close_Bracket {
		item := node_value(d) or_return
		append(&items, item)
		if parse_comma(p) {
			break
		}
		at := p.curr_token.offset
		if err := trailing_comma(p, .Close_Bracket); err != nil {
			return node_fail(d, err, at)
		}
	}
	n.items = items[:]
	return nil
}

@(private)
node_object_body :: proc(d: ^Doc_Parser, n: ^Node, end_token: Token_Kind) -> Error {
	p := &d.p
	n.kind = .Object
	keys := make([dynamic]string, d.a)
	offsets := make([dynamic]int, d.a)
	items := make([dynamic]Node, d.a)
	seen := make(map[string]struct{}, d.a)
	for p.curr_token.kind != end_token {
		key_at := p.curr_token.offset
		key, kerr := parse_object_key(p, d.a)
		if kerr != nil {
			return node_fail(d, kerr, key_at)
		}
		colon_at := p.curr_token.offset
		if err := parse_colon(p); err != nil {
			return node_fail(d, err, colon_at)
		}
		item := node_value(d) or_return
		if key in seen {
			d.detail = key
			return node_fail(d, .Duplicate_Object_Key, key_at)
		}
		seen[key] = {}
		append(&keys, key)
		append(&offsets, key_at)
		append(&items, item)
		if parse_comma(p) {
			break
		}
		at := p.curr_token.offset
		if err := trailing_comma(p, end_token); err != nil {
			return node_fail(d, err, at)
		}
	}
	n.keys, n.key_offsets, n.items = keys[:], offsets[:], items[:]
	return nil
}

// The member of object `n` named `key`, or -1.
@(private)
node_find :: proc(n: ^Node, key: string) -> int {
	for k, i in n.keys {
		if k == key {
			return i
		}
	}
	return -1
}

// A Node as a Value, every string and container allocated with `allocator`, as parse with
// parse_integers makes it: an integer past i64 is the nearest Float.
@(private)
node_to_value :: proc(n: ^Node, allocator: runtime.Allocator) -> Value {
	switch n.kind {
	case .Null:     return Null{}
	case .False:    return Boolean(false)
	case .True:     return Boolean(true)
	case .Integer:
		neg, mag, ok := parse_integer_text(n.text)
		if ok {
			if i, fits := integer_to_i64(neg, mag); fits {
				return Integer(i)
			}
		}
		v, _ := number_to_float(n.text, neg, mag, ok)
		return v
	case .Float:
		v, _ := number_to_float(n.text)
		return v
	case .Infinity, .NaN:
		return special_float(n)
	case .String:
		s, _ := clone_string(n.text, allocator)
		return s
	case .Array:
		a := make(Array, len(n.items), allocator)
		for &item, i in n.items {
			a[i] = node_to_value(&item, allocator)
		}
		return a
	case .Object:
		o := make(Object, len(n.items), allocator)
		for &item, i in n.items {
			k, _ := clone_string(n.keys[i], allocator)
			o[k] = node_to_value(&item, allocator)
		}
		return o
	}
	return nil
}

// JSON5's Infinity and NaN, with their signs.
@(private)
special_float :: proc(n: ^Node) -> Float {
	negative := len(n.text) > 0 && n.text[0] == '-'
	if n.kind == .Infinity {
		return negative ? 0hfff0000000000000 : 0h7ff0000000000000
	}
	return negative ? 0hfff7ffffffffffff : 0h7ff7ffffffffffff
}

// "a string", "a number": what a value is, for a message.
@(private)
node_kind_name :: proc(n: ^Node) -> string {
	switch n.kind {
	case .Null:                                return "null"
	case .False, .True:                        return "a boolean"
	case .Integer, .Float, .Infinity, .NaN:    return "a number"
	case .String:                              return "a string"
	case .Array:                               return "an array"
	case .Object:                              return "an object"
	}
	return "nothing"
}

// The issue for a document that does not parse, at the line and column where it stopped.
@(private)
parse_issue :: proc(r: ^Report, data: string, err: Error, at: int, detail: string) {
	message := error_message(err)
	if err == .Duplicate_Object_Key {
		message = fmt.tprintf("the key %q is given twice in one object", detail)
	}
	report_add(r, .Parse, .Error, offset_position(data, at), "", "%s", message)
}
