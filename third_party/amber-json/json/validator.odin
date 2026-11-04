// Derived from Odin's core:encoding/json at dev-2026-08 (8412dc3), Copyright (c) 2016-2025
// Ginger Bill, under the zlib licence in third_party/odin/LICENSE.
// Altered for amber-json: is_valid is parse's answer, and has check; a depth limit.
// Each change is marked "amber-json:" where it is made.

package json

import "core:mem/virtual"

// is_valid is true when `data` parses: one value and nothing after it, no key twice in an
// object, no deeper than max_depth, every string UTF-8 with no lone surrogate.
//
// amber-json: core's skipped duplicate keys and trailing data. This one parses into an arena it
// frees before it returns, so the answer is parse's own.
@(require_results)
is_valid :: proc(data: []byte, spec := DEFAULT_SPECIFICATION, parse_integers := false, max_depth := DEFAULT_MAX_DEPTH) -> bool {
	return check(data, spec, parse_integers, max_depth) == nil
}

// check is is_valid with the reason: the error parse would give, or nil.
@(require_results)
check :: proc(data: []byte, spec := DEFAULT_SPECIFICATION, parse_integers := false, max_depth := DEFAULT_MAX_DEPTH) -> Error {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		return .Out_Of_Memory
	}
	defer virtual.arena_destroy(&arena)
	_, err := parse_bytes(data, spec, parse_integers, virtual.arena_allocator(&arena), max_depth)
	return err
}

// validate_value and the procedures below it check the grammar without allocating, as core's
// is_valid did: they do not see duplicate keys, and the caller checks for trailing data.

@(require_results)
validate_object_key :: proc(p: ^Parser) -> bool {
	if p.spec != .JSON {
		if allow_token(p, .Ident) {
			return true
		}
	}
	err := expect_token(p, .String)
	return err == .None
}

@(require_results)
validate_object_body :: proc(p: ^Parser, end_token: Token_Kind) -> bool {
	for p.curr_token.kind != end_token {
		if !validate_object_key(p) {
			return false
		}
		if parse_colon(p) != nil {
			return false
		}
		validate_value(p) or_return

		if parse_comma(p) {
			break
		}
		if trailing_comma(p, end_token) != nil {
			return false
		}
	}
	return true
}

@(require_results)
validate_object :: proc(p: ^Parser) -> bool {
	if enter(p) != nil {
		return false
	}
	defer leave(p)
	if err := expect_token(p, .Open_Brace); err != .None {
		return false
	}

	validate_object_body(p, .Close_Brace) or_return

	if err := expect_token(p, .Close_Brace); err != .None {
		return false
	}
	return true
}

@(require_results)
validate_array :: proc(p: ^Parser) -> bool {
	if enter(p) != nil {
		return false
	}
	defer leave(p)
	if err := expect_token(p, .Open_Bracket); err != .None {
		return false
	}

	for p.curr_token.kind != .Close_Bracket {
		if !validate_value(p) {
			return false
		}

		if parse_comma(p) {
			break
		}
		if trailing_comma(p, .Close_Bracket) != nil {
			return false
		}
	}

	if err := expect_token(p, .Close_Bracket); err != .None {
		return false
	}

	return true
}

@(require_results)
validate_value :: proc(p: ^Parser) -> bool {
	token := p.curr_token

	#partial switch token.kind {
	case .Null, .False, .True:
		advance_token(p)
		return true
	case .Integer, .Float:
		advance_token(p)
		return true
	case .String:
		advance_token(p)
		return is_valid_string_literal(token.text, p.spec)

	case .Open_Brace:
		return validate_object(p)

	case .Open_Bracket:
		return validate_array(p)

	case .Ident:
		if p.spec == .MJSON {
			advance_token(p)
			return true
		}
		return false

	case:
		if p.spec != .JSON {
			#partial switch token.kind {
			case .Infinity, .NaN:
				advance_token(p)
				return true
			}
		}
	}

	return false
}
