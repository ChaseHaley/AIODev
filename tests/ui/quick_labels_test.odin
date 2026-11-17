package ui_test

import "aio:colour"
import "aio:render"
import "aio:settings"
import "aio:ui"
import "core:strings"
import "core:testing"
import fixtures "../fixtures"

@(private)
LABELS_THREE :: "One | blue | first; Two | #2ea043 | second; Three | orange"

@(private)
labels_fixture :: proc(t: ^testing.T, p: ^ui.Editor, value: string = LABELS_THREE) {
	testing.expect_value(t, ui.editor_quick_labels_load(p, value), nil)
	ui.editor_filter(p)
}

@(private)
labels_value :: proc(t: ^testing.T, p: ^ui.Editor, edit: ui.Label_Edit) -> (value, select_key: string) {
	problem: string
	value, select_key, problem = ui.editor_quick_labels_value(p, edit)
	testing.expect_value(t, problem, "")
	return
}

@(private)
label_page_keys :: proc(p: ^ui.Editor) -> string {
	keys := make([dynamic]string, context.temp_allocator)
	for item in p.items {
		if item.row >= 0 && item.part == 0 {append(&keys, p.rows[item.row].key)}
	}
	return strings.join(keys[:], ",", context.temp_allocator)
}

@(test)
quick_labels_load_a_line_and_three_fields_per_label_with_add_and_reset :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	labels_fixture(t, &p)
	testing.expect_value(t, label_page_keys(&p), "label.1,label.2,label.3,label.add,label.reset")
	heads := 0
	for row in p.rows {
		if row.kind == .Quick_Label {heads += 1}
		if row.key == "label.add" {testing.expect_value(t, row.action, ui.Page_Action.Label_Add)}
		if row.key == "label.reset" {testing.expect_value(t, row.action, ui.Page_Action.Label_Reset)}
	}
	testing.expect_value(t, heads, 3)
	testing.expect_value(t, len(p.rows), 3 * 4 + 2)
	testing.expect_value(t, p.groups[p.rows[0].group].title, "Agent changes")
	testing.expect(t, ui.editor_reveal(&p, ui.Reveal_Row{"label.2.color"}))
	testing.expect_value(t, p.label_expanded, 2)
	testing.expect_value(
		t,
		label_page_keys(&p),
		"label.1,label.2,label.2.name,label.2.color,label.2.instruction,label.3,label.add,label.reset",
	)
	testing.expect_value(t, ui.editor_row(&p).value, "#2ea043")
	testing.expect(t, ui.editor_reveal(&p, ui.Reveal_Quick_Labels{}))
	testing.expect_value(t, ui.editor_row(&p).key, "label.1")
	empty: ui.Editor
	defer ui.editor_destroy(&empty)
	labels_fixture(t, &empty, "")
	testing.expect(t, ui.editor_reveal(&empty, ui.Reveal_Quick_Labels{}))
	testing.expect_value(t, ui.editor_row(&empty).key, ui.QUICK_LABEL_ADD_KEY)
}

@(test)
quick_labels_search_finds_a_label_by_its_instruction :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	labels_fixture(t, &p)
	ui.field_set(&p.filter, "second")
	ui.editor_filter(&p)
	testing.expect_value(t, label_page_keys(&p), "label.2")
}

@(test)
quick_labels_value_is_rebuilt_from_the_rows_and_edits :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	labels_fixture(t, &p)
	value, select_key := labels_value(t, &p, {kind = .Field, key = "label.1.name", value = "  Uno "})
	testing.expect_value(t, value, "Uno | blue | first; Two | #2ea043 | second; Three | orange")
	testing.expect_value(t, select_key, "label.1.name")
	value, _ = labels_value(t, &p, {kind = .Field, key = "label.3.instruction", value = "later"})
	testing.expect_value(t, value, "One | blue | first; Two | #2ea043 | second; Three | orange | later")
	value, _ = labels_value(t, &p, {kind = .Field, key = "label.2.instruction", value = ""})
	testing.expect_value(t, value, "One | blue | first; Two | #2ea043; Three | orange")
	value, _ = labels_value(t, &p, {kind = .Field, key = "label.1.color", value = "teal"})
	testing.expect_value(t, value, "One | teal | first; Two | #2ea043 | second; Three | orange")
	s, issues, err := settings.parse(strings.concatenate({settings.QUICK_LABELS_KEY, " = ", value}, context.temp_allocator))
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&issues)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(issues), 0)
	testing.expect_value(t, s.turns.quick_labels, value)
	// The rows are untouched until the saved value reloads the page.
	testing.expect_value(t, p.rows[0].title, "One")
}

