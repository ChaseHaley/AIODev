package main

import "aio:layout"
import "aio:links"
import "aio:localpath"
import "aio:ui"
import "core:log"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"

// Files, folders and web pages pinned to a pane, tab or workspace, to reopen from the pane header. A
// pane's list lives with its content, so it follows the pane through every move between tabs and windows.
Document :: struct {
	// A web address, or an absolute local path.
	target: string,
	folder: bool `json:"folder,omitempty"`,
}

Document_Level :: enum {
	Pane,
	Tab,
	Workspace,
}

Document_List :: [dynamic]Document

DOCUMENT_LEVEL_LIMIT :: 16
// Every path a link can resolve to fits, and so does any address worth pinning.
@(private)
DOCUMENT_TARGET_LIMIT :: links.TARGET_BYTES

// The lists one pane can see. A nil pane list means its content takes no pins of its own.
Document_Scopes :: struct {
	pane, tab, workspace: ^Document_List,
}

Document_Row :: struct {
	document: Document,
	level:    Document_Level,
}

Document_Pin_Result :: enum {
	Pinned,
	Level_Full,
	Failed,
}

documents_destroy :: proc(list: ^Document_List) {
	for document in list {delete(document.target)}
	delete(list^)
	list^ = nil
}

@(require_results)
document_is_web :: proc(target: string) -> bool {return links.allowed(target)}

// Web addresses are case sensitive past the host, and local paths are not.
@(private, require_results)
document_same :: proc(a, b: string) -> bool {
	return document_is_web(a) ? a == b : strings.equal_fold(a, b)
}

@(private)
document_list_remove :: proc(list: ^Document_List, target: string) -> bool {
	for document, i in list {
		if document_same(document.target, target) {
			delete(document.target)
			ordered_remove(list, i)
			return true
		}
	}
	return false
}

@(private, require_results)
document_list_has :: proc(list: ^Document_List, target: string) -> bool {
	for document in list {if document_same(document.target, target) {return true}}
	return false
}

@(private, require_results)
document_list_append :: proc(list: ^Document_List, document: Document) -> bool {
	target, err := strings.clone(document.target)
	if err != nil {return false}
	if _, append_error := append(list, Document{target, document.folder}); append_error != nil {
		delete(target)
		log.error("storing a pinned document failed")
		return false
	}
	return true
}

// The name a row shows first, and what tells it apart from another of that name.
@(require_results)
document_label :: proc(document: Document, allocator := context.allocator) -> (name, detail: string) {
	if document_is_web(document.target) {
		rest := document.target[strings.index(document.target, "://") + 3:]
		end := strings.index_any(rest, "/?#")
		host, path := rest, ""
		if end >= 0 {host, path = rest[:end], rest[end:]}
		host = strings.trim_prefix(host, "www.")
		if path == "/" {path = ""}
		name, _ = strings.clone(host, allocator)
		detail, _ = strings.clone(path, allocator)
		return
	}
	trimmed := strings.trim_right(document.target, "\\/")
	// The folders nearest the file tell two of the same name apart; a row has no room for the rest.
	directory := filepath.dir(trimmed)
	start := len(directory)
	for _ in 0 ..< 2 {
		at := strings.last_index_any(directory[:start], "\\/")
		if at < 0 {start = 0; break}
		start = at
	}
	detail, _ = strings.clone(strings.trim_left(directory[start:], "\\/"), allocator)
	name, _ = strings.clone(filepath.base(trimmed), allocator)
	return
}

@(require_results)
document_icon :: proc(document: Document) -> ui.Icon {
	switch {
	case document_is_web(document.target):
		return .Globe
	case document.folder:
		return .Folder
	case markdown_is_path(document.target):
		return .Markdown
	}
	return .Document
}

