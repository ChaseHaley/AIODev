package ui_test

import "cosmos:font"
import "cosmos:render"
import "aio:turns"
import "aio:ui"
import "core:strings"
import "core:testing"

@(test)
dropdown_row_badges_take_the_status_colours :: proc(t: ^testing.T) {
	theme := ui.Theme {
		warning = {1, 0.5, 0, 1},
		success = {0, 1, 0, 1},
		error   = {1, 0, 0, 1},
		info    = {0, 0.5, 1, 1},
		muted   = {0.5, 0.5, 0.5, 1},
	}
	expected := [turns.File_Status]render.Color {
		.Modified = theme.warning,
		.Added    = theme.success,
		.Deleted  = theme.error,
		.Renamed  = theme.info,
		.Copied   = theme.info,
	}
	for status in turns.File_Status {
		tint := ui.changes_status_tint(status)
		testing.expect_value(t, ui.dropdown_tint_color(theme, tint), expected[status])
	}
	testing.expect_value(t, ui.dropdown_tint_color(theme, .None), theme.muted)
}

@(test)
dropdown_row_keeps_the_name_whole_and_cuts_the_folder_from_its_start :: proc(t: ^testing.T) {
	f: Changes_Fixture
	view: ui.Changes_View
	if !fixture_make(t, &f, &view) {return}
	defer font.system_destroy(f.fonts)
	body := ui.text_styled(&f.text, .Body)
	detail := ui.text_styled(&f.text, .Detail)
	row := ui.Dropdown_Row {
		badge      = "M",
		badge_tint = .Warning,
		primary    = "changes_model.odin",
		secondary  = "AIODev-agent-changes-rail/src/ui",
	}
	buf: [64]u8
	// The badge, 8 DIP of gap and the 8 DIP inset on each side take 32 before the name and 8 after the
	// folder, and the counts' side keeps a 12 DIP gap: the name and the folder get what is left.
	fixed := f32(8 + 16 + 8 + 8 + 12)
	name := ui.text_width(&body, row.primary)
	whole := ui.text_width(&detail, row.secondary)
	tail := ui.text_width(&detail, "…/src/ui")
	option :: proc(width: f32) -> render.Rect {return {0, 0, width, 32}}

	// Room for everything: nothing is cut.
	l := ui.dropdown_row_layout(row, option(fixed + name + 8 + whole + 2), {}, &body, &detail, 1, buf[:])
	testing.expect_value(t, l.folder, row.secondary)
	testing.expect(t, !l.cut)
	testing.expect(t, l.name_room >= name)

	// Not enough for the whole folder: it loses its leading folders and takes "…/", and the name stays whole.
	l = ui.dropdown_row_layout(row, option(fixed + name + 8 + tail + 1), {}, &body, &detail, 1, buf[:])
	testing.expect_value(t, l.folder, "…/src/ui")
	testing.expect(t, l.cut)
	testing.expect(t, strings.has_suffix(l.folder, "src/ui"))
	testing.expect(t, l.name_room >= name)

	// Less room: one more folder goes from the start, so what is nearest the file stays.
	smaller := ui.text_width(&detail, "…/ui")
	l = ui.dropdown_row_layout(row, option(fixed + name + 8 + smaller + 1), {}, &body, &detail, 1, buf[:])
	testing.expect_value(t, l.folder, "…/ui")
	testing.expect(t, l.cut)

	// No room for even the last folder: the folder goes and the name is still whole.
	l = ui.dropdown_row_layout(row, option(fixed + name + 8 + 2), {}, &body, &detail, 1, buf[:])
	testing.expect_value(t, l.folder, "")
	testing.expect(t, l.cut)
	testing.expect(t, l.name_room >= name)

	// Only when the name alone does not fit does it fade, over all the room there is.
	l = ui.dropdown_row_layout(row, option(fixed + name - 20), {}, &body, &detail, 1, buf[:])
	testing.expect_value(t, l.folder, "")
	testing.expect(t, l.name_room < name)
}

@(test)
dropdown_row_puts_the_counts_in_columns_at_the_right :: proc(t: ^testing.T) {
	f: Changes_Fixture
	view: ui.Changes_View
	if !fixture_make(t, &f, &view) {return}
	defer font.system_destroy(f.fonts)
	body := ui.text_styled(&f.text, .Body)
	detail := ui.text_styled(&f.text, .Detail)
	rows := [2]ui.Dropdown_Row {
		{badge = "A", primary = "a.odin", added = 3, removed = 1},
		{badge = "M", primary = "long_name.odin", secondary = "src", added = 1200, removed = 45},
	}
	d: ui.Dropdown
	ui.dropdown_init(&d)
	defer ui.dropdown_destroy(&d)
	choices := ui.Dropdown_Choices {
		choices = {"a", "b"},
		rows    = rows[:],
	}
	ui.dropdown_measure(&d, choices, &f.text, 1)
	testing.expect(t, d.metrics.plus > 0 && d.metrics.minus > 0)
	buf: [64]u8
	option := render.Rect{0, 0, 500, 32}
	first := ui.dropdown_row_layout(rows[0], option, d.metrics, &body, &detail, 1, buf[:])
	second := ui.dropdown_row_layout(rows[1], option, d.metrics, &body, &detail, 1, buf[:])
	// The columns line up row to row, whatever the counts' own widths.
	testing.expect_value(t, first.plus_right, second.plus_right)
	testing.expect_value(t, first.minus_right, second.minus_right)
	testing.expect_value(t, first.minus_right, f32(500 - 8))
	testing.expect(t, first.plus_right < first.minus_right)
}

@(test)
dropdown_row_cut_names_the_row_whose_folder_is_shortened :: proc(t: ^testing.T) {
	f: Changes_Fixture
	view: ui.Changes_View
	if !fixture_make(t, &f, &view) {return}
	defer font.system_destroy(f.fonts)
	rows := [2]ui.Dropdown_Row {
		{badge = "M", primary = "a.odin"},
		{badge = "M", primary = "model.odin", secondary = "AIODev-agent-changes-rail/src/ui/deeper/still/deeper/and/deeper/yet"},
	}
	d: ui.Dropdown
	ui.dropdown_init(&d)
	defer ui.dropdown_destroy(&d)
	choices := ui.Dropdown_Choices {
		choices     = {"a.odin", "model.odin"},
		rows        = rows[:],
		rows_serial = 1,
		fit_content = true,
		min_width   = 200,
	}
	anchor := ui.Dropdown_Anchor {
		field     = {300, 10, 80, 24},
		row       = {300, 10, 80, 24},
		bounds    = {0, 0, 400, 600},
		align_end = true,
	}
	ui.dropdown_open(&d, choices)
	ui.dropdown_measure(&d, choices, &f.text, 1)
	popup := ui.dropdown_rect(&d, choices, anchor, 1)
	testing.expect(t, popup.width >= 200)
	first, first_cut := ui.dropdown_row_cut(&d, choices, anchor, &f.text, popup.x + 40, popup.y + 4 + 16, 1)
	testing.expect_value(t, first, 0)
	testing.expect(t, !first_cut)
	// The widest row asks for more than 200 DIPs, but the page only has 400 - 16.
	second, second_cut := ui.dropdown_row_cut(&d, choices, anchor, &f.text, popup.x + 40, popup.y + 4 + 32 + 16, 1)
	testing.expect_value(t, second, 1)
	testing.expect(t, second_cut)
	testing.expect(t, popup.width <= 400 - 16)
	outside, _ := ui.dropdown_row_cut(&d, choices, anchor, &f.text, 5, 5, 1)
	testing.expect_value(t, outside, -1)
}
