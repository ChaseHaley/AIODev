package main

import "aio:layout"

// What each kind of pane content may do. A new kind fails to compile until it has an entry here, and
// its own branches in the switches over layout.Content_Kind.
Content_Policy :: struct {
	// A live runtime in app.sessions, keyed by the content id.
	owns_session:      bool,
	// One page per workspace, so the content id is always 0.
	one_per_workspace: bool,
	// May have a linked window.
	linkable:          bool,
}

@(rodata)
CONTENT_POLICY := [layout.Content_Kind]Content_Policy {
	.Terminal = {owns_session = true, linkable = true},
	.Settings = {one_per_workspace = true},
	.Markdown = {},
}

// The title of content that does not title itself through a session.
@(require_results)
content_title :: proc(app: ^App, content: layout.Content) -> string {
	switch content.kind {
	case .Terminal:
	case .Settings:
		return "Settings"
	case .Markdown:
		if pane := markdown_find(app, content.id); pane != nil {return pane.title}
	}
	return ""
}

// Where content lives, shown after its title. Sessions report their own directory.
@(require_results)
content_directory :: proc(app: ^App, content: layout.Content) -> string {
	if content.kind != .Markdown {return ""}
	pane := markdown_find(app, content.id)
	return pane != nil ? pane.directory : ""
}

@(require_results)
content_icon :: proc(kind: layout.Content_Kind) -> string {
	switch kind {
	case .Terminal:
	case .Settings:
		return "⚙"
	case .Markdown:
		return "🗎"
	}
	return ""
}
