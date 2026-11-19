package ui_test

import "aio:settings"
import "aio:ui"
import "core:strings"
import "core:testing"

@(private)
FILTERS_THREE :: "One | a; Two | b c; Three | !vendor/"

@(private)
FILTER_NAME_REFUSAL :: "Enter a name of up to 32 characters without ; | or quotes."

@(private)
FILTER_NAME_TOO_LONG :: "0123456789012345678901234567890123"

@(private)
filters_fixture :: proc(t: ^testing.T, p: ^ui.Editor, value: string = FILTERS_THREE) {
	testing.expect_value(t, ui.editor_saved_filters_load(p, value), nil)
	ui.editor_filter(p)
}

@(private)
filters_value :: proc(t: ^testing.T, p: ^ui.Editor, edit: ui.Filter_Edit) -> (value, select_key: string) {
	problem: string
	value, select_key, problem = ui.editor_saved_filters_value(p, edit)
	testing.expect_value(t, problem, "")
	return
}

@(private)
filters_value_kept :: proc(t: ^testing.T, p: ^ui.Editor, edit: ui.Filter_Edit, key, text: string) -> string {
	value, _, problem := ui.editor_saved_filters_value(p, edit, {key, text})
	testing.expect_value(t, problem, "")
	return value
}

@(test)
saved_filters_load_a_line_and_two_fields_per_filter_with_add :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	filters_fixture(t, &p)
	testing.expect_value(t, label_page_keys(&p), "filter.1,filter.2,filter.3,filter.add")
	heads := 0
	for row in p.rows {
		if row.kind == .Saved_Filter {heads += 1}
		if row.key == "filter.add" {testing.expect_value(t, row.action, ui.Page_Action.Filter_Add)}
	}
	testing.expect_value(t, heads, 3)
	testing.expect_value(t, len(p.rows), 3 * 3 + 1)
	testing.expect_value(t, p.groups[p.rows[0].group].title, "Agent changes")
	testing.expect_value(t, p.rows[0].title, "One")
	testing.expect_value(t, p.rows[0].value, "a")
	testing.expect(t, ui.editor_reveal(&p, ui.Reveal_Row{"filter.2.pattern"}))
	testing.expect_value(t, p.filter_expanded, 2)
	testing.expect_value(
		t,
		label_page_keys(&p),
		"filter.1,filter.2,filter.2.name,filter.2.pattern,filter.3,filter.add",
	)
	testing.expect_value(t, ui.editor_row(&p).value, "b c")
	testing.expect(t, ui.editor_reveal(&p, ui.Reveal_Saved_Filters{}))
	testing.expect_value(t, ui.editor_row(&p).key, "filter.1")
	empty: ui.Editor
	defer ui.editor_destroy(&empty)
	filters_fixture(t, &empty, "")
	testing.expect_value(t, label_page_keys(&empty), "filter.add")
	testing.expect(t, ui.editor_reveal(&empty, ui.Reveal_Saved_Filters{}))
	testing.expect_value(t, ui.editor_row(&empty).key, ui.SAVED_FILTER_ADD_KEY)
}

@(test)
saved_filters_search_finds_a_filter_by_its_pattern :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	filters_fixture(t, &p)
	ui.field_set(&p.filter, "vendor")
	ui.editor_filter(&p)
	testing.expect_value(t, label_page_keys(&p), "filter.3")
}

@(test)
saved_filters_value_is_rebuilt_from_the_rows_and_edits :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	filters_fixture(t, &p)
	value, select_key := filters_value(t, &p, {kind = .Field, key = "filter.1.name", value = "  Uno "})
	testing.expect_value(t, value, "Uno | a; Two | b c; Three | !vendor/")
	testing.expect_value(t, select_key, "filter.1.name")
	value, _ = filters_value(t, &p, {kind = .Field, key = "filter.3.pattern", value = "x | y"})
	testing.expect_value(t, value, "One | a; Two | b c; Three | x | y")
	value, _ = filters_value(t, &p, {kind = .Field, key = "filter.2.pattern", value = " .odin$ "})
	testing.expect_value(t, value, "One | a; Two | .odin$; Three | !vendor/")
	joined := strings.concatenate({settings.SAVED_FILTERS_KEY, " = ", value}, context.temp_allocator)
	s, issues, err := settings.parse(joined)
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&issues)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(issues), 0)
	testing.expect_value(t, s.turns.saved_filters, value)
	// The rows are untouched until the saved value reloads the page.
	testing.expect_value(t, p.rows[0].title, "One")
}

