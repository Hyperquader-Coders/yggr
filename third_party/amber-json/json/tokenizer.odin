// Derived from Odin's core:encoding/json at dev-2026-08 (8412dc3), Copyright (c) 2016-2025
// Ginger Bill, under the zlib licence in third_party/odin/LICENSE.
// Altered for amber-json: a NUL byte is not the end; comments skipped in a loop; \u takes
// hexadecimal only; lone surrogates and JSON5 escapes in JSON refused.
// Each change is marked "amber-json:" where it is made.

package json

import "core:strings"
import "core:unicode/utf8"

Pos :: struct {
	offset: int,
	line:   int,
	column: int,
}

Token :: struct {
	using pos: Pos,
	kind: Token_Kind,
	text: string,
}

Token_Kind :: enum {
	Invalid,
	EOF,

	Null,
	False,
	True,

	Infinity,
	NaN,

	Ident,

	Integer,
	Float,
	String,

	Colon,
	Comma,

	Open_Brace,
	Close_Brace,

	Open_Bracket,
	Close_Bracket,
}

Tokenizer :: struct {
	using pos:        Pos,
	data:             string,
	r:                rune, // current rune
	w:                int,  // current rune width in bytes
	curr_line_offset: int,
	spec:             Specification,
	parse_integers:   bool,
	insert_comma:     bool,
}



@(require_results)
make_tokenizer :: proc(data: string, spec := DEFAULT_SPECIFICATION, parse_integers := false) -> Tokenizer {
	t := Tokenizer{pos = {line=1}, data = data, spec = spec, parse_integers = parse_integers}
	next_rune(&t)
	if t.r == utf8.RUNE_BOM {
		next_rune(&t)
	}
	return t
}

next_rune :: proc(t: ^Tokenizer) -> rune #no_bounds_check {
	if t.offset >= len(t.data) {
		t.r = utf8.RUNE_EOF
	} else {
		t.offset += t.w
		t.r, t.w = utf8.decode_rune_in_string(t.data[t.offset:])
		t.pos.column = t.offset - t.curr_line_offset
		if t.offset >= len(t.data) {
			t.r = utf8.RUNE_EOF
		}
	}
	return t.r
}


