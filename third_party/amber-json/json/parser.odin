// Derived from Odin's core:encoding/json at dev-2026-08 (8412dc3), Copyright (c) 2016-2025
// Ginger Bill, under the zlib licence in third_party/odin/LICENSE.
// Altered for amber-json: the tokenizer's errors kept; trailing data, trailing commas, duplicate and empty keys,
// nesting past max_depth, bad escapes, lone surrogates and invalid UTF-8 refused; integers past
// i64 read as Float; leaks on errors fixed.
// Each change is marked "amber-json:" where it is made.

package json

import "core:math"
import "core:mem"
import "core:unicode/utf8"
import "core:unicode/utf16"
import "core:strconv"

Parser :: struct {
	tok:            Tokenizer,
	prev_token:     Token,
	curr_token:     Token,
	spec:           Specification,
	allocator:      mem.Allocator,
	parse_integers: bool,
	// amber-json: the tokenizer's error for curr_token, which core dropped; a token with one
	// has kind .Invalid. EOF's is .EOF.
	curr_err:       Error,
	// amber-json: objects and arrays open around curr_token, and how many may be.
	depth:          int,
	max_depth:      int,
}

make_parser :: proc{
	make_parser_from_bytes,
	make_parser_from_string,
}

@(require_results)
make_parser_from_bytes :: proc(data: []byte, spec := DEFAULT_SPECIFICATION, parse_integers := false, allocator := context.allocator, max_depth := DEFAULT_MAX_DEPTH) -> Parser {
	return make_parser_from_string(string(data), spec, parse_integers, allocator, max_depth)
}
@(require_results)
make_parser_from_string :: proc(data: string, spec := DEFAULT_SPECIFICATION, parse_integers := false, allocator := context.allocator, max_depth := DEFAULT_MAX_DEPTH) -> Parser {
	p: Parser
	p.tok = make_tokenizer(data, spec, parse_integers)
	p.spec = spec
	p.allocator = allocator
	p.max_depth = max_depth
	assert(p.allocator.procedure != nil)
	advance_token(&p)
	return p
}

parse :: proc{
	parse_bytes,
	parse_string,
}


@(require_results)
parse_bytes :: proc(data: []byte, spec := DEFAULT_SPECIFICATION, parse_integers := false, allocator := context.allocator, max_depth := DEFAULT_MAX_DEPTH, loc := #caller_location) -> (Value, Error) {
	return parse_string(string(data), spec, parse_integers, allocator, max_depth, loc)
}

@(require_results)
parse_string :: proc(data: string, spec := DEFAULT_SPECIFICATION, parse_integers := false, allocator := context.allocator, max_depth := DEFAULT_MAX_DEPTH, loc := #caller_location) -> (Value, Error) {
	context.allocator = allocator
	p := make_parser_from_string(data, spec, parse_integers, allocator, max_depth)

	value: Value
	err: Error
	switch p.spec {
	case .JSON, .JSON5:
		value, err = parse_value(&p, loc)
	case .SJSON:
		#partial switch p.curr_token.kind {
		case .Ident, .String:
			// The root object of MJSON, without braces.
			if p.max_depth < 1 {
				return nil, .Nesting_Too_Deep
			}
			p.depth += 1
			value, err = parse_object_body(&p, .EOF, loc)
			p.depth -= 1
		case:
			value, err = parse_value(&p, loc)
		}
	}
	if err != nil {
		// What was read is freed already; on an error parse_object_body returns the map it
		// freed, which core's MJSON path here handed to the caller.
		return nil, err
	}
	if err = expect_end(&p); err != nil {
		destroy_value(value, allocator, loc)
		return nil, err
	}
	return value, nil
}

// expect_end is nil when the parser has read the whole input: amber-json reads one value and
// refuses anything after it but whitespace (core stopped after the value and said nothing).
// In MJSON a newline reads as a comma, so commas there are skipped first.
@(require_results)
expect_end :: proc(p: ^Parser) -> Error {
	if p.spec == .MJSON {
		for p.curr_token.kind == .Comma {
			advance_token(p)
		}
	}
	switch {
	case p.curr_token.kind == .EOF:
		return nil
	case p.curr_err != nil && p.curr_err != .EOF:
		return p.curr_err
	}
	return .Trailing_Data
}

