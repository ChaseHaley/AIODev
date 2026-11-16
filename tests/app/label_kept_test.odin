package app_test

import "core:strings"
import "core:testing"
import app "../../src"
import "aio:ui"

// A field the user typed into and left, which is not a label field, is still saved when the next thing they
// do is a label action: the action takes only label fields into itself.
@(test)
a_label_action_leaves_another_kept_field_to_its_own_save :: proc(t: ^testing.T) {
	f: Profile_Fixture
	defer profile_fixture_destroy(t, &f)
	if !profile_fixture_create(t, &f, "labelkept", "") {return}
	w := f.state.windows[0]
	e := profile_open(&f)
	ui.editor_label_toggle(e, 1)
	if !testing.expect(t, ui.editor_select_key(e, "interface.font_size")) {return}
	ui.field_set(&e.value, "13")
	ui.editor_focus_row(e)
	// Moving to a label's name keeps the font size, then the label is removed.
	if !testing.expect(t, ui.editor_select_key(e, "label.1.name")) {return}
	ui.editor_request_set(e, ui.Label_Edit{kind = .Remove, id = 1})
	app.editor_outcome(&f.state, w, .Label_Action)
	// Both saves land: the kept font size, and the label action without label 1.
	testing.expect(t, profile_file_has(f.path, "interface.font_size = 13"))
	text := profile_file_text(f.path)
	testing.expect(t, strings.contains(text, "turns.quick_labels = \"Verify this |"))
	testing.expect(t, !strings.contains(text, "Clarify this"))
}

// A label field typed into and left goes with its own label through a Remove of an earlier one.
@(test)
a_kept_label_field_survives_removing_an_earlier_label :: proc(t: ^testing.T) {
	f: Profile_Fixture
	defer profile_fixture_destroy(t, &f)
	if !profile_fixture_create(t, &f, "labelown", "") {return}
	w := f.state.windows[0]
	e := profile_open(&f)
	ui.editor_label_toggle(e, 2)
	if !testing.expect(t, ui.editor_select_key(e, "label.2.name")) {return}
	ui.field_set(&e.value, "Renamed")
	ui.editor_focus_row(e)
	if !testing.expect(t, ui.editor_select_key(e, "interface.font_size")) {return}
	ui.editor_request_set(e, ui.Label_Edit{kind = .Remove, id = 1})
	app.editor_outcome(&f.state, w, .Label_Action)
	labels := f.state.settings.turns.quick_labels
	testing.expect(t, strings.has_prefix(labels, "Renamed |"), labels)
	// The label that took position 2 keeps its own name: the kept rename was applied once, not saved
	// again onto whatever row now holds its old key.
	testing.expect(t, strings.contains(labels, "; Match existing patterns |"), labels)
}
