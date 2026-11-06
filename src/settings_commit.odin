package main

import "aio:settings"
import "aio:ui"
import "core:os"
import "core:strings"

// How a new settings revision reaches the open settings pages.
Settings_Publication :: union #no_nil {
	Publish_Saved,
	Publish_Reloaded,
	Publish_Unavailable,
	Publish_Reset,
}

// A save from this app. Only pages showing `previous` advance: a page predating an external edit
// must still fail the file conflict check. The origin accepts its saved field; other pages keep
// pending text and selection while receiving the new source.
Publish_Saved :: struct {
	previous, revision: string,
	origin:             ^ui.Editor,
}

// Settings were read from the file again. Every page adopts the file, keeping drafts whose rows remain.
Publish_Reloaded :: struct {
	revision: string,
}

// The file could not be read; running settings fell back to defaults, but pages retain their work.
Publish_Unavailable :: struct {}

// A factory reset. Every page adopts the defaults and drops its drafts and table state.
Publish_Reset :: struct {
	revision: string,
}

// Saves and publishes exactly one internal revision.
@(require_results)
settings_commit :: proc(
	app: ^App,
	expected, updated: string,
	origin: ^ui.Editor = nil,
) -> settings.Save_Error {
	// A caller may borrow either string from a page that publication replaces.
	previous, previous_error := strings.clone(expected, context.temp_allocator)
	revision, revision_error := strings.clone(updated, context.temp_allocator)
	if previous_error != nil || revision_error != nil {return .IO}
	return settings_save_revision(app, previous, revision, Publish_Saved{previous, revision, origin})
}

// Saves `revision` over `expected` and applies it. A conflict means the file no longer holds
// `expected`, so the pages showing it have fallen behind.
@(private, require_results)
settings_save_revision :: proc(
	app: ^App,
	expected, revision: string,
	publication: Settings_Publication,
) -> settings.Save_Error {
	loaded, diagnostics, parse_error := settings.parse(revision, themes_directory = settings.theme_directory())
	defer settings.destroy(&loaded)
	defer settings.diagnostics_destroy(&diagnostics)
	if parse_error != nil {return .IO}
	result := settings.save(app.settings_path, expected, revision)
	if result == .Conflict {
		for window in app.windows {
			p := &window.editor
			if ui.editor_source(p) == expected {ui.editor_revision_stale(p, .Changed_Outside)}
		}
	}
	if result != .None {return result}
	settings_revision_apply(app, loaded, &diagnostics, nil, publication)
	loaded = {}
	return .None
}

// Saves one setting through the file so the change survives and every window applies it. A value
// the schema refuses reports why; other failures report `failure`. Without a settings file, as in
// tests, the caller applies the value itself.
@(require_results)
settings_save_value :: proc(app: ^App, key, value, failure: string) -> (saved, has_file: bool) {
	if app.settings_path == "" {return false, false}
	data, read_error := os.read_entire_file(app.settings_path, context.temp_allocator)
	if read_error != nil {
		notify(app, .Error, failure)
		return false, true
	}
	updated, message, edit_error := settings.edit_text(string(data), key, value)
	defer delete(updated)
	defer delete(message)
	if edit_error == nil && message != "" {
		notify(app, .Error, message)
		return false, true
	}
	warning: string
	if edit_error == nil && (strings.has_prefix(key, settings.KEY_BINDING_PREFIX) || key == "input.leader") {
		problem: string
		problem, warning = editor_validate_bindings(updated, app.settings_path)
		if problem != "" {
			notify(app, .Error, problem)
			return false, true
		}
	}
	if edit_error != nil || settings_commit(app, string(data), updated) != .None {
		notify(app, .Error, failure)
		return false, true
	}
	if warning != "" {notify(app, .Info, warning)}
	return true, true
}

// Shows a new revision on every open settings page. It also ends any Delete Theme prompt, since the
// revision may have changed the theme the prompt named.
@(private)
settings_publish :: proc(app: ^App, publication: Settings_Publication) {
	for window in app.windows {
		theme_delete_disarm(&window.resources)
		p := &window.editor
		if !ui.editor_loaded(p) {continue}
		window.dirty = true
		switch publish in publication {
		case Publish_Saved:
			if ui.editor_source(p) != publish.previous {
				ui.editor_revision_stale(p, .Changed_Outside)
				continue
			}
			settings_publish_page(app, p, publish.revision, p != publish.origin)
		case Publish_Reloaded:
			settings_publish_page(app, p, publish.revision, true)
		case Publish_Unavailable:
			ui.editor_revision_stale(p, .Refresh_Failed)
		case Publish_Reset:
			// The page is built afresh rather than carried over, which drops what the user had open.
			replacement: ui.Editor
			if !settings_load_source(app, &replacement, publish.revision) {
				ui.editor_revision_stale(p, .Refresh_Failed)
				continue
			}
			ui.editor_destroy(p)
			p^ = replacement
		}
	}
}

@(private)
settings_publish_page :: proc(app: ^App, p: ^ui.Editor, revision: string, preserve_draft: bool) {
	// Every way out short of replacing the page leaves it behind the revision.
	reason := ui.Editor_Stale_Reason.Refresh_Failed
	published := false
	defer if !published {ui.editor_revision_stale(p, reason)}
	if !ui.editor_process_capture(p) {
		notify(app, .Error, "Could not preserve the active program draft.")
		return
	}
	replacement: ui.Editor
	defer ui.editor_destroy(&replacement)
	view, view_error := ui.editor_view_take(p)
	defer ui.editor_view_destroy(&view)
	if view_error != nil {
		notify(app, .Error, "Could not refresh the settings page. Reopen Settings to reload it.")
		return
	}
	ui.editor_view_hold(&replacement, &view)
	if !settings_load_source(app, &replacement, revision) {return}
	if p.process_dirty {
		if preserve_draft && p.process_source != replacement.process_source {
			reason = .Draft_Conflict
			return
		}
		if ui.editor_process_copy_draft(p, &replacement) != nil {
			notify(app, .Error, "Could not preserve program drafts.")
			return
		}
	}
	ui.field_set(&replacement.filter, ui.field_string(&p.filter))
	ui.editor_filter(&replacement)
	row := ui.editor_row(p)
	selected := row != nil && ui.editor_reveal(&replacement, row.key)
	draft := preserve_draft && ui.editor_draft(p)
	// Removing a field being edited is a semantic conflict. Keep that page and its old source
	// intact, so saving cannot silently recreate a removed profile or discard its draft.
	if draft && !selected {
		reason = .Draft_Conflict
		return
	}
	replacement.filter.cursor, replacement.filter.anchor = p.filter.cursor, p.filter.anchor
	replacement.scroll = clamp(p.scroll, 0, max(0, len(replacement.items) - max(1, p.visible_rows)))
	if selected {ui.editor_carry(&replacement, p, draft)}
	ui.editor_revision_sync(&replacement)
	ui.editor_destroy(p)
	p^, replacement = replacement, {}
	published = true
}

