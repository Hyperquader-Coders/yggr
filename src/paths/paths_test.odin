#+test
package paths

import "core:os"
import "core:path/filepath"
import "core:testing"

@(private = "file")
join :: proc(a, b: string) -> string {
	joined, _ := filepath.join({a, b}, context.temp_allocator)
	return joined
}

@(test)
test_expand_home :: proc(t: ^testing.T) {
	home, found := os.lookup_env("HOME", context.temp_allocator)
	if !found || home == "" {
		return
	}
	cases := [][2]string {
		{"~", home},
		{"~/notes/a.odin", join(home, "notes/a.odin")},
		{"~other/x", "~other/x"}, // ~user is not expanded
		{"/etc/hosts", "/etc/hosts"},
		{"a/~/b", "a/~/b"}, // only a leading ~
	}
	for c in cases {
		got := expand_home(c[0], context.temp_allocator)
		testing.expectf(t, got == c[1], "expand_home(%q) = %q, want %q", c[0], got, c[1])
	}
}

@(test)
test_abs :: proc(t: ^testing.T) {
	got, err := abs("/a/b/../c/./d.odin", context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect_value(t, got, "/a/c/d.odin")

	wd, werr := os.get_working_directory(context.temp_allocator)
	testing.expect(t, werr == nil)
	rel, rerr := abs("x/../y.odin", context.temp_allocator)
	testing.expect(t, rerr == nil)
	testing.expect_value(t, rel, join(wd, "y.odin"))

	// Lexical: a path that does not exist still resolves.
	missing, merr := abs("/no/such/dir/../file", context.temp_allocator)
	testing.expect(t, merr == nil)
	testing.expect_value(t, missing, "/no/such/file")
}

@(test)
test_expand :: proc(t: ^testing.T) {
	home, found := os.lookup_env("HOME", context.temp_allocator)
	if !found || home == "" {
		return
	}
	got, err := expand("~/a/../b.odin", context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect_value(t, got, join(home, "b.odin"))
}
