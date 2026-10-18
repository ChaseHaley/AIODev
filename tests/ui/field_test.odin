package ui_test

import "core:testing"
import "aio:ui"

@(test)
field_selection_replaces_moves_and_deletes_by_word :: proc(t: ^testing.T) {
	f: ui.Text_Field
	defer delete(f.bytes)
	ui.field_set(&f, "alpha beta")
	testing.expect_value(t, ui.field_key(&f, key({key = .A, modifiers = {.Control}})), ui.Field_Change.Moved)
	testing.expect_value(t, ui.field_key(&f, key({key = .A, modifiers = {.Control}})), ui.Field_Change.None)
	testing.expect_value(t, ui.field_text(&f, "z"), ui.Field_Change.Edited)
	testing.expect_value(t, ui.field_string(&f), "z")
	ui.field_set(&f, "one two  three")
	ui.field_key(&f, key({key = .Arrow_Left, modifiers = {.Control}}))
	testing.expect_value(t, f.cursor, 9)
	ui.field_key(&f, key({key = .Arrow_Left, modifiers = {.Control, .Shift}}))
	testing.expect_value(t, ui.field_selected_text(&f), "two  ")
	ui.field_key(&f, key({key = .Arrow_Right}))
	testing.expect_value(t, f.cursor, 9)
	testing.expect_value(t, ui.field_selected_text(&f), "")
	ui.field_key(&f, key({key = .Backspace, modifiers = {.Control}}))
	testing.expect_value(t, ui.field_string(&f), "one three")
	ui.field_key(&f, key({key = .Delete, modifiers = {.Control}}))
	testing.expect_value(t, ui.field_string(&f), "one ")
	ui.field_key(&f, key({key = .Home, modifiers = {.Shift}}))
	testing.expect_value(t, ui.field_selected_text(&f), "one ")
	ui.field_key(&f, key({key = .Delete}))
	testing.expect_value(t, ui.field_string(&f), "")
	testing.expect_value(t, ui.field_key(&f, key({key = .Backspace})), ui.Field_Change.None)
	testing.expect_value(t, ui.field_text(&f, "\x1b\x7f"), ui.Field_Change.None)
	testing.expect_value(t, ui.field_text(&f, "\xff"), ui.Field_Change.None)
}

@(test)
field_pointer_drag_selects_between_offsets :: proc(t: ^testing.T) {
	f: ui.Text_Field
	defer delete(f.bytes)
	ui.field_set(&f, "héllo")
	testing.expect_value(t, ui.field_pointer(&f, 1, true, false), ui.Field_Change.Moved)
	testing.expect_value(t, ui.field_pointer(&f, 6, false, false), ui.Field_Change.Moved)
	testing.expect_value(t, ui.field_selected_text(&f), "éllo")
	f.dragging = false
	testing.expect_value(t, ui.field_pointer(&f, 0, false, false), ui.Field_Change.None)
	ui.field_pointer(&f, 0, true, true)
	testing.expect_value(t, ui.field_selected_text(&f), "h")
}
