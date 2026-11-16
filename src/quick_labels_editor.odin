package main

import "aio:settings"
import "aio:ui"

// Saves one change to the quick labels. The page rows own the label text, so every change rebuilds
// the whole `turns.quick_labels` value from them and saves it as one setting. A refusal rings the
// field's row, or for a field the user moved off (`kept`) says why on that row.
@(private)
editor_labels_edit :: proc(app: ^App, w: ^Window, edit: ui.Label_Edit, kept := false) {
	p := &w.editor
	value, select_key, problem := ui.editor_quick_labels_value(p, edit)
	if problem != "" {
		if kept {
			editor_kept_refused(p, "", edit.key, problem)
		} else {
			ui.editor_message(p, problem, true)
		}
		return
	}
	result := settings_change(app, Setting_Value{settings.QUICK_LABELS_KEY, value}, editor_field_base(p, kept))
	if kept && result.status == .Refused {
		editor_kept_refused(p, "", edit.key, result.message)
		return
	}
	message := "Saved and applied."
	focus := Reveal_Focus.None
	switch edit.kind {
	case .Field:
	case .Add:
		message, focus = "Label added. Name it and pick its color.", .Control
	case .Reset:
		message = "Labels reset to the defaults."
	case .Remove:
		message = "Label removed."
	case .Move:
		message, focus = "Label order saved. Alt+1 to Alt+9 follow it.", .Control
	}
	editor_table_saved(w, result, .Setting, select_key, message, focus, edit.kind == .Field)
}
