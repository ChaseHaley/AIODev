package main

import "aio:settings"
import "aio:views"

// Saves one change to the saved filters. The page rows own the filter text, so every change rebuilds
// the whole `turns.saved_filters` value from them and saves it as one setting. A refusal rings the
// field's row with the reason; for a field the user moved off (`kept`) it says why on that row. A
// `pending` field is one the user left without Enter just before this action: it is applied to the
// rows first so a Move or Remove cannot save it onto another filter. Returns whether it applied, and
// if it did not, the open filter and the settling blocks are as they were.
@(private)
editor_filters_edit :: proc(
	app: ^App,
	w: ^Window,
	edit: views.Filter_Edit,
	kept := false,
	pending: views.Editor_Kept = {},
) -> bool {
	p := &w.editor
	expanded := p.filter_expanded
	value, select_key, problem := views.editor_saved_filters_value(p, edit, pending)
	if problem != "" {
		views.editor_saved_filters_undo(p, edit, expanded)
		editor_filters_refused(p, edit, problem, kept)
		return false
	}
	result := settings_change(app, Setting_Value{settings.SAVED_FILTERS_KEY, value}, editor_field_base(p, kept))
	if result.status != .Applied {views.editor_saved_filters_undo(p, edit, expanded)}
	if result.status == .Refused {
		editor_filters_refused(p, edit, result.message, kept)
		return false
	}
	message := "Saved and applied."
	focus := Reveal_Focus.None
	switch edit.kind {
	case .Field:
	case .Add:
		message, focus = "Filter added. Write its pattern; a name is optional.", .Control
	case .Remove:
		message = "Filter removed."
	case .Move:
		message, focus = "Filter order saved.", .Control
	case .Default:
		message, focus = "Default filters saved. New Agent changes panes start with them on.", .Control
	}
	editor_table_saved(w, result, .Setting, select_key, message, focus, edit.kind == .Field)
	return result.status == .Applied
}

// A filter action (Remove, Move or Add) with the field the user just left, which `kept` holds. Only a
// filter field's text goes into the action, and only when it is a value the filters can hold: any other
// kept field, and an invalid one, stay in `kept` for editor_kept_save, so they cannot block the action
// or be lost by it.
@(private)
editor_filters_action :: proc(app: ^App, w: ^Window, edit: views.Filter_Edit, kept: ^views.Editor_Kept) {
	p := &w.editor
	pending: views.Editor_Kept
	dropped := ""
	if views.editor_kept_is_filter(p, kept^) {
		_, _, problem := views.editor_saved_filters_value(p, {kind = .Field, key = kept.key, value = kept.value})
		if problem == "" {
			pending = kept^
		} else if edit.kind != .Add {
			// Remove and Move renumber the filters, so the row the field was typed in may now be another
			// filter's: the field is dropped with its reason in the status line, and rings no row.
			dropped = problem
			views.editor_kept_destroy(kept)
		}
	}
	if editor_filters_edit(app, w, edit, pending = pending) && pending.key != "" {
		views.editor_kept_destroy(kept)
	}
	if dropped != "" {views.editor_message(p, dropped, true)}
}

// Says why a filter change was refused: on the field's row when one field caused it, as for the
// profile fields, and in the status line.
@(private)
editor_filters_refused :: proc(p: ^views.Editor, edit: views.Filter_Edit, message: string, kept: bool) {
	if kept {
		editor_kept_refused(p, "", edit.key, message)
		return
	}
	if edit.kind == .Field {views.editor_error_set(p, "", edit.key, message)}
	views.editor_message(p, message, true)
}
