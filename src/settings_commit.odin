package main

import "aio:settings"
import "aio:ui"
import "core:os"
import "core:strings"

// Saves and publishes exactly one internal revision. Only pages based on expected advance:
// a page predating an external edit must still fail the file conflict check. The origin accepts
// its saved field; other pages retain pending text and selection while receiving the new source.
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
	loaded, diagnostics, parse_error := settings.parse(revision, themes_directory = settings.theme_directory())
	defer settings.destroy(&loaded)
	defer settings.diagnostics_destroy(&diagnostics)
	if parse_error != nil {return .IO}
	if result := settings.save(app.settings_path, previous, revision); result != .None {return result}
	settings_prepare_reload(app)
	settings_apply_revision(app, loaded, &diagnostics)
	loaded = {}
	settings_apply_running(app)
	for window in app.windows {
		p := &window.editor
		if !p.open || p.source != previous {continue}
		settings_publish_page(app, p, revision, p != origin)
		window.dirty = true
	}
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

@(private)
settings_publish_page :: proc(app: ^App, p: ^ui.Editor, revision: string, preserve_draft: bool) {
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
	replacement.expanded, view.expanded = view.expanded, ""
	replacement.remove_confirm, view.remove_confirm = view.remove_confirm, ""
	replacement.detected_open = view.detected_open
	replacement.process_expanded = view.process_expanded
	replacement.profile_positions, view.profile_positions = view.profile_positions, {}
	if !settings_load_source(app, &replacement, revision) {return}
	if p.process_dirty {
		if preserve_draft && p.process_source != replacement.process_source {return}
		if ui.editor_process_copy_draft(p, &replacement) != nil {
			notify(app, .Error, "Could not preserve program drafts.")
			return
		}
	}
	ui.field_set(&replacement.filter, ui.field_string(&p.filter))
	ui.editor_filter(&replacement)
	row := ui.editor_row(p)
	selected := row != nil && ui.editor_reveal(&replacement, row.key)
	draft := preserve_draft && row != nil &&
	         (ui.field_string(&p.value) != row.value || p.capturing || p.process_dirty)
	// Removing a field being edited is a semantic conflict. Keep that page and its old source
	// intact, so saving cannot silently recreate a removed profile or discard its draft.
	if draft && !selected {return}
	replacement.filter.cursor, replacement.filter.anchor = p.filter.cursor, p.filter.anchor
	replacement.scroll = clamp(p.scroll, 0, max(0, len(replacement.items) - max(1, p.visible_rows)))
	if selected {
		replacement.focus = p.focus
		replacement.profile_control = p.profile_control
		// A multiple choice saves each option as it flips; keep its popup open for the next one.
		if next_row := ui.editor_row(&replacement); p.popup == .Choice && row.multiple && next_row.multiple {
			replacement.popup, replacement.popup_index, replacement.popup_scroll =
				.Choice, p.popup_index, p.popup_scroll
		}
		// A picker drag saves on release while its popup remains open. Keep its hue and
		// saturation even at black, where rebuilding them from the saved RGB loses both.
		if next_row := ui.editor_row(&replacement); p.popup == .Color && next_row.kind == row.kind {
			replacement.popup = .Color
			before, after := ui.field_string(&p.value), ui.field_string(&replacement.value)
			previous_color, previous_ok, _ := settings.parse_color(before)
			next_color, next_ok, _ := settings.parse_color(after)
			if previous_ok && next_ok && previous_color == next_color {replacement.hsv = p.hsv}
		}
	}
	if draft {
		delete(replacement.value.bytes)
		replacement.value, p.value = p.value, {}
		replacement.capturing, replacement.leader_pending = p.capturing, p.leader_pending
		replacement.captured, replacement.physical = p.captured, p.physical
		replacement.shortcut_index = p.shortcut_index
		replacement.popup, replacement.popup_index, replacement.popup_scroll =
			p.popup, p.popup_index, p.popup_scroll
		replacement.hsv = p.hsv
		ui.editor_message(&replacement, p.message, p.error)
		if p.error_key != "" {
			ui.editor_error_set(&replacement, p.error_profile, p.error_key, p.error_text)
		}
	}
	ui.editor_destroy(p)
	p^, replacement = replacement, {}
}