@(require_results)
token_end_pos :: proc(tok: Token) -> Pos {
	end := tok.pos
	end.offset += len(tok.text)
	return end
}

advance_token :: proc(p: ^Parser) -> (Token, Error) {
	err: Error
	p.prev_token = p.curr_token
	p.curr_token, err = get_token(&p.tok)
	// amber-json: the tokenizer marks an invalid number or string with an error and keeps its
	// kind; core dropped the error and read the token anyway (`01` as 1, `"a\tb"` as "a").
	p.curr_err = err
	if err != nil && err != .EOF {
		p.curr_token.kind = .Invalid
	}
	return p.prev_token, err
}


@(require_results)
allow_token :: proc(p: ^Parser, kind: Token_Kind) -> bool {
	if p.curr_token.kind == kind {
		advance_token(p)
		return true
	}
	return false
}

@(require_results)
expect_token :: proc(p: ^Parser, kind: Token_Kind) -> Error {
	prev := p.curr_token
	advance_token(p)
	if prev.kind == kind {
		return nil
	}
	return .Unexpected_Token
}


@(require_results)
parse_colon :: proc(p: ^Parser) -> (err: Error) {
	colon_err := expect_token(p, .Colon)
	if colon_err == nil {
		return nil
	}
	return .Expected_Colon_After_Key
}

@(require_results)
parse_comma :: proc(p: ^Parser) -> (do_break: bool) {
	switch p.spec {
	case .JSON5, .MJSON:
		if allow_token(p, .Comma) {
			return false
		}
		return false
	case .JSON:
		if !allow_token(p, .Comma) {
			return true
		}
	}
	return false
}

@(require_results)
parse_value :: proc(p: ^Parser, loc := #caller_location) -> (value: Value, err: Error) {
	err = .None
	token := p.curr_token
	#partial switch token.kind {
	case .Null:
		advance_token(p)
		value = Null{}
		return
	case .False:
		advance_token(p)
		value = Boolean(false)
		return
	case .True:
		advance_token(p)
		value = Boolean(true)
		return

	case .Integer:
		// amber-json: strconv.parse_i64 wraps past i64 and says ok. An integer that does not
		// fit is the nearest Float instead, as JavaScript reads it.
		advance_token(p)
		neg, mag, ok := parse_integer_text(token.text)
		if ok {
			if i, fits := integer_to_i64(neg, mag); fits {
				return Integer(i), nil
			}
		}
		return number_to_float(token.text, neg, mag, ok)
	case .Float:
		advance_token(p)
		return number_to_float(token.text)

	case .Ident:
		if p.spec == .MJSON {
			advance_token(p)
			return clone_string(token.text, p.allocator, loc)
		}

	case .String:
		advance_token(p)
		return unquote_string(token, p.spec, p.allocator, loc)

	case .Open_Brace:
		return parse_object(p, loc)

	case .Open_Bracket:
		return parse_array(p, loc)

	case:
		if p.spec != .JSON {
			switch {
			case allow_token(p, .Infinity):
				inf: u64 = 0x7ff0000000000000
				if token.text[0] == '-' {
					inf = 0xfff0000000000000
				}
				value = transmute(f64)inf
				return
			case allow_token(p, .NaN):
				nan: u64 = 0x7ff7ffffffffffff
				if token.text[0] == '-' {
					nan = 0xfff7ffffffffffff
				}
				value = transmute(f64)nan
				return
			}
		}
	}

	err = .Unexpected_Token
	if token.kind == .Invalid && p.curr_err != nil && p.curr_err != .EOF {
		err = p.curr_err
	}
	advance_token(p)
	return
}

// trailing_comma refuses a comma before the end of an array or object in JSON. amber-json:
// core took one (`[1,]`, `{"a":1,}`); JSON5 allows one.
@(require_results)
trailing_comma :: proc(p: ^Parser, end_token: Token_Kind) -> Error {
	if p.spec == .JSON && p.curr_token.kind == end_token {
		return .Unexpected_Token
	}
	return nil
}

