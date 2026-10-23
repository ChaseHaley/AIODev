package app_test

import app "../../src"
import "aio:input"
import "aio:layout"
import "aio:platform"
import "aio:ui"
import "core:testing"

@(test)
field_edit_failed_clipboard_preserves_unicode_selection :: proc(t: ^testing.T) {
	s: app.App
	ui.notices_init(&s.notices)
	defer ui.notices_destroy(&s.notices)
	f: ui.Text_Field
	defer delete(f.bytes)
	// An uninitialized platform is a deterministic clipboard failure without an OS write.
	for e in ([?]platform.Key_Event{
		{key = .X, modifiers = {.Control}, pressed = true},
		{key = .X, modifiers = {.Control, .Shift}, pressed = true},
		{key = .Delete, modifiers = {.Shift}, pressed = true},
		{key = .V, modifiers = {.Control}, pressed = true},
		{key = .Insert, modifiers = {.Shift}, pressed = true},
	}) {
		ui.field_set(&f, "aé🙂z")
		f.anchor, f.cursor = 7, 1
		edit := app.field_edit_key(&s, &f, e)
		testing.expect_value(t, edit.change, ui.Field_Change.None)
		testing.expect(t, !edit.pasted)
		testing.expect_value(t, ui.field_string(&f), "aé🙂z")
		testing.expect_value(t, f.anchor, 7)
		testing.expect_value(t, f.cursor, 1)
	}
	testing.expect_value(t, len(s.notices.items), 1)
	if len(s.notices.items) == 1 {
		testing.expect_value(t, s.notices.items[0].text, "Could not copy to the clipboard.")
	}
}

@(test)
field_edit_empty_releases_and_nonclipboard_keys :: proc(t: ^testing.T) {
	s: app.App
	ui.notices_init(&s.notices)
	defer ui.notices_destroy(&s.notices)
	f: ui.Text_Field
	defer delete(f.bytes)
	ui.field_set(&f, "é🙂")
	for e in ([?]platform.Key_Event{
		{key = .C, modifiers = {.Control}, pressed = true},
		{key = .Insert, modifiers = {.Control}, pressed = true},
		{key = .X, modifiers = {.Control}, pressed = true},
		{key = .Delete, modifiers = {.Shift}, pressed = true},
	}) {
		testing.expect_value(t, app.field_edit_key(&s, &f, e).change, ui.Field_Change.None)
	}
	testing.expect_value(t, len(s.notices.items), 0)
	ui.field_select_all(&f)
	for e in ([?]platform.Key_Event{
		{key = .X, modifiers = {.Control}}, {key = .Delete, modifiers = {.Shift}},
		{key = .V, modifiers = {.Control}}, {key = .Insert, modifiers = {.Shift}},
		{key = .C, modifiers = {.Control, .Super}, pressed = true},
	}) {
		testing.expect_value(t, app.field_edit_key(&s, &f, e).change, ui.Field_Change.None)
		testing.expect_value(t, ui.field_selected_text(&f), "é🙂")
	}
	testing.expect_value(t, len(s.notices.items), 0)
	testing.expect_value(t, app.field_edit_key(&s, &f,
		{key = .V, modifiers = {.Control, .Alt}, pressed = true, text = "漢"}).change,
		ui.Field_Change.Edited)
	testing.expect_value(t, ui.field_string(&f), "漢")
	testing.expect_value(t, app.field_edit_key(&s, &f,
		{key = .Arrow_Left, pressed = true}).change, ui.Field_Change.Moved)
	testing.expect_value(t, f.cursor, 0)
}