@(test)
quick_labels_refuse_fields_the_setting_cannot_hold_with_a_message :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	labels_fixture(t, &p)
	for c in ([?]struct {
			key, value: string,
		}{{"label.1.name", ""}, {"label.1.name", "a;b"}, {"label.1.color", "mauve"}, {"label.1.color", "#12"},
			{"label.2.instruction", "a|b"}, {"label.2.instruction", "a\nb"}}) {
		value, _, problem := ui.editor_quick_labels_value(&p, {kind = .Field, key = c.key, value = c.value})
		testing.expectf(t, value == "" && problem != "", "%s = %q", c.key, c.value)
	}
}

@(test)
quick_labels_move_reorders_and_the_open_label_follows :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	labels_fixture(t, &p)
	testing.expect(t, ui.editor_reveal(&p, ui.Reveal_Row{"label.1.name"}))
	value, select_key := labels_value(t, &p, {kind = .Move, id = 1, slot = 3})
	testing.expect_value(t, value, "Two | #2ea043 | second; Three | orange; One | blue | first")
	testing.expect_value(t, select_key, "label.3")
	testing.expect_value(t, p.label_expanded, 3)

	p.label_expanded = 2
	value, select_key = labels_value(t, &p, {kind = .Move, id = 3, slot = 0})
	testing.expect_value(t, value, "Three | orange; One | blue | first; Two | #2ea043 | second")
	testing.expect_value(t, select_key, "label.1")
	testing.expect_value(t, p.label_expanded, 3)

	p.label_expanded = 3
	value, _ = labels_value(t, &p, {kind = .Move, id = 1, slot = 2})
	testing.expect_value(t, value, "Two | #2ea043 | second; One | blue | first; Three | orange")
	testing.expect_value(t, p.label_expanded, 3)

	// A move into the label's own place changes nothing.
	value, _ = labels_value(t, &p, {kind = .Move, id = 2, slot = 2})
	testing.expect_value(t, value, LABELS_THREE)
	value, _ = labels_value(t, &p, {kind = .Move, id = 2, slot = 1})
	testing.expect_value(t, value, LABELS_THREE)
}

@(test)
quick_labels_ctrl_arrows_ask_to_move_one_place_within_the_list :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	labels_fixture(t, &p)
	testing.expect(t, ui.editor_select_key(&p, "label.2"))
	testing.expect_value(
		t,
		ui.editor_key(&p, key({key = .Arrow_Down, modifiers = {.Control}})),
		ui.Editor_Outcome.Label_Action,
	)
	request := ui.editor_request_take(&p)
	defer ui.editor_request_destroy(&request)
	edit, ok := request.(ui.Label_Edit)
	testing.expect(t, ok && edit.kind == .Move && edit.id == 2 && edit.slot == 3)
	value, _ := labels_value(t, &p, edit)
	testing.expect_value(t, value, "One | blue | first; Three | orange; Two | #2ea043 | second")

	testing.expect(t, ui.editor_select_key(&p, "label.1"))
	testing.expect_value(
		t,
		ui.editor_key(&p, key({key = .Arrow_Up, modifiers = {.Control}})),
		ui.Editor_Outcome.Changed,
	)
	testing.expect(t, ui.editor_request_take(&p) == nil)
	testing.expect(t, ui.editor_select_key(&p, "label.3"))
	testing.expect_value(
		t,
		ui.editor_key(&p, key({key = .Arrow_Down, modifiers = {.Control}})),
		ui.Editor_Outcome.Changed,
	)
	testing.expect(t, ui.editor_request_take(&p) == nil)
}

@(test)
quick_labels_add_takes_the_next_preset_and_opens_its_fields :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	labels_fixture(t, &p)
	value, select_key := labels_value(t, &p, {kind = .Add})
	testing.expect_value(t, value, strings.concatenate({LABELS_THREE, "; New label | teal"}, context.temp_allocator))
	testing.expect_value(t, select_key, "label.4.name")
	testing.expect_value(t, p.label_expanded, 4)

	seven: ui.Editor
	defer ui.editor_destroy(&seven)
	labels_fixture(t, &seven, settings.QUICK_LABELS_DEFAULT)
	value, _ = labels_value(t, &seven, {kind = .Add})
	testing.expect(t, strings.has_suffix(value, "; New label | gray"))
}