@(require_results)
get_token :: proc(t: ^Tokenizer) -> (token: Token, err: Error) {
	skip_digits :: proc(t: ^Tokenizer) {
		for t.offset < len(t.data) {
			if '0' <= t.r && t.r <= '9' {
				// Okay
			} else {
				return
			}
			next_rune(t)
		}
	}
	skip_hex_digits :: proc(t: ^Tokenizer) {
		for t.offset < len(t.data) {
			next_rune(t)
			switch t.r {
			case '0'..='9', 'a'..='f', 'A'..='F':
				// Okay
			case:
				return
			}
		}
	}

	@(require_results)
	scan_escape :: proc(t: ^Tokenizer) -> bool {
		switch t.r {
		case '"', '\'', '\\', '/', 'b', 'n', 'r', 't', 'f':
			next_rune(t)
			return true
		case 'u':
			// Expect 4 hexadecimal digits
			for i := 0; i < 4; i += 1 {
				r := next_rune(t)
				switch r {
				case '0'..='9', 'a'..='f', 'A'..='F':
					// Okay
				case:
					return false
				}
			}
			return true
		case:
			// Ignore the next rune regardless
			next_rune(t)
		}
		return false
	}

	skip_whitespace :: proc(t: ^Tokenizer, on_newline: bool) {
		loop: for t.offset < len(t.data) {
			switch t.r {
			case ' ', '\t', '\v', '\f', '\r':
				next_rune(t)
			case '\n':
				if on_newline {
					break loop
				}
				t.line += 1
				t.curr_line_offset = t.offset
				t.pos.column = 1
				next_rune(t)
			case:
				if t.spec != .JSON {
					switch t.r {
					case 0x2028, 0x2029, 0xFEFF:
						next_rune(t)
						continue loop
					}
				}
				break loop
			}
		}
		return
	}

	skip_to_next_line :: proc(t: ^Tokenizer) {
		for t.offset < len(t.data) {
			r := next_rune(t)
			if r == '\n' {
				return
			}
		}
	}

	skip_alphanum :: proc(t: ^Tokenizer) {
		for t.offset < len(t.data) {
			switch t.r {
			case 'A'..='Z', 'a'..='z', '0'..='9', '_':
				next_rune(t)
				continue
			}

			return
		}
	}

	// Whitespace and, outside strict JSON, comments. amber-json: core read each comment by
	// calling get_token again, so a long run of comments ran out of stack.
	for {
		skip_whitespace(t, t.insert_comma)
		if t.spec == .JSON || t.r != '/' || t.offset+1 >= len(t.data) {
			break
		}
		switch t.data[t.offset+1] {
		case '/':
			skip_to_next_line(t)
			continue
		case '*':
			end := strings.index(t.data[t.offset+2:], "*/")
			if end < 0 {
				token.pos = t.pos
				token.kind = .Invalid
				token.text = t.data[t.offset:]
				t.offset = len(t.data)
				t.r = utf8.RUNE_EOF
				err = .EOF
				return
			}
			stop := t.offset + 2 + end + 2
			for t.offset < stop {
				next_rune(t)
			}
			continue
		}
		break
	}

	token.pos = t.pos

	token.kind = .Invalid

	curr_rune := t.r
	next_rune(t)

	block: switch curr_rune {
	case utf8.RUNE_ERROR:
		err = .Illegal_Character
	case utf8.RUNE_EOF:
		token.kind = .EOF
		err = .EOF
	case '\x00':
		// amber-json: a NUL byte is not the end of the input, so what follows one is read.
		err = .Illegal_Character
		
	case '\n':
		t.insert_comma = false
		token.text = ","
		token.kind = .Comma
		return

	case 'A'..='Z', 'a'..='z', '_':
		token.kind = .Ident

		skip_alphanum(t)

		switch str := string(t.data[token.offset:t.offset]); str {
		case "null":  token.kind = .Null
		case "false": token.kind = .False
		case "true":  token.kind = .True
		case:
			if t.spec != .JSON {
				switch str {
				case "Infinity": token.kind = .Infinity
				case "NaN":      token.kind = .NaN
				}
			}
		}

	case '+':
		// amber-json: core set the error for JSON5 too, which its parser then dropped.
		if t.spec == .JSON {
			err = .Illegal_Character
			break
		}
		fallthrough

	case '-':
		switch t.r {
		case '0'..='9':
			// Okay
		case:
			// Illegal use of +/-
			err = .Illegal_Character

			if t.spec != .JSON {
				if t.r == 'I' || t.r == 'N' {
					skip_alphanum(t)
				}
				switch string(t.data[token.offset:t.offset]) {
				// amber-json: the error cleared, which core's parser dropped instead.
				case "-Infinity", "+Infinity": token.kind = .Infinity; err = nil
				case "-NaN", "+NaN":           token.kind = .NaN;      err = nil
				}
			}
			break block
		}
		fallthrough

	case '0'..='9':
		token.kind = t.parse_integers ? .Integer : .Float
		if t.spec != .JSON { // Hexadecimal Numbers
			if curr_rune == '0' && (t.r == 'x' || t.r == 'X') {
				next_rune(t)
				skip_hex_digits(t)
				break
			}
		}

		skip_digits(t)

		if t.r == '.' {
			token.kind = .Float
			next_rune(t)
			skip_digits(t)
		}
		if t.r == 'e' || t.r == 'E' {
			token.kind = .Float
			switch r := next_rune(t); r {
			case '+', '-':
				next_rune(t)
			}
			skip_digits(t)
		}

		str := string(t.data[token.offset:t.offset])
		if !is_valid_number(str, t.spec) {
			err = .Invalid_Number
		}

	case '.':
		err = .Illegal_Character
		if t.spec != .JSON { // Allow leading decimal point
			skip_digits(t)
			if t.r == 'e' || t.r == 'E' {
				switch r := next_rune(t); r {
				case '+', '-':
					next_rune(t)
				}
				skip_digits(t)
			}
			str := string(t.data[token.offset:t.offset])
			if !is_valid_number(str, t.spec) {
				err = .Invalid_Number
			}
		}


	case '\'':
		// amber-json: core set the error for JSON5 too, which its parser then dropped.
		if t.spec == .JSON {
			err = .Illegal_Character
			break
		}
		fallthrough
	case '"':
		token.kind = .String
		quote := curr_rune
		for t.offset < len(t.data) {
			r := t.r
			if r == '\n' || r < 0 {
				err = .String_Not_Terminated
				break
			}
			next_rune(t)
			if r == quote {
				break
			}
			if r == '\\' {
				_ = scan_escape(t)
			}
		}

		str := string(t.data[token.offset : t.offset])
		if !is_valid_string_literal(str, t.spec) {
			err = .Invalid_String
		}


	case ',': 
		token.kind = .Comma
		t.insert_comma = false
	case ':': token.kind = .Colon
	case '{': token.kind = .Open_Brace
	case '}': token.kind = .Close_Brace
	case '[': token.kind = .Open_Bracket
	case ']': token.kind = .Close_Bracket
	
	case '=': 
		if t.spec == .MJSON {
			token.kind = .Colon
		} else {
			err = .Illegal_Character
		}

	case '/':
		// Comments were skipped above, so this is a lone '/'.
		err = .Illegal_Character

	case: err = .Illegal_Character
	}

	token.text = string(t.data[token.offset : t.offset])
	
	if t.spec == .MJSON {
		switch token.kind {
		case .Invalid:
			// preserve insert_comma info
		case .EOF:
			t.insert_comma = false
		case .Colon, .Comma, .Open_Brace, .Open_Bracket:
			t.insert_comma = false
		case .Null, .False, .True, .Infinity, .NaN, 
		     .Ident, .Integer, .Float, .String, 
		     .Close_Brace, .Close_Bracket:
			t.insert_comma = true
		}
	}

	return
}



