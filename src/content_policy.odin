package main

import "aio:layout"
import "aio:ui"
import "core:fmt"

// What each kind of pane content may do. A new kind fails to compile until it has an entry here, and
// its own branches in the switches over layout.Content_Kind.
Content_Policy :: struct {
	// A live runtime in app.sessions, keyed by the content id.
	owns_session:      bool,
	// One page per workspace, so the content id is always 0.
	one_per_workspace: bool,
	// May have a linked window.
	linkable:          bool,
	// Has a Documents button and its own pinned documents.
	documents:         bool,
	// The badge a tab shows for its focused content; terminals show their shell's badge instead.
	icon:              ui.Icon,
	// The glyph beside a pane title.
	icon_text:         string,
	// What the kind is called where it has no title of its own.
	display_name:      string,
}

@(rodata)
CONTENT_POLICY := [layout.Content_Kind]Content_Policy {
	.Terminal = {owns_session = true, linkable = true, documents = true, display_name = "Terminal"},
	.Settings = {one_per_workspace = true, icon = .Settings, icon_text = "⚙", display_name = "Settings"},
	.Markdown = {documents = true, icon = .Markdown, icon_text = "🗎", display_name = "Markdown"},
}

// The title of content that does not title itself through a session.
@(require_results)
content_title :: proc(app: ^App, content: layout.Content) -> string {
	switch content.kind {
	case .Terminal:
	case .Settings:
		return CONTENT_POLICY[.Settings].display_name
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
	return CONTENT_POLICY[kind].icon_text
}

@(require_results)
content_tab_icon :: proc(kind: layout.Content_Kind) -> ui.Icon {
	return CONTENT_POLICY[kind].icon
}

// The content's own pinned documents, or nil for a kind without them or content no longer running.
@(require_results)
content_documents :: proc(app: ^App, content: layout.Content) -> ^Document_List {
	switch content.kind {
	case .Terminal:
		if entry := session_find(app, content.id); entry != nil {return &entry.documents}
	case .Markdown:
		if pane := markdown_find(app, content.id); pane != nil {return &pane.documents}
	case .Settings:
	}
	return nil
}

// Why a kind offers no documents, or empty for one that does.
@(require_results)
content_documents_notice :: proc(kind: layout.Content_Kind) -> string {
	policy := CONTENT_POLICY[kind]
	if policy.documents {return ""}
	return fmt.tprintf("%s has no documents of its own.", policy.display_name)
}