@(test)
quick_labels_remove_and_reset_return_the_values_a_save_needs :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	labels_fixture(t, &p)
	p.label_expanded = 3
	value, select_key := labels_value(t, &p, {kind = .Remove, id = 2})
	testing.expect_value(t, value, "One | blue | first; Three | orange")
	testing.expect_value(t, select_key, ui.QUICK_LABEL_ADD_KEY)
	testing.expect_value(t, p.label_expanded, 2)
	// Removing the open label closes its fields; removing another one before it renumbers it.
	value, _ = labels_value(t, &p, {kind = .Remove, id = 2})
	testing.expect_value(t, p.label_expanded, 0)
	p.label_expanded = 3
	value, _ = labels_value(t, &p, {kind = .Remove, id = 1})
	testing.expect_value(t, p.label_expanded, 2)
	single: ui.Editor
	defer ui.editor_destroy(&single)
	labels_fixture(t, &single, "Only | red")
	value, _ = labels_value(t, &single, {kind = .Remove, id = 1})
	testing.expect_value(t, value, "")

	p.label_expanded = 2
	value, select_key = labels_value(t, &p, {kind = .Reset})
	testing.expect_value(t, value, settings.QUICK_LABELS_DEFAULT)
	testing.expect_value(t, select_key, ui.QUICK_LABEL_RESET_KEY)
	testing.expect_value(t, p.label_expanded, 0)
}

@(private)
labels_value_kept :: proc(t: ^testing.T, p: ^ui.Editor, edit: ui.Label_Edit, key, text: string) -> string {
	value, _, problem := ui.editor_quick_labels_value(p, edit, {key, text})
	testing.expect_value(t, problem, "")
	return value
}

@(test)
a_kept_label_field_follows_its_label_through_remove_move_and_reset :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	labels_fixture(t, &p)
	// Typed into label 2 and left without Enter: removing label 1 renumbers it, but the text stays its own.
	value := labels_value_kept(t, &p, {kind = .Remove, id = 1}, "label.2.name", "Foo")
	testing.expect_value(t, value, "Foo | #2ea043 | second; Three | orange")
	// Removing the label it was typed into drops it instead of renaming the label that takes its place.
	value = labels_value_kept(t, &p, {kind = .Remove, id = 1}, "label.1.name", "Foo")
	testing.expect_value(t, value, "Two | #2ea043 | second; Three | orange")
	value = labels_value_kept(t, &p, {kind = .Move, id = 3, slot = 0}, "label.3.instruction", "later")
	testing.expect_value(t, value, "Three | orange | later; One | blue | first; Two | #2ea043 | second")
	value = labels_value_kept(t, &p, {kind = .Reset}, "label.1.name", "Foo")
	testing.expect_value(t, value, settings.QUICK_LABELS_DEFAULT)
	value = labels_value_kept(t, &p, {kind = .Add}, "label.1.name", "Uno")
	testing.expect(t, strings.has_prefix(value, "Uno | blue | first; Two"))
}

@(test)
a_refused_label_edit_leaves_the_open_label_where_it_was :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	labels_fixture(t, &p)
	p.label_expanded = 3
	edit := ui.Label_Edit{kind = .Move, id = 3, slot = 0}
	_, _, problem := ui.editor_quick_labels_value(&p, edit)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, p.label_expanded, 1)
	ui.editor_quick_labels_undo(&p, edit, 3)
	testing.expect_value(t, p.label_expanded, 3)
}

@(test)
quick_label_fields_show_no_reset_button :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	labels_fixture(t, &p)
	ui.editor_label_toggle(&p, 1)
	l := ui.editor_layout({0, 40, 1200, 1400}, 1)
	found := false
	for item, index in p.items {
		if item.row < 0 || item.part != 0 || p.rows[item.row].label_field == .None {continue}
		found = true
		testing.expect_value(t, ui.editor_row_parts(&p, l, index).reset.width, 0)
	}
	testing.expect(t, found)
}

@(test)
quick_labels_colors_resolve_presets_against_the_theme_and_hex_as_typed :: proc(t: ^testing.T) {
	for id in ([?]string{"studio-dark", "studio-light"}) {
		theme := ui.theme_from(fixtures.shipped_theme(id), fixtures.default_interface())
		testing.expect_value(t, ui.quick_label_color(theme, "blue"), theme.palette[4])
		testing.expect_value(t, ui.quick_label_color(theme, "yellow"), theme.palette[3])
		testing.expect_value(t, ui.quick_label_color(theme, "red"), theme.palette[1])
		testing.expect_value(t, ui.quick_label_color(theme, "green"), theme.palette[2])
		testing.expect_value(t, ui.quick_label_color(theme, "teal"), theme.palette[6])
		testing.expect_value(t, ui.quick_label_color(theme, "violet"), theme.palette[5])
		testing.expect_value(t, ui.quick_label_color(theme, "gray"), theme.muted)
		red, yellow := theme.palette[1], theme.palette[3]
		orange := ui.quick_label_color(theme, "orange")
		testing.expect_value(t, orange, render.Color{(red.r + yellow.r) / 2, (red.g + yellow.g) / 2, (red.b + yellow.b) / 2, 1})
		testing.expect_value(t, ui.quick_label_color(theme, "#2ea043"), colour.rgba({0x2e, 0xa0, 0x43}))
		testing.expect_value(t, ui.quick_label_color(theme, "#FFFFFF"), colour.rgba({255, 255, 255}))
		for unknown in ([?]string{"", "mauve", "Blue", "#12345", "2ea043", "#2ea043ff"}) {
			testing.expect_value(t, ui.quick_label_color(theme, unknown), theme.muted)
		}
		for preset in settings.QUICK_LABEL_PRESETS {
			testing.expect(t, ui.quick_label_color(theme, preset) != theme.muted || preset == "gray", preset)
		}
	}
}