// enter counts an object or array opened at curr_token, and refuses one past max_depth. amber-json:
// each level is a call deeper, and core had no limit, so `[[[[…` ran out of stack. leave undoes it.
@(require_results)
enter :: proc(p: ^Parser) -> Error {
	if p.depth >= p.max_depth {
		return .Nesting_Too_Deep
	}
	p.depth += 1
	return nil
}

leave :: proc(p: ^Parser) {
	p.depth -= 1
}

// parse_integer_text reads an integer token: an optional sign, then decimal digits, or JSON5's
// 0x and hexadecimal ones. ok is false when the magnitude does not fit a u128.
@(require_results)
parse_integer_text :: proc(text: string) -> (neg: bool, mag: u128, ok: bool) {
	s := text
	if len(s) > 0 && (s[0] == '-' || s[0] == '+') {
		neg = s[0] == '-'
		s = s[1:]
	}
	base: u128 = 10
	if len(s) > 2 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X') {
		base = 16
		s = s[2:]
	}
	if len(s) == 0 {
		return
	}
	for c in transmute([]byte)s {
		d: u128 = base
		switch c {
		case '0'..='9': d = u128(c - '0')
		case 'a'..='f': d = u128(c - 'a' + 10)
		case 'A'..='F': d = u128(c - 'A' + 10)
		}
		if d >= base {
			return
		}
		if mag > (max(u128) - d) / base {
			return
		}
		mag = mag*base + d
	}
	ok = true
	return
}

@(require_results)
integer_to_i64 :: proc(neg: bool, mag: u128) -> (i: i64, ok: bool) {
	if neg {
		if mag > u128(max(i64)) + 1 {
			return
		}
		return i64(-i128(mag)), true
	}
	if mag > u128(max(i64)) {
		return
	}
	return i64(mag), true
}

// number_to_float reads a number token as a Float. One past f64's range is an error, as JSON
// has no infinity. amber-json: core gave +Inf, which marshal then wrote as text no JSON reader takes.
// Hexadecimal (JSON5) goes through the integer, given as neg, mag and have_int.
@(require_results)
number_to_float :: proc(text: string, neg := false, mag: u128 = 0, have_int := false) -> (value: Value, err: Error) {
	f, ok := strconv.parse_f64(text)
	if !ok {
		n, m, iok := parse_integer_text(text)
		if have_int {
			n, m, iok = neg, mag, true
		}
		if !iok {
			return nil, .Invalid_Number
		}
		f = f64(m)
		if n {
			f = -f
		}
	}
	if math.is_inf(f) || math.is_nan(f) {
		return nil, .Invalid_Number
	}
	return Float(f), nil
}

@(require_results)
parse_array :: proc(p: ^Parser, loc := #caller_location) -> (value: Value, err: Error) {
	err = .None
	enter(p) or_return
	defer leave(p)
	expect_token(p, .Open_Bracket) or_return

	array: Array
	array.allocator = p.allocator
	defer if err != nil {
		for elem in array {
			destroy_value(elem, loc=loc)
		}
		delete(array, loc)
	}

	for p.curr_token.kind != .Close_Bracket {
		elem := parse_value(p, loc) or_return
		append(&array, elem, loc)

		if parse_comma(p) {
			break
		}
		trailing_comma(p, .Close_Bracket) or_return
	}

	expect_token(p, .Close_Bracket) or_return
	value = array
	return
}

@(private, require_results)
bytes_make :: proc(size, alignment: int, allocator: mem.Allocator, loc := #caller_location) -> (bytes: []byte, err: Error) {
	b, berr := mem.alloc_bytes(size, alignment, allocator, loc)
	if berr != nil {
		if berr == .Out_Of_Memory {
			err = .Out_Of_Memory
		} else {
			err = .Invalid_Allocator
		}
	}
	bytes = b
	return
}

@(require_results)
clone_string :: proc(s: string, allocator: mem.Allocator, loc := #caller_location) -> (str: string, err: Error) {
	n := len(s)
	b := bytes_make(n+1, 1, allocator, loc) or_return
	copy(b, s)
	if len(b) > n {
		b[n] = 0
		str = string(b[:n])
	}
	return
}