@(test)
saved_filters_refuse_fields_the_setting_cannot_hold_with_a_message :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	filters_fixture(t, &p)
	for c in ([?]struct {
			key, value, message: string,
		}{
			{"filter.1.name", "", FILTER_NAME_REFUSAL},
			{"filter.1.name", "a;b", FILTER_NAME_REFUSAL},
			{"filter.1.name", "a|b", FILTER_NAME_REFUSAL},
			{"filter.1.name", "say \"hi\"", FILTER_NAME_REFUSAL},
			{"filter.1.name", FILTER_NAME_TOO_LONG, FILTER_NAME_REFUSAL},
			{"filter.2.name", " one ", "Another filter already has that name."},
			{"filter.3.name", "TWO", "Another filter already has that name."},
			{"filter.1.pattern", "", "Enter a pattern without ;."},
			{"filter.2.pattern", "a;b", "Enter a pattern without ;."},
			{"filter.2.pattern", "a\nb", "Enter a pattern without ;."},
		}) {
		value, _, problem := ui.editor_saved_filters_value(&p, {kind = .Field, key = c.key, value = c.value})
		testing.expectf(t, value == "" && problem == c.message, "%s = %q: %q", c.key, c.value, problem)
	}
}

@(test)
saved_filters_move_reorders_and_the_open_filter_follows :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	filters_fixture(t, &p)
	testing.expect(t, ui.editor_reveal(&p, ui.Reveal_Row{"filter.1.name"}))
	value, select_key := filters_value(t, &p, {kind = .Move, id = 1, slot = 3})
	testing.expect_value(t, value, "Two | b c; Three | !vendor/; One | a")
	testing.expect_value(t, select_key, "filter.3")
	testing.expect_value(t, p.filter_expanded, 3)

	p.filter_expanded = 2
	value, select_key = filters_value(t, &p, {kind = .Move, id = 3, slot = 0})
	testing.expect_value(t, value, "Three | !vendor/; One | a; Two | b c")
	testing.expect_value(t, select_key, "filter.1")
	testing.expect_value(t, p.filter_expanded, 3)

	p.filter_expanded = 3
	value, _ = filters_value(t, &p, {kind = .Move, id = 1, slot = 2})
	testing.expect_value(t, value, "Two | b c; One | a; Three | !vendor/")
	testing.expect_value(t, p.filter_expanded, 3)

	// A move into the filter's own place changes nothing.
	value, _ = filters_value(t, &p, {kind = .Move, id = 2, slot = 2})
	testing.expect_value(t, value, FILTERS_THREE)
	value, _ = filters_value(t, &p, {kind = .Move, id = 2, slot = 1})
	testing.expect_value(t, value, FILTERS_THREE)
}

@(test)
saved_filters_ctrl_arrows_ask_to_move_one_place_within_the_list :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	filters_fixture(t, &p)
	testing.expect(t, ui.editor_select_key(&p, "filter.2"))
	testing.expect_value(
		t,
		ui.editor_key(&p, key({key = .Arrow_Down, modifiers = {.Control}})),
		ui.Editor_Outcome.Filter_Action,
	)
	request := ui.editor_request_take(&p)
	defer ui.editor_request_destroy(&request)
	edit, ok := request.(ui.Filter_Edit)
	testing.expect(t, ok && edit.kind == .Move && edit.id == 2 && edit.slot == 3)
	value, _ := filters_value(t, &p, edit)
	testing.expect_value(t, value, "One | a; Three | !vendor/; Two | b c")

	testing.expect(t, ui.editor_select_key(&p, "filter.1"))
	testing.expect_value(
		t,
		ui.editor_key(&p, key({key = .Arrow_Up, modifiers = {.Control}})),
		ui.Editor_Outcome.Changed,
	)
	testing.expect(t, ui.editor_request_take(&p) == nil)
	testing.expect(t, ui.editor_select_key(&p, "filter.3"))
	testing.expect_value(
		t,
		ui.editor_key(&p, key({key = .Arrow_Down, modifiers = {.Control}})),
		ui.Editor_Outcome.Changed,
	)
	testing.expect(t, ui.editor_request_take(&p) == nil)
}

@(test)
saved_filters_delete_asks_to_remove_and_enter_opens_the_fields :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	filters_fixture(t, &p)
	testing.expect(t, ui.editor_select_key(&p, "filter.2"))
	testing.expect_value(t, ui.editor_key(&p, key({key = .Enter})), ui.Editor_Outcome.Changed)
	testing.expect_value(t, p.filter_expanded, 2)
	testing.expect_value(t, ui.editor_key(&p, key({key = .Arrow_Left})), ui.Editor_Outcome.Changed)
	testing.expect_value(t, p.filter_expanded, 0)
	testing.expect_value(t, ui.editor_key(&p, key({key = .Arrow_Right})), ui.Editor_Outcome.Changed)
	testing.expect_value(t, p.filter_expanded, 2)
	testing.expect(t, ui.editor_select_key(&p, "filter.3"))
	ui.editor_focus_row(&p)
	testing.expect_value(t, ui.editor_key(&p, key({key = .Delete})), ui.Editor_Outcome.Filter_Action)
	request := ui.editor_request_take(&p)
	defer ui.editor_request_destroy(&request)
	edit, ok := request.(ui.Filter_Edit)
	testing.expect(t, ok && edit.kind == .Remove && edit.id == 3)
}

