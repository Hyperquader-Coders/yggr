package lsp

// registry.odin — parse an lsp-servers.conf language→server registry.
// Pure Odin (no GTK, no fs) so it is headless-testable; the UI reads the file
// and passes its text here. Format (see flatpak/lsp-servers.conf):
//   <gtksourceview-language-id>=<command line>
// blank lines and lines starting with '#' are ignored; the command line is
// split on spaces.

import "core:strings"

// Return the split command for `language_id`, or ok=false if absent.
registry_lookup :: proc(conf_text: string, language_id: string, allocator := context.allocator) -> (cmd: []string, ok: bool) {
	text := conf_text
	for line in strings.split_lines_iterator(&text) {
		t := strings.trim_space(line)
		if len(t) == 0 || t[0] == '#' do continue
		eq := strings.index_byte(t, '=')
		if eq < 0 do continue
		key := strings.trim_space(t[:eq])
		val := strings.trim_space(t[eq + 1:])
		if key == language_id && len(val) > 0 {
			return strings.split(val, " ", allocator), true
		}
	}
	return nil, false
}
