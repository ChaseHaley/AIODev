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
