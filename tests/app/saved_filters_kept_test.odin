package app_test

import "core:strings"
import "core:testing"
import app "../../src"
import "aio:ui"

@(private)
SAVED_FILTERS_SETTINGS :: `turns.saved_filters = "#00000001 One | a; #00000002 Two | b c; #00000003 Three | !vendor/"` + "\n"

// A field the user typed into and left, which is not a filter field, is still saved when the next thing
// they do is a filter action: the action takes only filter fields into itself.
@(test)
a_filter_action_leaves_another_kept_field_to_its_own_save :: proc(t: ^testing.T) {
	f: Profile_Fixture
	defer profile_fixture_destroy(t, &f)
	if !profile_fixture_create(t, &f, "filterkept", SAVED_FILTERS_SETTINGS) {return}
	w := f.state.windows[0]
	e := profile_open(&f)
	ui.editor_filter_toggle(e, 1)
	if !testing.expect(t, ui.editor_select_key(e, "interface.font_size")) {return}
	ui.field_set(&e.value, "13")
	ui.editor_focus_row(e)
	if !testing.expect(t, ui.editor_select_key(e, "filter.1.name")) {return}
	ui.editor_request_set(e, ui.Filter_Edit{kind = .Remove, id = 1})
	app.editor_outcome(&f.state, w, .Filter_Action)
	testing.expect(t, profile_file_has(f.path, "interface.font_size = 13"))
	text := profile_file_text(f.path)
	testing.expect(t, strings.contains(text, "turns.saved_filters = \"#00000002 Two | b c; #00000003 Three | !vendor/\""), text)
	testing.expect_value(t, f.state.settings.turns.saved_filters, "#00000002 Two | b c; #00000003 Three | !vendor/")
}

// A filter field typed into and left goes with its own filter through a Remove of an earlier one.
@(test)
a_kept_filter_field_survives_removing_an_earlier_filter :: proc(t: ^testing.T) {
	f: Profile_Fixture
	defer profile_fixture_destroy(t, &f)
	if !profile_fixture_create(t, &f, "filterown", SAVED_FILTERS_SETTINGS) {return}
	w := f.state.windows[0]
	e := profile_open(&f)
	ui.editor_filter_toggle(e, 2)
	if !testing.expect(t, ui.editor_select_key(e, "filter.2.name")) {return}
	ui.field_set(&e.value, "Renamed")
	ui.editor_focus_row(e)
	if !testing.expect(t, ui.editor_select_key(e, "interface.font_size")) {return}
	ui.editor_request_set(e, ui.Filter_Edit{kind = .Remove, id = 1})
	app.editor_outcome(&f.state, w, .Filter_Action)
	filters := f.state.settings.turns.saved_filters
	testing.expect_value(t, filters, "#00000002 Renamed | b c; #00000003 Three | !vendor/")
}
