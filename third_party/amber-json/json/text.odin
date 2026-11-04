// amber-json's own: reading and rewriting JSON text without building a json.Value, ported from
// amber-lib's amber:json wrapper with its names (members, member, items, decode_string, compact,
// pretty, quote) and write_string_lossy for its write_string. Unlike the wrapper's, every reader
// here checks the whole text with parse's rules first, in strict JSON: text that is not one
// value — a key given twice at any depth, trailing data, JSON5, bad UTF-8, nesting past
// max_depth — is refused, never read partway or passed through.

package json

import "base:runtime"
import "core:io"
import "core:mem/virtual"
import "core:strings"
import "core:unicode/utf8"

// One member of an object: its key, escapes read, and its value's text as written.
Member :: struct {
	key: string,
	raw: string,
}

// members is the object `src`'s members in the order they were written, which a parsed Value's
// map does not keep. The slice and each key are allocated with `allocator`; each `raw` is a
// slice of `src`. False, with nothing allocated, when `src` is not one strict JSON object.
@(require_results)
members :: proc(src: string, allocator := context.allocator, max_depth := DEFAULT_MAX_DEPTH) -> (list: []Member, ok: bool) {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		return nil, false
	}
	defer virtual.arena_destroy(&arena)
	root, err, _, _ := parse_document(src, .JSON, max_depth, virtual.arena_allocator(&arena))
	if err != nil || root.kind != .Object {
		return nil, false
	}
	out, aerr := make([]Member, len(root.keys), allocator)
	if aerr != nil {
		return nil, false
	}
	for key, i in root.keys {
		k, kerr := strings.clone(key, allocator)
		if kerr != nil {
			for m in out[:i] {
				delete(m.key, allocator)
			}
			delete(out, allocator)
			return nil, false
		}
		out[i] = {k, src[root.items[i].offset:root.items[i].end]}
	}
	return out, true
}

// member is the text of the value at `key` in the object `src`, a slice of `src`. False when
// the key is not there or `src` is not one strict JSON object. It allocates nothing that
// outlives the call.
@(require_results)
member :: proc(src: string, key: string, max_depth := DEFAULT_MAX_DEPTH) -> (raw: string, ok: bool) {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		return "", false
	}
	defer virtual.arena_destroy(&arena)
	root, err, _, _ := parse_document(src, .JSON, max_depth, virtual.arena_allocator(&arena))
	if err != nil || root.kind != .Object {
		return "", false
	}
	i := node_find(&root, key)
	if i < 0 {
		return "", false
	}
	return src[root.items[i].offset:root.items[i].end], true
}

// items is the text of each item of the array `src`, in order: the slice allocated with
// `allocator`, each string a slice of `src`. False, with nothing allocated, when `src` is not one
// strict JSON array.
@(require_results)
items :: proc(src: string, allocator := context.allocator, max_depth := DEFAULT_MAX_DEPTH) -> (list: []string, ok: bool) {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		return nil, false
	}
	defer virtual.arena_destroy(&arena)
	root, err, _, _ := parse_document(src, .JSON, max_depth, virtual.arena_allocator(&arena))
	if err != nil || root.kind != .Array {
		return nil, false
	}
	out, aerr := make([]string, len(root.items), allocator)
	if aerr != nil {
		return nil, false
	}
	for &n, i in root.items {
		out[i] = src[n.offset:n.end]
	}
	return out, true
}

// decode_string reads `raw`, one JSON string literal with its quotes (whitespace around it
// allowed), into the text it stands for, allocated with `allocator`. False, with nothing
// allocated, for anything else: a bad escape, a lone surrogate, bytes that are not UTF-8, a
// control character, something after the literal.
@(require_results)
decode_string :: proc(raw: string, allocator := context.allocator) -> (s: string, ok: bool) {
	t := make_tokenizer(raw, .JSON)
	token, err := get_token(&t)
	if err != nil || token.kind != .String {
		return "", false
	}
	if next, nerr := get_token(&t); next.kind != .EOF || (nerr != nil && nerr != .EOF) {
		return "", false
	}
	value, uerr := unquote_string(token, .JSON, allocator)
	if uerr != nil {
		return "", false
	}
	return value, true
}

