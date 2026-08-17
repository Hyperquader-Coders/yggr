package lsp

// protocol.odin — typed structs for the MVP message subset (SPEC §3).
// json tags follow core:encoding/json marshalling.

Position :: struct {
	line:      int `json:"line"`,
	character: int `json:"character"`, // utf-8 bytes if negotiated, else utf-16 units
}

Range :: struct {
	start: Position `json:"start"`,
	end:   Position `json:"end"`,
}

Text_Document_Identifier :: struct {
	uri: string `json:"uri"`,
}

Versioned_Text_Document_Identifier :: struct {
	uri:     string `json:"uri"`,
	version: int    `json:"version"`,
}

Text_Document_Item :: struct {
	uri:         string `json:"uri"`,
	language_id: string `json:"languageId"`,
	version:     int    `json:"version"`,
	text:        string `json:"text"`,
}

Diagnostic_Severity :: enum int {
	Error       = 1,
	Warning     = 2,
	Information = 3,
	Hint        = 4,
}

Diagnostic :: struct {
	range:    Range  `json:"range"`,
	severity: int    `json:"severity"`, // optional in spec; 0 => treat as Error
	source:   string `json:"source"`,
	message:  string `json:"message"`,
}

Publish_Diagnostics_Params :: struct {
	uri:         string       `json:"uri"`,
	version:     int          `json:"version"`, // 0 when absent; only trust if `has_version`
	diagnostics: []Diagnostic `json:"diagnostics"`,
}

Markup_Content :: struct {
	kind:  string `json:"kind"`, // "markdown" | "plaintext"
	value: string `json:"value"`,
}

Hover_Result :: struct {
	contents: Markup_Content `json:"contents"`,
	// NOTE(agent): servers may also send MarkedString | MarkedString[].
	// Decode into json.Value first and normalize; see client.odin handler.
}

Completion_Item :: struct {
	label:              string     `json:"label"`,
	kind:               int        `json:"kind"`,
	detail:             string     `json:"detail"`,
	insert_text:        string     `json:"insertText"`,
	insert_text_format: int        `json:"insertTextFormat"`, // 2 => snippet: strip $n / ${n:x}
	text_edit:          ^Text_Edit `json:"textEdit"`,
	sort_text:          string     `json:"sortText"`,
}

Text_Edit :: struct {
	range:    Range  `json:"range"`,
	new_text: string `json:"newText"`,
}

Formatting_Options :: struct {
	tab_size:      int  `json:"tabSize"`,
	insert_spaces: bool `json:"insertSpaces"`,
}

// ---- initialize request params (SPEC §4.1) --------------------------
// Typed so the wire output is exact: positionEncodings ["utf-8"], hover
// contentFormat ["markdown","plaintext"], completion snippetSupport false,
// publishDiagnostics versionSupport true.

Initialize_Params :: struct {
	process_id:        int                 `json:"processId"`,
	root_uri:          string              `json:"rootUri"`,
	workspace_folders: []Workspace_Folder  `json:"workspaceFolders"`,
	capabilities:      Client_Capabilities `json:"capabilities"`,
}

// Modern LSP project root; some servers (e.g. OLS) only set up their project
// and run diagnostics when workspaceFolders is present, not rootUri alone.
Workspace_Folder :: struct {
	uri:  string `json:"uri"`,
	name: string `json:"name"`,
}

Client_Capabilities :: struct {
	general:       General_Capabilities       `json:"general"`,
	text_document: Text_Document_Capabilities `json:"textDocument"`,
}

General_Capabilities :: struct {
	position_encodings: []string `json:"positionEncodings"`, // ["utf-8"]
}

Text_Document_Capabilities :: struct {
	hover:               Hover_Capabilities       `json:"hover"`,
	completion:          Completion_Capabilities  `json:"completion"`,
	publish_diagnostics: Publish_Diag_Capabilities `json:"publishDiagnostics"`,
}

Hover_Capabilities :: struct {
	content_format: []string `json:"contentFormat"`, // ["markdown","plaintext"]
}

Completion_Capabilities :: struct {
	completion_item: Completion_Item_Capabilities `json:"completionItem"`,
}

Completion_Item_Capabilities :: struct {
	snippet_support: bool `json:"snippetSupport"`, // false in MVP
}

Publish_Diag_Capabilities :: struct {
	version_support: bool `json:"versionSupport"`, // true
}

// CompletionItemKind → symbolic icon name (SPEC §4.4).
completion_kind_icon :: proc(kind: int) -> string {
	switch kind {
	case 2, 3:  return "lang-method-symbolic"     // method, function
	case 5, 10: return "lang-struct-field-symbolic" // field, property
	case 6:     return "lang-variable-symbolic"
	case 7, 22: return "lang-class-symbolic"       // class, struct
	case 9:     return "lang-namespace-symbolic"
	case 14:    return "completion-word-symbolic"  // keyword
	case:       return "completion-snippet-symbolic"
	}
}