@(test)
quick_labels_ink_is_lifted_to_the_minimum_contrast :: proc(t: ^testing.T) {
	for id in ([?]string{"studio-dark", "studio-light"}) {
		theme := ui.theme_from(fixtures.shipped_theme(id), fixtures.default_interface())
		for value in ([?]string{"blue", "yellow", "orange", "teal", "red", "violet", "green", "gray", "#ffff00", "#101010"}) {
			for minimum in ([?]f32{3, 4.5, 7}) {
				ink := ui.quick_label_ink(theme, value, theme.pane, minimum)
				ratio := colour.contrast_ratio(colour.RGBA(ink), colour.RGBA(theme.pane))
				testing.expectf(t, ratio >= minimum - 0.01, "%s %s over the pane: %f < %f", id, value, ratio, minimum)
			}
		}
		// Contrast of one keeps the label's own colour.
		testing.expect_value(t, ui.quick_label_ink(theme, "blue", theme.pane, 1), theme.palette[4])
	}
}

@(test)
quick_labels_colour_popup_picks_a_preset_by_name_and_the_wheel_by_hex :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	labels_fixture(t, &p)
	testing.expect(t, ui.editor_reveal(&p, ui.Reveal_Row{"label.2.color"}))
	l := page(&p)
	parts := ui.editor_row_parts(&p, l, p.selected)
	x, y := center(parts.swatch)
	_ = ui.editor_press(&p, l, nil, x, y, false)
	testing.expect_value(t, ui.editor_popup(&p), ui.Editor_Popup.Color)
	popup := ui.editor_popup_rect(&p, l)
	// The strip of eight presets sits above the wheel, so this popup is taller than a plain one.
	testing.expect_value(t, popup.height, 202)
	strip := render.Rect{popup.x + 12, popup.y + 12, 268, 24}
	step := (strip.width - strip.height) / 7
	presets := settings.QUICK_LABEL_PRESETS
	for preset, i in presets {
		if ui.editor_popup(&p) == .None {_ = ui.editor_press(&p, l, nil, x, y, false)}
		testing.expect_value(t, ui.editor_popup(&p), ui.Editor_Popup.Color)
		cx, cy := center({strip.x + step * f32(i), strip.y, strip.height, strip.height})
		testing.expect_value(t, ui.editor_press(&p, l, nil, cx, cy, false), ui.Editor_Outcome.Save)
		testing.expect_value(t, ui.field_string(&p.value), preset)
		testing.expect_value(t, ui.editor_popup(&p), ui.Editor_Popup.None)
	}
	_ = ui.editor_press(&p, l, nil, x, y, false)
	wheel := render.Rect{popup.x + 12, popup.y + 12 + 36, 140, 140}
	_ = ui.editor_press(&p, l, nil, wheel.x + wheel.width - 0.01, wheel.y + wheel.height / 2, false)
	// The wheel's right edge is pure red; the brightness is whatever the ramp held.
	picked, is_hex, _ := colour.parse(ui.field_string(&p.value), .Strict)
	testing.expect(t, is_hex && picked.r > 0 && picked.g == 0 && picked.b == 0, ui.field_string(&p.value))
	testing.expect_value(t, ui.editor_release(&p), ui.Editor_Outcome.Save)
	value, _ := labels_value(t, &p, {kind = .Field, key = "label.2.color", value = ui.field_string(&p.value)})
	testing.expect_value(
		t,
		value,
		strings.concatenate({"One | blue | first; Two | ", ui.field_string(&p.value), " | second; Three | orange"}, context.temp_allocator),
	)
}

@(test)
quick_labels_name_rows_show_the_text_popup_without_presets :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	labels_fixture(t, &p)
	testing.expect(t, ui.editor_reveal(&p, ui.Reveal_Row{"label.1.name"}))
	l := page(&p)
	testing.expect_value(t, ui.editor_popup_rect(&p, l).width, 0)
}
