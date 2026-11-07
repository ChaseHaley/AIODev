package main

import "aio:settings"
import "aio:ui"
import "core:fmt"
import "core:strings"

editor_process_save :: proc(app: ^App, w: ^Window) {
	p := &w.editor
	value, problem := ui.editor_process_value(p)
	if problem != "" {ui.editor_message(p, problem, true); return}
	updated, message, err := settings.edit_text(p.source, settings.PADDING_GROUPS_KEY, value)
	defer delete(updated)
	defer delete(message)
	if err != nil || message != "" {
		ui.editor_message(p, err != nil ? "Could not prepare program settings." : message, true)
		return
	}
	if result := settings_commit(app, p.source, updated, p); result != .None {
		failure := "Could not save program settings."
		if result == .Conflict {failure = "File changed outside this editor. Reopen Settings to reload it."}
		ui.editor_message(p, failure, true)
		return
	}
	p.process_dirty = false
	ui.editor_message(p, "Saved and applied.", false)
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
	source, source_error := strings.clone(w.editor.source)
	if source_error != nil {
		delete(owned)
		ui.editor_message(&w.editor, "Could not prepare group deletion.", true)
		return
	}
	overlay_open(app, w, nil)
	delete(w.process_remove_name)
	delete(w.process_remove_source)
	w.process_remove_name = owned
	w.process_remove_source, w.process_remove_id = source, group
	ui.confirm_open(&w.process_remove_confirm)
	w.process_remove_confirm.focus = .Cancel
	w.process_remove_confirm.show_option = false
	w.dirty = true
}

editor_process_remove_finish :: proc(app: ^App, w: ^Window, accepted: bool) {
	ui.confirm_close(&w.process_remove_confirm)
	if accepted {
		if w.editor.source != w.process_remove_source {
			ui.editor_message(&w.editor, "Settings changed. Review the group before deleting it.", true)
			w.dirty = true
			return
		}
		ui.editor_process_group_remove(&w.editor, w.process_remove_id)
		editor_process_save(app, w)
	}
	w.dirty = true
}

editor_process_remove_title :: proc(w: ^Window) -> string {
	return fmt.tprintf("Delete %s?", w.process_remove_name)
}
