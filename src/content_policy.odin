package main

import "aio:layout"
import "aio:render"
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
	// The badge a tab, float capsule or pane shows for the content; terminals show their shell's instead.
	icon:              ui.Icon,
	// Shown in a keycap as a pane header's badge in place of the icon.
	header_glyph:      string,
	// What the kind is called where it has no title of its own.
	display_name:      string,
}

@(rodata)
CONTENT_POLICY := [layout.Content_Kind]Content_Policy {
	.Terminal = {owns_session = true, linkable = true, documents = true, display_name = "Terminal"},
	.Settings = {one_per_workspace = true, icon = .Settings, header_glyph = "⚙", display_name = "Settings"},
	.Markdown = {documents = true, icon = .Markdown, display_name = "Markdown"},
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

// The title a pane shows: its session's name or reported title, else the content's own.
@(require_results)
content_pane_title :: proc(app: ^App, entry: ^Session_Entry, content: layout.Content) -> string {
	if entry != nil {return session_display_title(entry)}
	return content_title(app, content)
}

// What a pane's badge shows: an icon, or with none a keycap of the glyph or the image at atlas.
Content_Badge :: struct {
	icon:  ui.Icon,
	glyph: string,
	atlas: render.Rect,
}

// A session's program icon or shell badge `size` pixels square, else the kind's icon, or in a pane header
// the kind's glyph where it has one.
@(require_results)
content_badge :: proc(
	app: ^App,
	entry: ^Session_Entry,
	kind: layout.Content_Kind,
	size: f32,
	header := false,
) -> (
	badge: Content_Badge,
	result: render.Build_Status,
) {
	policy := CONTENT_POLICY[kind]
	switch {
	case policy.owns_session:
		badge.glyph, badge.atlas, result = pane_icon(app, entry, size)
	case header && policy.header_glyph != "":
		badge.glyph = policy.header_glyph
	case:
		badge.icon = policy.icon
	}
	return
}

// Where content lives, shown after its title. Sessions report their own directory.
@(require_results)
content_directory :: proc(app: ^App, content: layout.Content) -> string {
	if content.kind != .Markdown {return ""}
	pane := markdown_find(app, content.id)
	return pane != nil ? pane.directory : ""
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