@(require_results)
parse_object_key :: proc(p: ^Parser, key_allocator: mem.Allocator, loc := #caller_location) -> (key: string, err: Error) {
	tok := p.curr_token
	if p.spec != .JSON {
		if allow_token(p, .Ident) {
			return clone_string(tok.text, key_allocator, loc)
		}
	}
	if tok_err := expect_token(p, .String); tok_err != nil {
		err = .Expected_String_For_Object_Key
		return
	}
	return unquote_string(tok, p.spec, key_allocator, loc)
}

@(require_results)
parse_object_body :: proc(p: ^Parser, end_token: Token_Kind, loc := #caller_location) -> (obj: Object, err: Error) {
	obj = make(Object, allocator=p.allocator, loc=loc)

	defer if err != nil {
		for key, elem in obj {
			delete(key, p.allocator, loc)
			destroy_value(elem, loc=loc)
		}
		delete(obj, loc)
	}

	for p.curr_token.kind != end_token {
		// amber-json: the key and the value are freed on every error after them (core leaked
		// both), and the empty key is a key (core dropped it, so {"":1,"":2} passed).
		key := parse_object_key(p, p.allocator, loc) or_return
		if err = parse_colon(p); err != nil {
			delete(key, p.allocator, loc)
			return
		}
		elem: Value
		if elem, err = parse_value(p, loc); err != nil {
			delete(key, p.allocator, loc)
			return
		}

		if key in obj {
			err = .Duplicate_Object_Key
			delete(key, p.allocator, loc)
			destroy_value(elem, p.allocator, loc)
			return
		}

		reserve_error := reserve(&obj, len(obj) + 1, loc)
		if reserve_error != nil {
			err = .Out_Of_Memory if reserve_error == .Out_Of_Memory else .Invalid_Allocator
			delete(key, p.allocator, loc)
			destroy_value(elem, p.allocator, loc)
			return
		}
		obj[key] = elem

		if parse_comma(p) {
			break
		}
		trailing_comma(p, end_token) or_return
	}
	return obj, .None
}

@(require_results)
parse_object :: proc(p: ^Parser, loc := #caller_location) -> (value: Value, err: Error) {
	enter(p) or_return
	defer leave(p)
	expect_token(p, .Open_Brace) or_return
	obj := parse_object_body(p, .Close_Brace, loc) or_return
	if err = expect_token(p, .Close_Brace); err != nil {
		destroy_value(obj, p.allocator, loc)
		return nil, err
	}
	return obj, .None
}


