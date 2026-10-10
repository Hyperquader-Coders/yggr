#+test
package markup

import "core:testing"

@(private = "file")
expect_pango :: proc(t: ^testing.T, input, want: string, kind := Kind.Markdown, loc := #caller_location) {
	got := to_pango(input, kind, context.temp_allocator)
	testing.expectf(t, got == want, "\ninput: %q\nwant:  %q\ngot:   %q", input, want, got, loc = loc)
}

// What ols sends for a documented proc: signature fence, rule, doc comment.
@(test)
test_ols_hover :: proc(t: ^testing.T) {
	expect_pango(t,
		"```odin\nproj.add :: proc(a, b: int) -> int\n```\n---\nAdds two numbers. Returns **the sum** of `a` and `b`.\n",
		"<tt>proj.add :: proc(a, b: int) -&gt; int</tt>\n\nAdds two numbers. Returns <b>the sum</b> of <tt>a</tt> and <tt>b</tt>.")
}

@(test)
test_fences :: proc(t: ^testing.T) {
	// Multi-line body, blank line kept; tilde fence; info string dropped.
	expect_pango(t, "~~~go\nfunc f() {\n\n}\n~~~", "<tt>func f() {\n\n}</tt>")
	// Markdown inside a fence is literal, markup escaped.
	expect_pango(t, "```\n**x** <b> & `y`\n```", "<tt>**x** &lt;b&gt; &amp; `y`</tt>")
	// A shorter run does not close; a longer one does.
	expect_pango(t, "````\n```\n`````", "<tt>```</tt>")
	// Unclosed fence runs to the end.
	expect_pango(t, "```odin\nx := 1", "<tt>x := 1</tt>")
	// The fence's indentation is removed from the body.
	expect_pango(t, "  ```\n  a\n    b\n  ```", "<tt>a\n  b</tt>")
	// A backtick info string containing a backtick is not a fence.
	expect_pango(t, "```a`b", "```a`b")
	// Text before and after is separated by blank lines.
	expect_pango(t, "before\n```\ncode\n```\nafter", "before\n\n<tt>code</tt>\n\nafter")
}

@(test)
test_indented_code :: proc(t: ^testing.T) {
	expect_pango(t, "Example:\n\n\tfoo()\n\n\tbar()\nend", "Example:\n\n<tt>foo()\n\nbar()</tt>\n\nend")
	expect_pango(t, "    four", "<tt>four</tt>")
	// Cannot interrupt a paragraph: the tab stays as text.
	expect_pango(t, "para\n\tmore", "para\n\tmore")
}

@(test)
test_rules_and_headings :: proc(t: ^testing.T) {
	expect_pango(t, "a\n\n---\n\nb", "a\n\nb")
	expect_pango(t, "a\n* * *\nb", "a\n\nb")
	expect_pango(t, "___", "")
	expect_pango(t, "--", "--")
	expect_pango(t, "# Title #\ntext", "<b>Title</b>\n\ntext")
	expect_pango(t, "### a `b`", "<b>a <tt>b</tt></b>")
	expect_pango(t, "#hashtag", "#hashtag")
	expect_pango(t, "####### seven", "####### seven")
}

@(test)
test_paragraphs_and_lists :: proc(t: ^testing.T) {
	expect_pango(t, "one\ntwo\n\n\nthree\r\n", "one\ntwo\n\nthree")
	expect_pango(t, "- a\n* *b*\n+ c\n  - d", "• a\n• <i>b</i>\n• c\n  • d")
	expect_pango(t, "  lead", "  lead")
	expect_pango(t, "", "")
	expect_pango(t, "\n  \n", "")
}

@(test)
test_inline :: proc(t: ^testing.T) {
	expect_pango(t, "**b** *i* __b__ _i_", "<b>b</b> <i>i</i> <b>b</b> <i>i</i>")
	expect_pango(t, "**bold *nested* x**", "<b>bold <i>nested</i> x</b>")
	expect_pango(t, "***both***", "<b><i>both</i></b>")
	expect_pango(t, "`a` ``b ` c`` ` d `", "<tt>a</tt> <tt>b ` c</tt> <tt>d</tt>")
	// No closer, or whitespace inside the delimiters: literal.
	expect_pango(t, "a * b * c, **x, `y", "a * b * c, **x, `y")
	expect_pango(t, "** x**", "** x**")
	// snake_case and intraword underscores stay literal; intraword * works.
	expect_pango(t, "snake_case_name and _x_y", "snake_case_name and _x_y")
	expect_pango(t, "a*b*c", "a<i>b</i>c")
	// Emphasis delimiters inside a code span do not close.
	expect_pango(t, "*a `*` b*", "<i>a <tt>*</tt> b</i>")
	expect_pango(t, "\\*not\\* \\` \\q", "*not* ` \\q")
}

@(test)
test_links :: proc(t: ^testing.T) {
	expect_pango(t, "See [the docs](https://odin-lang.org) now", "See the docs now")
	expect_pango(t, "[**b** [x]](u(v)) ![alt](i.png)", "<b>b</b> [x] alt")
	expect_pango(t, "<https://x.org/?a=1&b=2> <me@x.org>", "https://x.org/?a=1&amp;b=2 me@x.org")
	// Not links: literal.
	expect_pango(t, "[a] [b](c ![d]", "[a] [b](c ![d]")
}

// Server text is never markup: tags, entities and quotes show literally,
// in every construct, and the output stays well-formed.
@(test)
test_escaping :: proc(t: ^testing.T) {
	expect_pango(t, "<b>not bold</b> &amp; \"q\" 'a'", "&lt;b&gt;not bold&lt;/b&gt; &amp;amp; &quot;q&quot; &apos;a&apos;")
	expect_pango(t, "`<i>` **<span>** [<u>](x) # h", "<tt>&lt;i&gt;</tt> <b>&lt;span&gt;</b> &lt;u&gt; # h")
	expect_pango(t, "# <big>", "<b>&lt;big&gt;</b>")
	expect_pango(t, "</tt></b>", "&lt;/tt&gt;&lt;/b&gt;")
	expect_pango(t, "<b>x</b>", "&lt;b&gt;x&lt;/b&gt;", .Plaintext)
}

@(test)
test_plaintext :: proc(t: ^testing.T) {
	// No Markdown in plain text: fences, rules and emphasis are literal.
	expect_pango(t, "\n```odin\n**x** & y\n---\n\n", "```odin\n**x** &amp; y\n---", .Plaintext)
	expect_pango(t, "  indented", "  indented", .Plaintext)
}

// GMarkup rejects invalid UTF-8 and most control characters; either would
// leave the label empty, so both become U+FFFD. Valid UTF-8 passes through.
@(test)
test_bad_bytes :: proc(t: ^testing.T) {
	expect_pango(t, "a\xffb\x01c\x7f", "a�b�c�")
	expect_pango(t, "`\xfe`", "<tt>�</tt>")
	expect_pango(t, "Größe → *ok*\tend", "Größe → <i>ok</i>\tend")
	expect_pango(t, "\xff", "�", .Plaintext)
}

@(test)
test_with_font :: proc(t: ^testing.T) {
	got := with_font("<tt>x</tt>", "Sans \"Bold\" <10>", context.temp_allocator)
	testing.expect_value(t, got, "<span font_desc=\"Sans &quot;Bold&quot; &lt;10&gt;\"><tt>x</tt></span>")
	testing.expect_value(t, with_font("a", "", context.temp_allocator), "a")
}