// The lists `content` can see, wherever it is shown: a linked window's own workspace is a private
// view, so its tab and workspace are found through what the pane shows.
@(require_results)
document_scopes :: proc(app: ^App, content: layout.Content) -> (scopes: Document_Scopes, found: bool) {
	for workspace in app.workspaces {
		if workspace.provisional {continue}
		for tab in workspace.tabs {
			if layout.find_content(&tab.tree, content) == layout.INVALID_NODE {continue}
			return {content_documents(app, content), &tab.documents, &workspace.documents}, true
		}
	}
	return {}, false
}

@(require_results)
document_scope_list :: proc(scopes: Document_Scopes, level: Document_Level) -> ^Document_List {
	switch level {
	case .Pane:
		return scopes.pane
	case .Tab:
		return scopes.tab
	case .Workspace:
		return scopes.workspace
	}
	return nil
}

// Every document the pane can see, sorted by level and then by name. A document pinned at several
// levels shows at its narrowest. The rows borrow from the lists.
@(require_results)
documents_visible :: proc(scopes: Document_Scopes, allocator := context.temp_allocator) -> []Document_Row {
	rows := make([dynamic]Document_Row, 0, 3 * DOCUMENT_LEVEL_LIMIT, allocator)
	for level in Document_Level {
		list := document_scope_list(scopes, level)
		if list == nil {continue}
		start := len(rows)
		next: for document in list {
			for row in rows {if document_same(row.document.target, document.target) {continue next}}
			append(&rows, Document_Row{document, level})
		}
		group := rows[start:]
		slice.sort_by(group, proc(a, b: Document_Row) -> bool {
			first, _ := document_label(a.document, context.temp_allocator)
			second, _ := document_label(b.document, context.temp_allocator)
			lower_first := strings.to_lower(first, context.temp_allocator)
			lower_second := strings.to_lower(second, context.temp_allocator)
			return lower_first < lower_second
		})
	}
	return rows[:]
}

// Pins `document` at `level`. One the pane can already see moves there instead of appearing twice. A
// full level changes nothing.
@(require_results)
document_pin :: proc(
	scopes: Document_Scopes,
	level: Document_Level,
	document: Document,
) -> Document_Pin_Result {
	destination := document_scope_list(scopes, level)
	if destination == nil {return .Failed}
	present := document_list_has(destination, document.target)
	if !present && len(destination) >= DOCUMENT_LEVEL_LIMIT {return .Level_Full}
	// The caller's document may borrow from a list about to give it up, so the stored copy and the
	// destination's room exist before any list changes. A target already there frees its own slot.
	target, err := strings.clone(document.target)
	if err != nil {return .Failed}
	if !present && reserve(destination, len(destination) + 1) != nil {
		delete(target)
		log.error("storing a pinned document failed")
		return .Failed
	}
	for other in Document_Level {
		if list := document_scope_list(scopes, other); list != nil {_ = document_list_remove(list, target)}
	}
	append(destination, Document{target, document.folder})
	return .Pinned
}

document_remove :: proc(scopes: Document_Scopes, level: Document_Level, target: string) -> bool {
	list := document_scope_list(scopes, level)
	return list != nil && document_list_remove(list, target)
}

@(private, require_results)
document_valid :: proc(target: string) -> bool {
	if target == "" || len(target) > DOCUMENT_TARGET_LIMIT || !utf8.valid_string(target) {return false}
	return document_is_web(target) || localpath.local_absolute(target)
}

// Takes what a saved layout holds. A hand-edited or damaged entry never reaches an opener.
documents_restore :: proc(list: ^Document_List, saved: []Document) {
	for document in saved {
		if len(list) >= DOCUMENT_LEVEL_LIMIT {
			log.warn("ignoring saved documents past the level limit")
			return
		}
		if !document_valid(document.target) {
			log.warn("ignoring a saved document with an unusable target")
			continue
		}
		if !document_list_has(list, document.target) {_ = document_list_append(list, document)}
	}
}

documents_copy :: proc(list: ^Document_List, from: []Document) {
	for document in from {
		if !document_list_append(list, document) {return}
	}
}
