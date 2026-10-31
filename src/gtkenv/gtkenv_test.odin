#+test
package gtkenv

import "base:runtime"
import "core:os"
import "core:strings"
import "core:testing"

// Exporting GTK_PATH is the package's job, so proving it has to touch the process. It does so
// here, once, before the runner starts any test thread (HOUSE_RULES, Tests), and leaves
// GTK_PATH as it found it. The results are written here and nowhere else; the tests read them.
@(private = "file")
OWN_PATH :: "/somewhere/of/my/own"

@(private = "file")
Exported :: struct {
	chosen: string, // what use_system_modules returned
	value:  string, // GTK_PATH after it; "" with `set` false when there is none
	set:    bool,
}

@(private = "file")
with_own_path, with_no_path: Exported

@(private = "file")
want_dir: string

@(init, private = "file")
export_before_any_test :: proc "contextless" () {
	context = runtime.default_context()
	saved, had := os.lookup_env("GTK_PATH", context.allocator)
	defer delete(saved)

	_ = os.set_env("GTK_PATH", OWN_PATH)
	with_own_path = exported_by_use_system_modules()

	_ = os.unset_env("GTK_PATH")
	want_dir = module_dir()
	with_no_path = exported_by_use_system_modules()

	if had {
		_ = os.set_env("GTK_PATH", saved)
	} else {
		_ = os.unset_env("GTK_PATH")
	}
	free_all(context.temp_allocator)
}

// `value` is a copy that lives as long as the test binary: it is made once and read by a test.
@(private = "file")
exported_by_use_system_modules :: proc() -> (e: Exported) {
	e.chosen = use_system_modules()
	e.value, e.set = os.lookup_env("GTK_PATH", context.allocator)
	return e
}

// An existing value is the caller's, and is never overwritten.
@(test)
test_use_system_modules_keeps_a_set_path :: proc(t: ^testing.T) {
	testing.expect_value(t, with_own_path.chosen, "")
	testing.expect(t, with_own_path.set, "GTK_PATH was unset")
	testing.expect_value(t, with_own_path.value, OWN_PATH)
}

// With none set, it picks the distro directory and exports it, which is the whole job. A
// machine with no GTK4 has no directory to pick, and GTK_PATH stays unset.
@(test)
test_use_system_modules_exports_the_distro_directory :: proc(t: ^testing.T) {
	testing.expect_value(t, with_no_path.chosen, want_dir)
	testing.expect_value(t, with_no_path.set, want_dir != "")
	testing.expect_value(t, with_no_path.value, want_dir)
}

// module_dir must name a directory that exists, or nothing was gained by pointing GTK at
// it. It is allowed to find none — a machine with no GTK4 installed is a valid state.
@(test)
test_module_dir_exists_when_found :: proc(t: ^testing.T) {
	dir := module_dir()
	if dir == "" {return}
	testing.expect(t, os.exists(dir), "module_dir returned a path that does not exist")
}

// The reason the package exists: a directory with no immodules in it does not solve the
// IME problem. This asserts the *predicate*, not the machine — a build host with no
// ibus installed is not a failure, so it only checks that a positive answer is backed by
// a real .so.
@(test)
test_has_immodules_is_honest :: proc(t: ^testing.T) {
	testing.expect(t, !has_immodules(""), "an empty path cannot carry modules")
	testing.expect(t, !has_immodules("/nonexistent/gtk-4.0"), "a missing path cannot carry modules")
	if dir := module_dir(); dir != "" && has_immodules(dir) {
		fd, err := os.open(strings.concatenate({dir, "/4.0.0/immodules"}, context.temp_allocator))
		testing.expect(t, err == nil, "has_immodules said yes but the directory will not open")
		if err == nil {os.close(fd)}
	}
}
