// amber-json's own: the Report, as amber-toml's toml/report.odin has it (same author, copied and
// changed where JSON differs): an issue names the JSON path of the value, `claims.aud[1]`,
// rather than a table and a key, and a Source holds the positions of its object's keys rather
// than borrowing a tree that unmarshal frees.

package json

import "base:runtime"
import "core:fmt"
import "core:strings"

Severity :: enum u8 {
	Warning, // noted; the value was adjusted or ignored
	Error,   // the value was refused; the field keeps what it had
}

Issue_Kind :: enum u8 {
	Parse,            // the document is not JSON
	Type_Mismatch,    // a string for a number, null for a field that is not a Maybe, 1.5 for an integer
	Out_Of_Range,
	Clamped,          // out of range, and the nearest bound used
	Length_Mismatch,
	Unknown_Enum,
	Missing_Key,
	Unknown_Key,
	Duplicate,
	Unsupported_Type, // a field type unmarshal does not fill
	Bad_Tag,          // the schema is wrong, not the document
	Rule,             // added by the program, through issue_at
}

// Where a value was written: 1-based line, and 1-based byte column. Zero when there is no
// document to point into.
Position :: struct {
	line:   int,
	column: int,
}

// One thing wrong with a document. `path` is the JSON path of the value it is about —
// `claims.aud[1]`, `keys[kid="k1"].alg`, "" for the document itself — and the message begins
// with it.
Issue :: struct {
	kind:     Issue_Kind,
	severity: Severity,
	position: Position,
	path:     string,
	message:  string,
}

// Every issue found, in the order found. The strings are allocated with `allocator`, so a report
// outlives the document it describes; with an arena, freeing the arena frees it.
// `stop_at_error` makes unmarshal return at the first Error; Warnings never stop it.
Report :: struct {
	issues:        [dynamic]Issue,
	errors:        int,
	stop_at_error: bool,
	allocator:     runtime.Allocator,
}

report_init :: proc(r: ^Report, stop_at_error := false, allocator := context.allocator) {
	r^ = {
		issues        = make([dynamic]Issue, allocator),
		stop_at_error = stop_at_error,
		allocator     = allocator,
	}
}

// report_destroy frees what the report allocated; with an arena, freeing the arena does the
// same.
report_destroy :: proc(r: ^Report) {
	for i in r.issues {
		delete(i.path, r.allocator)
		delete(i.message, r.allocator)
	}
	delete(r.issues)
	r^ = {}
}

// A field that holds where a struct was read from: the object's path, its position, and where
// each of its keys was written. unmarshal fills it, marshal leaves it out, and issue_at uses it
// to report a program's own rules at the right line. Allocated with unmarshal's allocator, as
// the struct's strings are.
Source :: struct {
	name:      string,
	position:  Position,
	keys:      []string,
	positions: []Position,
}

// issue_at adds a program's own finding — a rule between fields, or between entries — at `key`
// of the object `src` came from, or at the object itself when `key` is "" or absent.
issue_at :: proc(r: ^Report, src: Source, key: string, severity: Severity, format: string, args: ..any) {
	at := src.position
	for k, i in src.keys {
		if k == key && i < len(src.positions) {
			at = src.positions[i]
			break
		}
	}
	path := key == "" ? src.name : join_path(src.name, key, context.temp_allocator)
	message := fmt.tprintf(format, ..args)
	if path != "" {
		message = fmt.tprintf("%s: %s", path, message)
	}
	report_add(r, .Rule, severity, at, path, "%s", message)
}

// has_issue says whether `r` already holds an Error at `key` of the object `src` came from, or
// anywhere inside the object or array `key` names — so a program's rule does not judge a field
// that was refused and kept its default, and report a second error about a value the person
// never wrote.
has_issue :: proc(r: ^Report, src: Source, key: string) -> bool {
	inside := join_path(src.name, key, context.temp_allocator)
	for i in r.issues {
		if i.severity != .Error {
			continue
		}
		// `n`, `n.port`, `n[2]`: the value itself, or one below it.
		if strings.has_prefix(i.path, inside) && (len(i.path) == len(inside) || i.path[len(inside)] == '.' || i.path[len(inside)] == '[') {
			return true
		}
	}
	return false
}