// compact is `src` with no whitespace outside its strings. Every token is kept as it was
// written: key order, escapes and the spelling of numbers. On an error — `src` is not one strict
// JSON value — the text is empty and the error is parse's.
@(require_results)
compact :: proc(src: string, allocator := context.allocator, max_depth := DEFAULT_MAX_DEPTH) -> (text: string, err: Error) {
	return reformat(src, "", false, allocator, max_depth)
}

// pretty is `src` with each member and item on a line of its own, indented by `indent` per
// level (two spaces unless given), `": "` after each key, and an empty object or array as `{}`
// or `[]`. Like compact it keeps every token as written, and refuses text that is not one strict
// JSON value; amber-lib's wrapper passed such text back unchanged, which a caller still can:
// `text, err := json.pretty(src); if err != nil { text = src }`.
@(require_results)
pretty :: proc(src: string, allocator := context.allocator, indent := "  ", max_depth := DEFAULT_MAX_DEPTH) -> (text: string, err: Error) {
	return reformat(src, indent, true, allocator, max_depth)
}

@(private)
reformat :: proc(src: string, indent: string, pretty: bool, allocator: runtime.Allocator, max_depth: int) -> (text: string, err: Error) {
	check(transmute([]byte)src, .JSON, false, max_depth) or_return
	b, berr := strings.builder_make(0, len(src), allocator)
	if berr != nil {
		return "", .Out_Of_Memory
	}
	newline :: proc(b: ^strings.Builder, pretty: bool, indent: string, depth: int) {
		if pretty {
			strings.write_byte(b, '\n')
			for _ in 0 ..< depth {
				strings.write_string(b, indent)
			}
		}
	}
	// The text has passed parse, so every token is valid and the brackets match.
	t := make_tokenizer(src, .JSON)
	depth := 0
	token, _ := get_token(&t)
	for token.kind != .EOF {
		next, _ := get_token(&t)
		#partial switch token.kind {
		case .Open_Brace, .Open_Bracket:
			strings.write_string(&b, token.text)
			if next.kind == .Close_Brace || next.kind == .Close_Bracket {
				strings.write_string(&b, next.text)
				next, _ = get_token(&t)
			} else {
				depth += 1
				newline(&b, pretty, indent, depth)
			}
		case .Close_Brace, .Close_Bracket:
			depth -= 1
			newline(&b, pretty, indent, depth)
			strings.write_string(&b, token.text)
		case .Comma:
			strings.write_byte(&b, ',')
			newline(&b, pretty, indent, depth)
		case .Colon:
			strings.write_string(&b, ": " if pretty else ":")
		case:
			strings.write_string(&b, token.text)
		}
		token = next
	}
	return strings.to_string(b), nil
}

// quote is `s` as a JSON string literal, quotes included, escaped as marshal escapes it and
// allocated with `allocator`. Text that is not UTF-8 is .Invalid_UTF8 and an empty result, as in
// marshal; write_string_lossy is the form that replaces it.
@(require_results)
quote :: proc(s: string, allocator := context.allocator) -> (text: string, err: Marshal_Error) {
	check_utf8(s) or_return
	b, berr := strings.builder_make(0, len(s) + 2, allocator)
	if berr != nil {
		return "", io.Error.Unknown
	}
	if _, werr := io.write_quoted_string(strings.to_writer(&b), s, '"', nil, true); werr != nil {
		strings.builder_destroy(&b)
		return "", werr
	}
	return strings.to_string(b), nil
}

// write_string_lossy writes `s` to `b` as a JSON string literal, quotes included, with each byte
// that is not part of valid UTF-8 (a stray byte, a cut-off sequence, an encoded surrogate)
// written as U+FFFD. It is the request-body writer amber-lib's write_string was: one stray byte
// in a prompt does not make the request fail. Valid text comes out exactly as marshal writes it.
// It is the one writer here that changes what it was given; marshal, unparse and quote refuse
// such text with .Invalid_UTF8.
write_string_lossy :: proc(b: ^strings.Builder, s: string) {
	w := strings.to_writer(b)
	io.write_byte(w, '"')
	for i := 0; i < len(s); {
		r, width := rune(s[i]), 1
		if r >= utf8.RUNE_SELF {
			r, width = utf8.decode_rune_in_string(s[i:])
		}
		// An invalid byte decodes as RUNE_ERROR, width 1: U+FFFD itself, escaped as marshal
		// escapes a U+FFFD that was written.
		io.write_escaped_rune(w, r, '"', false, nil, true)
		i += width
	}
	io.write_byte(w, '"')
}