@(test)
field_edit_clipboard_and_direct_consumer_events :: proc(t: ^testing.T) {
	s: app.App
	ui.notices_init(&s.notices)
	defer ui.notices_destroy(&s.notices)
	if !testing.expect_value(t, platform.init(&s.platform, "AIODev.Test.Work154"),
		platform.Init_Result.Primary) {return}
	defer testing.expect_value(t, platform.destroy(&s.platform), platform.Error.None)
	previous, saved := platform.clipboard_get_text(&s.platform, context.allocator)
	if !testing.expect(t, saved) {return}
	defer {
		testing.expect(t, platform.clipboard_set_text(&s.platform, previous))
		delete(previous)
	}
	f: ui.Text_Field
	defer delete(f.bytes)
	for e in ([?]platform.Key_Event{
		{key = .C, modifiers = {.Control}, pressed = true},
		{key = .C, modifiers = {.Control, .Shift}, pressed = true},
		{key = .Insert, modifiers = {.Control}, pressed = true},
		{key = .X, modifiers = {.Control}, pressed = true},
		{key = .X, modifiers = {.Control, .Shift}, pressed = true},
		{key = .Delete, modifiers = {.Shift}, pressed = true},
	}) {
		ui.field_set(&f, "aé🙂z")
		f.anchor, f.cursor = 7, 1
		edit := app.field_edit_key(&s, &f, e)
		cut := e.key == .X || e.key == .Delete
		testing.expect_value(t, edit.change, cut ? ui.Field_Change.Edited : ui.Field_Change.None)
		testing.expect_value(t, ui.field_string(&f), cut ? "az" : "aé🙂z")
		copied, ok := platform.clipboard_get_text(&s.platform, context.allocator)
		testing.expect(t, ok)
		testing.expect_value(t, copied, "é🙂")
		delete(copied)
	}
	for modifiers in ([?]input.Modifiers{{.Control}, {.Control, .Shift}, {.Shift}}) {
		testing.expect(t, platform.clipboard_set_text(&s.platform, "漢\n🙂\té\x7f"))
		ui.field_set(&f, "az")
		f.anchor, f.cursor = 1, 1
		edit := app.field_edit_key(&s, &f,
			{key = modifiers == {.Shift} ? .Insert : .V, modifiers = modifiers, pressed = true})
		testing.expect(t, edit.pasted)
		testing.expect_value(t, ui.field_string(&f), "a漢🙂éz")
		testing.expect_value(t, f.cursor, 10)
		testing.expect_value(t, f.anchor, f.cursor)
	}
	testing.expect(t, platform.clipboard_set_text(&s.platform, ""))
	ui.field_select_all(&f)
	empty := app.field_edit_key(&s, &f, {key = .V, modifiers = {.Control}, pressed = true})
	testing.expect(t, empty.pasted)
	testing.expect_value(t, ui.field_string(&f), "")
	empty = app.field_edit_key(&s, &f, {key = .V, modifiers = {.Control}, pressed = true})
	testing.expect(t, empty.pasted && empty.change == .None)

	workspace := app.workspace_create_empty(&s)
	if !testing.expect(t, workspace != nil) {return}
	defer {app.workspace_destroy(workspace); delete(s.workspaces)}
	tree := layout.Layout{root = layout.INVALID_NODE, focus = layout.INVALID_NODE}
	w := app.Window{id = 154, workspace = workspace, tree = &tree, width = 600, height = 400, scale = 1}
	append(&s.windows, &w)
	defer {
		delete(s.windows)
		delete(w.rename.bytes)
		delete(w.workspace_picker.rows)
		delete(w.workspace_picker.query.bytes)
		delete(w.workspace_picker.saved_query.bytes)
		delete(w.tab_controls)
		delete(w.tab_positions)
		delete(w.panes)
		delete(w.dividers)
	}
	w.rename_open, w.rename_workspace = true, true
	ui.field_set(&w.rename, "old")
	ui.field_select_all(&w.rename)
	testing.expect(t, platform.clipboard_set_text(&s.platform, "  漢\n🙂  "))
	app.handle_event(&s, platform.Key_Event{window = w.id, key = .V, modifiers = {.Control}, pressed = true})
	testing.expect_value(t, ui.field_string(&w.rename), "  漢🙂  ")
	ui.field_select_all(&w.rename)
	app.handle_event(&s, platform.Key_Event{window = w.id, key = .C, unshifted = 'x',
		modifiers = {.Control}, pressed = true})
	testing.expect_value(t, ui.field_selected_text(&w.rename), "  漢🙂  ")
	app.handle_event(&s, platform.Key_Event{window = w.id, key = .V, modifiers = {.Control}})
	testing.expect_value(t, ui.field_string(&w.rename), "  漢🙂  ")
	app.handle_event(&s, platform.Key_Event{window = w.id, key = .Enter, pressed = true})
	testing.expect_value(t, workspace.name, "漢🙂")
	testing.expect(t, !w.rename_open)

	app.workspace_picker_open(&s, &w)
	testing.expect(t, platform.clipboard_set_text(&s.platform, "漢\n🙂"))
	app.handle_event(&s, platform.Key_Event{window = w.id, key = .V, modifiers = {.Control}, pressed = true})
	testing.expect_value(t, ui.field_string(&w.workspace_picker.query), "漢🙂")
	testing.expect_value(t, len(w.workspace_picker.rows), 1)
	ui.field_select_all(&w.workspace_picker.query)
	// The picker receives logical layout keys; rename retains its existing raw-key policy.
	app.handle_event(&s, platform.Key_Event{window = w.id, key = .C, unshifted = 'x',
		modifiers = {.Control}, pressed = true})
	testing.expect_value(t, ui.field_string(&w.workspace_picker.query), "")
	app.workspace_row_rename_open(&s, &w, workspace.id)
	app.handle_event(&s, platform.Key_Event{window = w.id, key = .Insert, modifiers = {.Shift}, pressed = true})
	testing.expect_value(t, ui.field_string(&w.rename), "漢🙂")
	app.handle_event(&s, platform.Key_Event{window = w.id, key = .Enter, pressed = true})
	testing.expect_value(t, app.workspace_picker_target(&w.workspace_picker, .Rename), u32(0))
	testing.expect_value(t, workspace.name, "漢🙂")
	app.workspace_row_icon_open(&s, &w, workspace.id)
	ui.field_set(&w.workspace_picker.query, "")
	w.workspace_picker.selected = 0
	testing.expect(t, platform.clipboard_set_text(&s.platform, "\n\t"))
	app.handle_event(&s, platform.Key_Event{window = w.id, key = .V, modifiers = {.Control}, pressed = true})
	testing.expect_value(t, ui.field_string(&w.workspace_picker.query), "")
	testing.expect_value(t, w.workspace_picker.selected, len(app.WORKSPACE_ICONS))
}