// unquote_string gives a string token's text with its escapes read.
//
// amber-json: core assumed a mostly valid string, and on anything else stopped and returned what
// it had (`"a\qb"` read as "a"), or re-encoded a bad byte as U+FFFD, three bytes for one, past
// the end of its buffer, which panicked. Here a byte that is not UTF-8, a raw control character,
// an escape the spec does not have and a lone surrogate are each .Invalid_String, and nothing
// is allocated.
@(require_results)
unquote_string :: proc(token: Token, spec: Specification, allocator := context.allocator, loc := #caller_location) -> (value: string, err: Error) {
	if token.kind != .String {
		return "", nil
	}
	s := token.text
	if len(s) < 2 || s[0] != s[len(s)-1] || (s[0] != '"' && s[0] != '\'') {
		return "", .Invalid_String
	}
	quote := s[0]
	s = s[1:len(s)-1]

	i := 0
	for i < len(s) {
		c := s[i]
		if c == '\\' || c == quote || c < ' ' {
			break
		}
		if c < utf8.RUNE_SELF {
			i += 1
			continue
		}
		r, w := utf8.decode_rune_in_string(s[i:])
		if r == utf8.RUNE_ERROR && w == 1 {
			return "", .Invalid_String
		}
		i += w
	}
	if i == len(s) {
		return clone_string(s, allocator, loc)
	}

	// Every escape is at least as long as what it writes, and so is UTF-8 copied as it is. The
	// byte past the end stays zero, the NUL a cstring field relies on, as clone_string's.
	b := bytes_make(len(s)+1, 1, allocator, loc) or_return
	w := copy(b, s[0:i])

	if len(b) == 0 && allocator.data == nil {
		// `unmarshal_count_array` calls us with a nil allocator
		return string(b[:w]), nil
	}
	defer if err != nil {
		delete(b, allocator, loc)
		value = ""
	}

	for i < len(s) {
		c := s[i]
		switch {
		case c == '\\':
			i += 1
			if i >= len(s) {
				return "", .Invalid_String
			}
			switch s[i] {
			case '"', '\\', '/':
				b[w] = s[i]
				i += 1
				w += 1
			case '\'':
				if spec == .JSON {
					return "", .Invalid_String
				}
				b[w] = s[i]
				i += 1
				w += 1

			case 'b':
				b[w] = '\b'
				i += 1
				w += 1
			case 'f':
				b[w] = '\f'
				i += 1
				w += 1
			case 'r':
				b[w] = '\r'
				i += 1
				w += 1
			case 't':
				b[w] = '\t'
				i += 1
				w += 1
			case 'n':
				b[w] = '\n'
				i += 1
				w += 1
			case 'u':
				r := hex4(s[i+1:])
				if r < 0 {
					return "", .Invalid_String
				}
				i += 5

				// A surrogate only as a high one followed by a low one, which are one character.
				if r >= utf8.SURROGATE_LOW_MIN && r <= utf8.SURROGATE_MAX {
					return "", .Invalid_String
				}
				if r >= utf8.SURROGATE_MIN && r <= utf8.SURROGATE_HIGH_MAX {
					if i+1 >= len(s) || s[i] != '\\' || s[i+1] != 'u' {
						return "", .Invalid_String
					}
					r2 := hex4(s[i+2:])
					if r2 < utf8.SURROGATE_LOW_MIN || r2 > utf8.SURROGATE_MAX {
						return "", .Invalid_String
					}
					i += 6
					r = utf16.decode_surrogate_pair(r, r2)
				}

				buf, buf_width := utf8.encode_rune(r)
				copy(b[w:], buf[:buf_width])
				w += buf_width

			case '0':
				if spec == .JSON {
					return "", .Invalid_String
				}
				b[w] = '\x00'
				i += 1
				w += 1
			case 'v':
				if spec == .JSON {
					return "", .Invalid_String
				}
				b[w] = '\v'
				i += 1
				w += 1

			case 'x':
				if spec == .JSON {
					return "", .Invalid_String
				}
				r := hex2(s[i+1:])
				if r < 0 {
					return "", .Invalid_String
				}
				i += 3

				buf, buf_width := utf8.encode_rune(r)
				copy(b[w:], buf[:buf_width])
				w += buf_width

			case '\n':
				// JSON5: a line continuation writes nothing (core stopped the string here).
				if spec == .JSON {
					return "", .Invalid_String
				}
				i += 1
			case '\r':
				if spec == .JSON {
					return "", .Invalid_String
				}
				i += 1
				if i < len(s) && s[i] == '\n' {
					i += 1
				}

			case:
				return "", .Invalid_String
			}

		case c == quote, c < ' ':
			return "", .Invalid_String

		case c < utf8.RUNE_SELF:
			b[w] = c
			i += 1
			w += 1

		case:
			r, width := utf8.decode_rune_in_string(s[i:])
			if r == utf8.RUNE_ERROR && width == 1 {
				return "", .Invalid_String
			}
			copy(b[w:], s[i:i+width])
			i += width
			w += width
		}
	}

	return string(b[:w]), nil
}

// hex2 reads two hexadecimal digits, or gives -1.
@(private)
hex2 :: proc(s: string) -> rune {
	if len(s) < 2 || !is_hex(s[0]) || !is_hex(s[1]) {
		return -1
	}
	r: rune
	for c in transmute([]byte)s[:2] {
		switch c {
		case '0'..='9': r = r*16 + rune(c - '0')
		case 'a'..='f': r = r*16 + rune(c - 'a' + 10)
		case 'A'..='F': r = r*16 + rune(c - 'A' + 10)
		}
	}
	return r
}
