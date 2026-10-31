package gtkenv

// Copied from amber-lib's amber_gtkenv (gtkenv.odin and its test), so this public repository
// builds on its own; only the package name differs. A change goes to amber-lib first.

// Package gtkenv fixes up the environment a GTK4 app needs *before* it calls gtk_init.
//
// It exists because the amber apps ship a **bundled GTK** (amber-gtk4) rather than
// Mint's: kat800 needs 4.16 for VTE, and one GTK across the suite beats two. A bundle
// built for size has no input-method modules — `lib/gtk-4.0` holds a print backend and
// nothing else, where the distro's holds `immodules/libim-ibus.so` — so unless GTK is
// told where the system's modules are, **IME input silently stops working**: no dialog,
// no error, just a warning in a crash log nobody reads until a user reports that they
// cannot type Japanese.
//
// Toolkit-free on purpose — it is only environment variables — so it links into an app
// that has not initialised GTK yet, which is the only moment setting these has any effect.

import "core:os"
import "core:strings"

// Where a distro keeps its GTK4 loadable modules, most specific first. Debian and Ubuntu
// (so Mint) use the multiarch path; the other two cover a non-multiarch or 64-bit-suffix
// layout so this is not silently Debian-only.
@(private)
MODULE_DIRS := []string{"/usr/lib/x86_64-linux-gnu/gtk-4.0", "/usr/lib64/gtk-4.0", "/usr/lib/gtk-4.0"}

// use_system_modules points GTK at the distro's module directory, and reports the one it
// chose ("" when none exists or the caller had already set GTK_PATH).
//
// Call it before gtk_init. GTK reads GTK_PATH once, while it builds its module search
// path, and never looks again.
//
// GTK_PATH is *prepended* to GTK's built-in search path rather than replacing it, so this
// is additive: an app running against the system GTK is unaffected, and one running
// against the bundle gains the modules the bundle lacks. That is why there is no
// am-I-bundled test here — a check that could be wrong is worse than a call that is
// always right.
//
// An existing GTK_PATH is never overwritten. Someone who set it meant it, and this would
// be exactly the wrong thing to silently undo.
use_system_modules :: proc() -> string {
	if _, set := os.lookup_env("GTK_PATH", context.temp_allocator); set {
		return ""
	}
	for dir in MODULE_DIRS {
		if !os.exists(dir) {continue}
		if os.set_env("GTK_PATH", dir) != nil {return ""}
		return dir
	}
	return ""
}

// module_dir returns the distro module directory that use_system_modules would pick,
// without touching the environment. Split out so a caller can report or log it — and so
// the choice is testable without mutating the process.
module_dir :: proc() -> string {
	for dir in MODULE_DIRS {
		if os.exists(dir) {return dir}
	}
	return ""
}

// has_immodules reports whether `dir` actually carries input-method modules. The point of
// the exercise is IME input, and a module directory that exists but is empty buys
// nothing — a bundled prefix has exactly that shape.
has_immodules :: proc(dir: string) -> bool {
	if dir == "" {return false}
	// GTK4 versions its module directory: <dir>/4.0.0/immodules.
	path := strings.concatenate({dir, "/4.0.0/immodules"}, context.temp_allocator)
	if !os.exists(path) {return false}
	fd, err := os.open(path)
	if err != nil {return false}
	defer os.close(fd)
	entries, rerr := os.read_dir(fd, -1, context.temp_allocator)
	if rerr != nil {return false}
	for e in entries {
		if strings.has_suffix(e.name, ".so") {return true}
	}
	return false
}