@(test)
saved_filters_add_names_the_filter_uniquely_and_opens_its_fields :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	filters_fixture(t, &p)
	value, select_key := filters_value(t, &p, {kind = .Add})
	testing.expect_value(t, value, strings.concatenate({FILTERS_THREE, "; New filter | ."}, context.temp_allocator))
	testing.expect_value(t, select_key, "filter.4.name")
	testing.expect_value(t, p.filter_expanded, 4)

	taken: ui.Editor
	defer ui.editor_destroy(&taken)
	filters_fixture(t, &taken, "new FILTER | a; New filter 2 | b")
	value, _ = filters_value(t, &taken, {kind = .Add})
	testing.expect_value(t, value, "new FILTER | a; New filter 2 | b; New filter 3 | .")

	empty: ui.Editor
	defer ui.editor_destroy(&empty)
	filters_fixture(t, &empty, "")
	value, select_key = filters_value(t, &empty, {kind = .Add})
	testing.expect_value(t, value, "New filter | .")
	testing.expect_value(t, select_key, "filter.1.name")
}

@(test)
saved_filters_remove_returns_the_value_a_save_needs :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	filters_fixture(t, &p)
	p.filter_expanded = 3
	value, select_key := filters_value(t, &p, {kind = .Remove, id = 2})
	testing.expect_value(t, value, "One | a; Three | !vendor/")
	testing.expect_value(t, select_key, ui.SAVED_FILTER_ADD_KEY)
	testing.expect_value(t, p.filter_expanded, 2)
	// Removing the open filter closes its fields; removing another one before it renumbers it.
	value, _ = filters_value(t, &p, {kind = .Remove, id = 2})
	testing.expect_value(t, p.filter_expanded, 0)
	p.filter_expanded = 3
	value, _ = filters_value(t, &p, {kind = .Remove, id = 1})
	testing.expect_value(t, p.filter_expanded, 2)
	single: ui.Editor
	defer ui.editor_destroy(&single)
	filters_fixture(t, &single, "Only | a")
	value, _ = filters_value(t, &single, {kind = .Remove, id = 1})
	testing.expect_value(t, value, "")
}

@(test)
a_kept_filter_field_follows_its_filter_through_remove_and_move :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	filters_fixture(t, &p)
	// Typed into filter 2 and left without Enter: removing filter 1 renumbers it, but the text stays its own.
	value := filters_value_kept(t, &p, {kind = .Remove, id = 1}, "filter.2.name", "Foo")
	testing.expect_value(t, value, "Foo | b c; Three | !vendor/")
	// Removing the filter it was typed into drops it instead of renaming the filter that takes its place.
	value = filters_value_kept(t, &p, {kind = .Remove, id = 1}, "filter.1.name", "Foo")
	testing.expect_value(t, value, "Two | b c; Three | !vendor/")
	value = filters_value_kept(t, &p, {kind = .Move, id = 3, slot = 0}, "filter.3.pattern", "later")
	testing.expect_value(t, value, "Three | later; One | a; Two | b c")
	value = filters_value_kept(t, &p, {kind = .Add}, "filter.1.name", "Uno")
	testing.expect(t, strings.has_prefix(value, "Uno | a; Two"))
	testing.expect(t, ui.editor_kept_is_filter(&p, {"filter.2.pattern", "x"}))
	testing.expect(t, !ui.editor_kept_is_filter(&p, {"interface.font_size", "13"}))
}

@(test)
a_refused_filter_edit_leaves_the_open_filter_where_it_was :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	filters_fixture(t, &p)
	p.filter_expanded = 3
	edit := ui.Filter_Edit{kind = .Move, id = 3, slot = 0}
	_, _, problem := ui.editor_saved_filters_value(&p, edit)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, p.filter_expanded, 1)
	ui.editor_saved_filters_undo(&p, edit, 3)
	testing.expect_value(t, p.filter_expanded, 3)
}

@(test)
saved_filter_fields_show_no_reset_button :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	filters_fixture(t, &p)
	ui.editor_filter_toggle(&p, 1)
	l := ui.editor_layout({0, 40, 1200, 1400}, 1)
	found := false
	for item, index in p.items {
		if item.row < 0 || item.part != 0 || p.rows[item.row].filter_field == .None {continue}
		found = true
		testing.expect_value(t, ui.editor_row_parts(&p, l, index).reset.width, 0)
	}
	testing.expect(t, found)
}