@(require_results)
is_valid_number :: proc(str: string, spec: Specification) -> bool {
	s := str
	if s == "" {
		return false
	}

	if s[0] == '-' {
		s = s[1:]
		if s == "" {
			return false
		}
	} else if spec != .JSON {
		if s[0] == '+' { // Allow positive sign
			s = s[1:]
			if s == "" {
				return false
			}
		}
	}
	
	if spec != .JSON && len(s) >= 2 {
		// Allow for hexadecimal strings
		if s[:2] == "0x" || s[:2] == "0X" {
			s = s[2:]
			if len(s) == 0 {
				return false
			}
			hexadecimal_loop: for len(s) > 0 {
				switch s[0] {
				case '0'..='9', 'A'..='Z', 'a'..='z':
					s = s[1:]
				case:
					break hexadecimal_loop
				}
			}
			return len(s) == 0
		}
	}

	switch s[0] {
	case '0':
		s = s[1:]
	case '1'..='9':
		s = s[1:]
		for len(s) > 0 && '0' <= s[0] && s[0] <= '9' {
			s = s[1:]
		}
	case '.':
		if spec != .JSON { // Allow leading decimal point
			s = s[1:]
		} else {
			return false
		}
	case:
		return false
	}

	if spec != .JSON {
		if len(s) == 1 && s[0] == '.' { // Allow trailing decimal point
			return true
		}
	}

	if len(s) >= 2 && s[0] == '.' && '0' <= s[1] && s[1] <= '9' {
		s = s[2:]
		for len(s) > 0 && '0' <= s[0] && s[0] <= '9' {
			s = s[1:]
		}
	}

	if len(s) >= 2 && (s[0] == 'e' || s[0] == 'E') {
		s = s[1:]
		switch s[0] {
		case '+', '-':
			s = s[1:]
			if s == "" {
				return false
			}
		}
		for len(s) > 0 && '0' <= s[0] && s[0] <= '9' {
			s = s[1:]
		}
	}

	// The string should be empty now to be valid
	return s == ""
}

@(require_results)
is_valid_string_literal :: proc(str: string, spec: Specification) -> bool {
	s := str
	if len(s) < 2 {
		return false
	}
	quote := s[0]
	if s[0] != s[len(s)-1] {
		return false
	}
	switch quote {
	case '"':
		// okay
	case '\'':
		if spec == .JSON {
			return false
		}
		// okay
	case:
		return false
	}
	s = s[1 : len(s)-1]

	i := 0
	for i < len(s) {
		c := s[i]
		switch {
		case c == '\\':
			i += 1
			if i >= len(s) {
				return false
			}
			switch s[i] {
			case '"', '\\', '/', 'b', 'n', 'r', 't', 'f':
				i += 1
			case '\'':
				// amber-json: \' is JSON5's, not JSON's.
				if spec == .JSON {
					return false
				}
				i += 1
			case '0', 'v':
				// amber-json: JSON5's escapes, which unquote_string reads, pass here too.
				if spec == .JSON {
					return false
				}
				i += 1
			case 'x':
				if spec == .JSON || i+2 >= len(s) || !is_hex(s[i+1]) || !is_hex(s[i+2]) {
					return false
				}
				i += 3

			case '\r':
				if spec != .JSON && i+1 < len(s) && s[i+1] == '\n' {
					i += 2
				} else {
					return false
				}
			case '\n':
				if spec != .JSON {
					i += 1
				} else {
					return false
				}
			case 'u':
				// amber-json: four hexadecimal digits (core took a..z), and a surrogate
				// only as a high one followed by a low one.
				r := hex4(s[i+1:])
				if r < 0 {
					return false
				}
				i += 5
				switch {
				case r >= utf8.SURROGATE_LOW_MIN && r <= utf8.SURROGATE_MAX:
					return false
				case r >= utf8.SURROGATE_MIN && r <= utf8.SURROGATE_HIGH_MAX:
					if i+1 >= len(s) || s[i] != '\\' || s[i+1] != 'u' {
						return false
					}
					r2 := hex4(s[i+2:])
					if r2 < utf8.SURROGATE_LOW_MIN || r2 > utf8.SURROGATE_MAX {
						return false
					}
					i += 6
				}

			case: return false
			}

		case c == quote, c < ' ':
			return false

		case c < utf8.RUNE_SELF:
			i += 1

		case:
			r, width := utf8.decode_rune_in_string(s[i:])
			if r == utf8.RUNE_ERROR && width == 1 {
				return false
			}
			i += width
		}
	}
	return true
}

@(private)
is_hex :: proc(c: byte) -> bool {
	switch c {
	case '0'..='9', 'a'..='f', 'A'..='F':
		return true
	}
	return false
}

// hex4 reads four hexadecimal digits, or gives -1.
@(private)
hex4 :: proc(s: string) -> rune {
	if len(s) < 4 {
		return -1
	}
	r: rune
	for c in transmute([]byte)s[:4] {
		x: rune
		switch c {
		case '0'..='9': x = rune(c - '0')
		case 'a'..='f': x = rune(c - 'a' + 10)
		case 'A'..='F': x = rune(c - 'A' + 10)
		case: return -1
		}
		r = r*16 + x
	}
	return r
}
