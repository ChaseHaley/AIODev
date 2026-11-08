package main

import "aio:links"
import "aio:localpath"
import "core:log"
import "core:path/filepath"
import "core:strings"

// Opening a target: one dispatch for terminal links, Markdown links, pinned documents and the
// Markdown picker. Each source turns its own spelling into a Target first; how sources differ lives
// in those constructors, not in copies of the dispatch.

// The system effects that hand a target over. start composes the real ones. An App without them,
// such as a test fixture that never installs a stub, refuses every target in every build rather than
// launching a browser or a file.
Target_Opener :: struct {
	url:  proc(uri: string) -> bool,
	file: proc(path, approved: string) -> bool,
}

// nil means nothing there reads as a target, which leaves the input to its other uses. Strings
// borrow the caller's buffer for the synchronous call.
Target :: union {
	Web_Target,
	File_Target,
	Missing_Target,
}

// An allowed http(s) address.
Web_Target :: struct {
	uri: string,
}

// A local path; opening prepares it again, so a file that went away is reported then.
File_Target :: struct {
	path: string,
}

// Text that reads as a local file that is not there.
Missing_Target :: struct {}

// Files a target opens in a Markdown pane instead of the system's handler, and what the Markdown
// picker offers. Explicit rendering (markdown.open, restored panes) accepts other safe files too.
@(private)
MARKDOWN_SHORT :: ".md"
@(private)
MARKDOWN_LONG :: ".markdown"
@(private)
MARKDOWN_EXTENSIONS :: [?]string{MARKDOWN_SHORT, MARKDOWN_LONG}
@(private)
MARKDOWN_FILTER :: "*" + MARKDOWN_SHORT + ";*" + MARKDOWN_LONG

markdown_is_path :: proc(path: string) -> bool {
	extension := filepath.ext(path)
	for markdown in MARKDOWN_EXTENSIONS {
		if strings.equal_fold(extension, markdown) {return true}
	}
	return false
}

// A pinned document holds an allowed web address or a canonical local path, opened as a click on
// the link it came from would open it.
@(require_results)
target_from_document :: proc(document: string) -> Target {
	if document_is_web(document) {return Web_Target{document}}
	return File_Target{document}
}

// A Markdown href. A '#' fragment is link syntax there, so it is dropped before a local path resolves
// beside the document; a printed terminal path may contain '#' literally and keeps it. The path
// borrows buffer.
@(require_results)
target_from_href :: proc(href, document_path: string, buffer: []u8) -> Target {
	if links.allowed(href) {return Web_Target{href}}
	spelling := href
	if fragment := strings.index_byte(spelling, '#'); fragment >= 0 {spelling = spelling[:fragment]}
	directory := filepath.dir(document_path)
	path, ok := links.resolve_file(spelling, directory, localpath.local_hosts(), buffer)
	if !ok {return Missing_Target{}}
	return File_Target{path}
}

target_open :: proc(app: ^App, w: ^Window, target: Target) {
	switch t in target {
	case Web_Target:
		if !target_open_url(app, t.uri) {notify(app, .Error, "Could not open the link.")}
	case File_Target:
		target_open_file(app, w, t.path)
	case Missing_Target:
		target_unavailable(app)
	}
}

target_unavailable :: proc(app: ^App) {
	notify(app, .Error, "That local file is not available.")
}

// The active file a confirmation asks before opening.
Pending_File :: struct {
	file: localpath.Open_File,
}

// A Markdown file opens in a pane; any other file goes to the system, after a confirmation when its
// type is active.
@(private)
target_open_file :: proc(app: ^App, w: ^Window, path: string) {
	file, ok := localpath.prepare_open(path)
	if !ok {target_unavailable(app); return}
	if !file.confirm && markdown_is_path(file.target) {
		defer localpath.open_file_destroy(&file)
		markdown_open_focused(app, w, file.target)
		return
	}
	if !file.confirm {
		defer localpath.open_file_destroy(&file)
		if !target_open_approved(app, file.path, "") {notify(app, .Error, "Could not open the file.")}
		return
	}
	if !gesture_cancel(app, w) {localpath.open_file_destroy(&file); return}
	confirmation_ask(app, w, Pending_File{file}, extended = true, focus = .Cancel)
}

pending_file_text :: proc(pending: Pending_File) -> Confirmation_Text {
	return {
		title = "Open this file?",
		body = filepath.base(pending.file.target),
		note = pending.file.target,
		label = "Open",
	}
}

@(private)
pending_file_finish :: proc(app: ^App, pending: Pending_File, accept: bool) {
	if accept && !target_open_approved(app, pending.file.path, pending.file.target) {
		notify(app, .Error, "Could not open the file.")
	}
}

pending_file_destroy :: proc(pending: ^Pending_File) {
	localpath.open_file_destroy(&pending.file)
}

@(private, require_results)
target_open_url :: proc(app: ^App, uri: string) -> bool {
	if app.opener.url == nil {
		log.error("a web target was opened without a composed opener")
		return false
	}
	if !app.opener.url(uri) {
		log.errorf("opening the web target failed: %s", uri)
		return false
	}
	return true
}

// approved is the confirmed target, or empty when no confirmation was shown.
@(private, require_results)
target_open_approved :: proc(app: ^App, path, approved: string) -> bool {
	if app.opener.file == nil {
		log.warn("a file target was opened without a composed opener")
		return false
	}
	return app.opener.file(path, approved)
}
