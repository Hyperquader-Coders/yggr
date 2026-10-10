package lsp

import "core:encoding/json"
import "core:strings"

// hover_contents normalizes a textDocument/hover result to one string.
// Hover.contents is a MarkupContent {kind, value}, a MarkedString (a Markdown
// string, or {language, value} meaning a code block), or an array of
// MarkedStrings. The text is Markdown unless the server sent a MarkupContent
// whose kind is not "markdown" (in practice "plaintext"), in which case
// `plaintext` is true. A null or empty result gives "". The text is allocated
// with `allocator`.
hover_contents :: proc(result: json.Value, allocator := context.allocator) -> (text: string, plaintext: bool) {
	obj, ok := result.(json.Object)
	if !ok do return "", false
	b := strings.builder_make(allocator)
	#partial switch c in obj["contents"] {
	case json.String:
		strings.write_string(&b, string(c))
	case json.Object:
		if kind, is_markup := c["kind"].(json.String); is_markup {
			plaintext = kind != "markdown"
			value, _ := c["value"].(json.String)
			strings.write_string(&b, string(value))
		} else {
			write_marked_string(&b, c)
		}
	case json.Array:
		for item in c {
			part := strings.builder_make(context.temp_allocator)
			#partial switch it in item {
			case json.String: strings.write_string(&part, string(it))
			case json.Object: write_marked_string(&part, it)
			}
			if len(strings.trim_space(strings.to_string(part))) == 0 do continue
			if len(b.buf) > 0 do strings.write_string(&b, "\n\n")
			strings.write_string(&b, strings.to_string(part))
		}
	}
	if len(strings.trim_space(strings.to_string(b))) == 0 {
		strings.builder_destroy(&b)
		return "", false
	}
	return strings.to_string(b), plaintext
}

// A MarkedString object {language, value} is a code block: write it as a
// Markdown fence longer than any backtick run inside the value.
@(private = "file")
write_marked_string :: proc(b: ^strings.Builder, obj: json.Object) {
	value, _ := obj["value"].(json.String)
	language, _ := obj["language"].(json.String)
	if len(value) == 0 do return
	longest, run := 0, 0
	for i in 0 ..< len(value) {
		run = run + 1 if value[i] == '`' else 0
		longest = max(longest, run)
	}
	fence := strings.repeat("`", max(3, longest + 1), context.temp_allocator)
	strings.write_string(b, fence)
	strings.write_string(b, string(language))
	strings.write_byte(b, '\n')
	strings.write_string(b, string(value))
	strings.write_byte(b, '\n')
	strings.write_string(b, fence)
}
