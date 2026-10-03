// Lexical path helpers for the file yggr is given: the leading "~" a user
// types, and a relative path made absolute against the working directory.
// Lexical means the path need not exist and symlinks are not resolved, unlike
// core's filepath.abs, which opens the path. Copied from amber-lib's afs
// (expand_home, abs, expand), so this public repository builds on its own.
package paths

import "core:os"
import "core:path/filepath"
import "core:strings"

// expand_home expands a leading "~" or "~/" to $HOME: "~" becomes home and
// "~/x" becomes home/x. "~user" is not supported (as in Go) and is returned
// unchanged, as is any path when HOME is unset or empty. The result is always
// freshly allocated with `allocator`.
expand_home :: proc(path: string, allocator := context.allocator) -> string {
	if path == "~" || strings.has_prefix(path, "~/") {
		if home, found := os.lookup_env("HOME", context.temp_allocator); found && home != "" {
			return strings.concatenate({home, path[1:]}, allocator)
		}
	}
	return strings.clone(path, allocator)
}

// abs returns a lexical absolute path: an absolute path is cleaned, and a
// relative one is joined to the working directory and cleaned. It mirrors Go's
// filepath.Abs. The result is allocated with `allocator`.
abs :: proc(path: string, allocator := context.allocator) -> (result: string, err: os.Error) {
	if os.is_absolute_path(path) {
		cleaned, _ := filepath.clean(path, allocator)
		return cleaned, nil
	}
	wd := os.get_working_directory(context.temp_allocator) or_return
	joined, _ := filepath.join({wd, path}, context.temp_allocator)
	cleaned, _ := filepath.clean(joined, allocator)
	return cleaned, nil
}

// expand is expand_home, then abs: the one call for a path a user typed, so
// "~/x", "./x", "../x" and "x" all resolve the same way. The result is
// allocated with `allocator`.
expand :: proc(path: string, allocator := context.allocator) -> (result: string, err: os.Error) {
	return abs(expand_home(path, context.temp_allocator), allocator)
}