// Whether `r` already has an issue of `kind` saying `message`.
@(private)
reported :: proc(r: ^Report, kind: Issue_Kind, message: string) -> bool {
	for i in r.issues {
		if i.kind == kind && i.message == message {
			return true
		}
	}
	return false
}

// issue_string is one issue as a person reads it:
// `token.json:1:52: claims.aud[1] "x" is not one of (a, b)`, with `warning: ` after the position
// for a Warning, and without a position where there is none.
issue_string :: proc(file: string, i: Issue, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	write_issue(&b, file, i)
	return strings.to_string(b)
}

// write_report writes every issue, one per line.
write_report :: proc(b: ^strings.Builder, file: string, r: ^Report) {
	for i in r.issues {
		write_issue(b, file, i)
		strings.write_byte(b, '\n')
	}
}

@(private)
write_issue :: proc(b: ^strings.Builder, file: string, i: Issue) {
	strings.write_string(b, file)
	if i.position != {} {
		fmt.sbprintf(b, ":%d:%d", i.position.line, i.position.column)
	}
	strings.write_string(b, ": ")
	if i.severity == .Warning {
		strings.write_string(b, "warning: ")
	}
	strings.write_string(b, i.message)
}

@(private)
report_add :: proc(r: ^Report, kind: Issue_Kind, severity: Severity, at: Position, path: string, format: string, args: ..any) {
	a := r.allocator
	append(&r.issues, Issue{
		kind     = kind,
		severity = severity,
		position = at,
		path     = strings.clone(path, a),
		message  = fmt.aprintf(format, ..args, allocator = a),
	})
	if severity == .Error {
		r.errors += 1
	}
}

// Where unmarshal is, as a chain of frames on the stack: nothing is allocated to know it, and
// the path is built only when an issue is added. A frame is a key (`index` -1) or an item of an
// array (`index` its number, and its `label` when a field tagged label named it, `label_key`
// being that field's key).
@(private)
Path_Frame :: struct {
	parent:    ^Path_Frame,
	key:       string,
	index:     int,
	label:     string,
	label_key: string,
}

// `claims.aud[1]`, `keys[kid="k1"].alg`, `headers["x-id"]`.
@(private)
frame_name :: proc(f: ^Path_Frame, allocator: runtime.Allocator) -> string {
	if f == nil {
		return ""
	}
	parent := frame_name(f.parent, context.temp_allocator)
	if f.index < 0 {
		return join_path(parent, f.key, allocator)
	}
	if f.label != "" {
		return fmt.aprintf("%s[%s=%q]", parent, f.label_key, f.label, allocator = allocator)
	}
	return fmt.aprintf("%s[%d]", parent, f.index, allocator = allocator)
}

// `parent.key`, or `parent["key"]` when the key is not a plain name.
@(private)
join_path :: proc(parent, key: string, allocator: runtime.Allocator) -> string {
	if !is_plain_key(key) {
		return fmt.aprintf("%s[%q]", parent, key, allocator = allocator)
	}
	if parent == "" {
		return strings.clone(key, allocator)
	}
	return strings.concatenate({parent, ".", key}, allocator)
}

// A key that reads unambiguously after a `.`: letters, digits, `_` and `-`, not empty.
@(private)
is_plain_key :: proc(key: string) -> bool {
	if key == "" {
		return false
	}
	for c in transmute([]byte)key {
		switch c {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '_', '-':
		case:
			return false
		}
	}
	return true
}

// The line and column of byte `offset` of `data`, or {} for a negative offset.
@(private)
offset_position :: proc(data: string, offset: int) -> Position {
	if offset < 0 {
		return {}
	}
	line, start := 1, 0
	for i in 0 ..< min(offset, len(data)) {
		if data[i] == '\n' {
			line += 1
			start = i + 1
		}
	}
	return {line = line, column = offset - start + 1}
}
