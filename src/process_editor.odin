package main

import "aio:settings"
import "aio:ui"
import "core:fmt"
import "core:strings"

editor_process_save :: proc(app: ^App, w: ^Window) {
	p := &w.editor
	value, problem := ui.editor_process_value(p)
	if problem != "" {ui.editor_message(p, problem, true); return}
	updated, message, err := settings.edit_text(ui.editor_source(p), settings.PADDING_GROUPS_KEY, value)
	defer delete(updated)
	defer delete(message)
	if err != nil || message != "" {
		ui.editor_message(p, err != nil ? "Could not prepare program settings." : message, true)
		return
	}
	if result := settings_commit(app, ui.editor_source(p), updated, p); result != .None {
		failure := "Could not save program settings."
		if result == .Conflict {failure = "File changed outside this editor. Reopen Settings to reload it."}
		ui.editor_message(p, failure, true)
		return
	}
	p.process_dirty = false
	ui.editor_message(p, "Saved and applied.", false)
}

// The program group a confirmation asks before deleting: its name for the question, and the settings
// text the question was asked against, so a file changed meanwhile is reviewed before anything goes.
Process_Remove :: struct {
	name, source: string,
	group:        int,
}

editor_process_remove_ask :: proc(app: ^App, w: ^Window, group: int) {
	if !ui.editor_process_capture(&w.editor) {return}
	name := ""
	for row in w.editor.rows {
		if row.process == group && row.process_field == .Group {name = row.title; break}
	}
	if name == "" {return}
	owned, err := strings.clone(name)
	if err != nil {ui.editor_message(&w.editor, "Could not prepare group deletion.", true); return}
	source, source_error := strings.clone(ui.editor_source(&w.editor))
	if source_error != nil {
		delete(owned)
		ui.editor_message(&w.editor, "Could not prepare group deletion.", true)
		return
	}
	overlay_open(app, w, nil)
	confirmation_open(w, Process_Remove{name = owned, source = source, group = group}, focus = .Cancel)
}

@(private)
editor_process_remove_finish :: proc(app: ^App, w: ^Window, remove: Process_Remove, accepted: bool) {
	if !accepted {return}
	if ui.editor_source(&w.editor) != remove.source {
		ui.editor_message(&w.editor, "Settings changed. Review the group before deleting it.", true)
		return
	}
	ui.editor_process_group_remove(&w.editor, remove.group)
	editor_process_save(app, w)
}

editor_process_remove_destroy :: proc(remove: ^Process_Remove) {
	delete(remove.name)
	delete(remove.source)
}

editor_process_remove_text :: proc(remove: Process_Remove) -> Confirmation_Text {
	return {title = fmt.tprintf("Delete %s?", remove.name), label = "Delete"}
}
