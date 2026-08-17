package ui

// i18n.odin — gettext localization (English source + German catalog shipped
// out of the box). glibc provides gettext/setlocale/bindtextdomain in libc,
// so no separate libintl link is needed. Mark user-visible strings with tr().

import os2 "core:os"
import "core:strings"

foreign import libc "system:c"

// glibc locale.h: LC_ALL == 6.
LC_ALL :: 6
TEXTDOMAIN :: "yggr"

foreign libc {
	setlocale :: proc "c" (category: i32, locale: cstring) -> cstring ---
	bindtextdomain :: proc "c" (domainname: cstring, dirname: cstring) -> cstring ---
	bind_textdomain_codeset :: proc "c" (domainname: cstring, codeset: cstring) -> cstring ---
	textdomain :: proc "c" (domainname: cstring) -> cstring ---
	gettext :: proc "c" (msgid: cstring) -> cstring ---
}

// Initialize localization from the environment (LANG/LC_ALL/LANGUAGE). The
// catalog base dir is the first that actually holds a catalog: $YGGR_LOCALEDIR
// (dev: point it at ./data/locale), the Flatpak path, a user install, or the
// system dir. gettext appends <lang>/LC_MESSAGES/yggr.mo.
i18n_init :: proc() {
	setlocale(LC_ALL, "")

	candidates := [?]string{
		os2.get_env("YGGR_LOCALEDIR", context.allocator),
		"/app/share/locale",
		os2.get_env("HOME", context.allocator) != "" \
			? strings.concatenate({os2.get_env("HOME", context.allocator), "/.local/share/locale"}, context.allocator) \
			: "",
		"/usr/share/locale",
	}
	dir := "/usr/share/locale"
	for c in candidates {
		if c == "" do continue
		if os2.exists(strings.concatenate({c, "/de/LC_MESSAGES/", TEXTDOMAIN, ".mo"}, context.temp_allocator)) {
			dir = c
			break
		}
	}
	dir_c := strings.clone_to_cstring(dir, context.allocator)
	bindtextdomain(TEXTDOMAIN, dir_c)
	bind_textdomain_codeset(TEXTDOMAIN, "UTF-8")
	textdomain(TEXTDOMAIN)
}

// Translate a UI string (returns the msgid itself when no catalog matches,
// i.e. English is the source language and needs no .mo).
tr :: proc(msgid: cstring) -> string {
	return string(gettext(msgid))
}
