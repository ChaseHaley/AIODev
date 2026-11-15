package ui_test

import "aio:font"
import "aio:glyphs"
import "aio:render"
import "aio:turns"
import "aio:ui"
import "core:strings"
import "core:testing"

@(private = "file")
Changes_Fixture :: struct {
	fonts:     ^font.System,
	text, mono: ui.Text,
	lines:     [3]turns.Diff_Line,
	hunks:     [1]turns.Hunk,
	files:     [2]turns.Diff_File,
	collapsed: [2]bool,
	rows:      [5]ui.Changes_Turn,
}

// Two files of one hunk (one context, one removed, one added line each), the second collapsed, and five
// turns. The fixture is filled in place, so the slices it hands out stay valid.
@(private = "file")
fixture_make :: proc(t: ^testing.T, f: ^Changes_Fixture, view: ^ui.Changes_View) -> bool {
	err: font.Error
	f.fonts, err = font.system_create()
	if !testing.expect_value(t, err, font.Error.None) {return false}
	if !testing.expect(t, ui.text_init(&f.text, f.fonts, nil, 13)) {
		font.system_destroy(f.fonts)
		return false
	}
	f.mono = ui.text_mono(&f.text, f.text.family)
	f.lines = {
		{kind = .Context, old_line = 1, new_line = 1, text = "a"},
		{kind = .Removed, old_line = 2, text = "b"},
		{kind = .Added, new_line = 2, text = "c"},
	}
	f.hunks = {{old_start = 1, old_count = 2, new_start = 1, new_count = 2, lines = f.lines[:]}}
	f.files = {
		{old_path = "a.txt", new_path = "a.txt", status = .Modified, added = 1, removed = 1, hunks = f.hunks[:]},
		{old_path = "b.txt", new_path = "b.txt", status = .Modified, added = 1, removed = 1, hunks = f.hunks[:]},
	}
	f.collapsed = {false, true}
	for &row, i in f.rows {
		row = {title = "turn", detail = "now", files = i + 1, added = i, removed = 1, agent = -1}
	}
	view^ = {
		scope     = .Agent,
		turns     = f.rows[:],
		first     = -1,
		last      = -1,
		files     = f.files[:],
		collapsed = f.collapsed[:],
		revision  = 1,
		editing   = -1,
	}
	return true
}

@(private = "file")
centre :: proc(r: render.Rect) -> (x, y: f32) {return r.x + r.width / 2, r.y + r.height / 2}

@(test)
changes_geometry_puts_the_strip_in_the_toolbar_and_the_diff_across_the_pane :: proc(t: ^testing.T) {
	f: Changes_Fixture
	view: ui.Changes_View
	if !fixture_make(t, &f, &view) {return}
	defer font.system_destroy(f.fonts)

	g := ui.changes_geometry({0, 0, 900, 600}, 1, &view, &f.text)
	testing.expect_value(t, g.toolbar, render.Rect{0, 0, 900, 28})
	testing.expect_value(t, g.diff, render.Rect{0, 28, 900, 572})
	testing.expect_value(t, g.send_bar, render.Rect{})
	testing.expect_value(t, g.scope, render.Rect{8, 2, 216, 24})
	testing.expect_value(t, g.step_back, render.Rect{232, 2, 24, 24})
	// Five bars 8 wide, 3 apart, between the step buttons.
	testing.expect_value(t, g.strip_bars, 5)
	testing.expect_value(t, g.strip, render.Rect{260, 2, 52, 24})
	testing.expect_value(t, g.step_forward, render.Rect{316, 2, 24, 24})
	testing.expect_value(t, g.range_label.x, f32(344))
	testing.expect(t, g.range_label.width > 0 && g.range_label.height == 24)
	testing.expect(t, g.repository.x >= g.range_label.x + g.range_label.width)
	testing.expect_value(t, g.turn_row, f32(40))
	// The turn list hangs under the range label: ten rows at most, five here, plus its padding.
	testing.expect_value(t, g.turn_list, render.Rect{344, 32, 320, 5 * 40 + 8})

	view.scope = .Uncommitted
	view.turns = nil
	git := ui.changes_geometry({0, 0, 900, 600}, 1, &view, &f.text)
	testing.expect_value(t, git.strip, render.Rect{})
	testing.expect_value(t, git.step_back, render.Rect{})
	testing.expect_value(t, git.step_forward, render.Rect{})
	testing.expect_value(t, git.range_label, render.Rect{})
	testing.expect_value(t, git.turn_list, render.Rect{})
	testing.expect_value(t, git.strip_bars, 0)
	testing.expect_value(t, git.diff, render.Rect{0, 28, 900, 572})

	// A turn scope without turns keeps its controls; the strip and the list stay empty.
	view.scope = .Repository
	empty := ui.changes_geometry({0, 0, 900, 600}, 1, &view, &f.text)
	testing.expect_value(t, empty.strip_bars, 0)
	testing.expect_value(t, empty.strip, render.Rect{})
	testing.expect_value(t, empty.step_back, render.Rect{232, 2, 24, 24})
	testing.expect_value(t, empty.step_forward, render.Rect{260, 2, 24, 24})
	testing.expect(t, empty.range_label.width > 0)
	testing.expect_value(t, empty.turn_list, render.Rect{})

	view.scope = .Agent
	view.turns = f.rows[:]
	double := ui.changes_geometry({0, 0, 1800, 1200}, 2, &view, &f.text)
	testing.expect_value(t, double.turn_row, f32(80))
	testing.expect_value(t, double.toolbar.height, f32(56))
	testing.expect_value(t, double.strip.width, f32(5 * 22 - 6))
	testing.expect_value(t, double.diff, render.Rect{0, 56, 1800, 1144})
}

@(test)
changes_toolbar_ends_with_the_fold_filter_layout_and_file_list_buttons :: proc(t: ^testing.T) {
	f: Changes_Fixture
	view: ui.Changes_View
	if !fixture_make(t, &f, &view) {return}
	defer font.system_destroy(f.fonts)
	state: ui.Changes_State
	defer ui.changes_state_destroy(&state)

	// The file list button is the far-right control, then the layout toggle, the filter and fold buttons.
	g := ui.changes_geometry({0, 0, 900, 600}, 1, &view, &f.text)
	testing.expect_value(t, g.files_button, render.Rect{868, 2, 24, 24})
	testing.expect_value(t, g.layout_button, render.Rect{840, 2, 24, 24})
	testing.expect_value(t, g.filter_button, render.Rect{812, 2, 24, 24})
	testing.expect_value(t, g.fold_button, render.Rect{784, 2, 24, 24})
	testing.expect(t, g.range_label.x + g.range_label.width <= g.fold_button.x)
	testing.expect(t, g.repository.x + g.repository.width <= g.fold_button.x)
	ui.changes_layout(&state, &view, &f.text, &f.mono, g.diff.width, 1)
	files_x, files_y := centre(g.files_button)
	layout_x, layout_y := centre(g.layout_button)
	files := ui.changes_hit(g, &view, &state, files_x, files_y)
	testing.expect_value(t, files, ui.Changes_Hit{.Files_Button, 0, 0})
	layout := ui.changes_hit(g, &view, &state, layout_x, layout_y)
	testing.expect_value(t, layout, ui.Changes_Hit{.Layout_Button, 0, 0})
	filter_x, filter_y := centre(g.filter_button)
	filter := ui.changes_hit(g, &view, &state, filter_x, filter_y)
	testing.expect_value(t, filter, ui.Changes_Hit{.Filter_Button, 0, 0})
	fold_x, fold_y := centre(g.fold_button)
	fold := ui.changes_hit(g, &view, &state, fold_x, fold_y)
	testing.expect_value(t, fold, ui.Changes_Hit{.Fold_Button, 0, 0})
	// Collapsing or expanding swaps its icon, not its place.
	view.any_expanded = true
	expanded := ui.changes_geometry({0, 0, 900, 600}, 1, &view, &f.text)
	testing.expect_value(t, expanded.fold_button, g.fold_button)
	view.any_expanded = false
	// The view a pane shows doesn't move the buttons.
	view.side_by_side = true
	side := ui.changes_geometry({0, 0, 900, 600}, 1, &view, &f.text)
	testing.expect_value(t, side.files_button, g.files_button)
	view.side_by_side = false

	// Git scopes have them in the same place.
	view.scope, view.turns = .Staged, nil
	git := ui.changes_geometry({0, 0, 900, 600}, 1, &view, &f.text)
	testing.expect_value(t, git.files_button, g.files_button)
	testing.expect_value(t, git.layout_button, g.layout_button)
	testing.expect_value(t, git.filter_button, g.filter_button)
	testing.expect_value(t, git.fold_button, g.fold_button)
	testing.expect(t, git.repository.x + git.repository.width <= git.fold_button.x)

	// Without files the file list and fold buttons are disabled and answer nothing; the toggle still
	// works.
	view.files = nil
	view.revision += 1
	ui.changes_layout(&state, &view, &f.text, &f.mono, git.diff.width, 1)
	testing.expect_value(t, ui.changes_hit(git, &view, &state, files_x, files_y), ui.Changes_Hit{})
	testing.expect_value(t, ui.changes_hit(git, &view, &state, fold_x, fold_y), ui.Changes_Hit{})
	layout = ui.changes_hit(git, &view, &state, layout_x, layout_y)
	testing.expect_value(t, layout, ui.Changes_Hit{.Layout_Button, 0, 0})
	// A filter that hides every file leaves the list open to pick one: it keeps the hidden files.
	view.filter_active, view.hidden_count, view.total_files = true, 2, 2
	hidden := ui.changes_geometry({0, 0, 900, 600}, 1, &view, &f.text)
	testing.expect_value(t, hidden.files_button, g.files_button)
	all_hidden := ui.changes_hit(hidden, &view, &state, files_x, files_y)
	testing.expect_value(t, all_hidden, ui.Changes_Hit{.Files_Button, 0, 0})
	// Folding only acts on the files the view shows.
	testing.expect_value(t, ui.changes_hit(hidden, &view, &state, fold_x, fold_y), ui.Changes_Hit{})
	view.filter_active, view.hidden_count, view.total_files = false, 0, 0

	double := ui.changes_geometry({0, 0, 1800, 1200}, 2, &view, &f.text)
	testing.expect_value(t, double.files_button, render.Rect{1736, 4, 48, 48})
	testing.expect_value(t, double.layout_button, render.Rect{1680, 4, 48, 48})
	testing.expect_value(t, double.filter_button, render.Rect{1624, 4, 48, 48})
	testing.expect_value(t, double.fold_button, render.Rect{1568, 4, 48, 48})
	// A pane too narrow for all four leaves them all out.
	sliver := ui.changes_geometry({0, 0, 120, 200}, 1, &view, &f.text)
	testing.expect_value(t, sliver.files_button, render.Rect{})
	testing.expect_value(t, sliver.layout_button, render.Rect{})
	testing.expect_value(t, sliver.filter_button, render.Rect{})
	testing.expect_value(t, sliver.fold_button, render.Rect{})
	testing.expect_value(t, sliver.filter_popover, render.Rect{})
	room := ui.changes_geometry({0, 0, 124, 200}, 1, &view, &f.text)
	testing.expect(t, room.files_button.width > 0 && room.layout_button.width > 0)
	testing.expect(t, room.filter_button.width > 0 && room.fold_button.width > 0)
}

@(test)
changes_filter_popover_hangs_under_its_button_and_answers_first :: proc(t: ^testing.T) {
	f: Changes_Fixture
	view: ui.Changes_View
	if !fixture_make(t, &f, &view) {return}
	defer font.system_destroy(f.fonts)
	state: ui.Changes_State
	defer ui.changes_state_destroy(&state)
	editor: ui.Text_Field
	defer delete(editor.bytes)
	view.filter_editor = &editor

	// Empty: no clear button, and the editing box spans the field.
	g := ui.changes_geometry({0, 0, 900, 600}, 1, &view, &f.text)
	small := ui.text_styled(&f.text, .Detail)
	height := f32(int(24 + 32 + 8 + small.line_height + 0.5))
	// 360 wide, its right edge on the button's.
	testing.expect_value(t, g.filter_popover, render.Rect{476, 32, 360, height})
	testing.expect_value(t, g.filter_field, render.Rect{488, 44, 336, 32})
	testing.expect_value(t, g.filter_clear, render.Rect{})
	box, shown := ui.changes_filter_box(g, &view, &f.text)
	testing.expect(t, shown && box.rect == g.filter_field)

	testing.expect(t, ui.field_set(&editor, "foo !.json") == nil)
	g = ui.changes_geometry({0, 0, 900, 600}, 1, &view, &f.text)
	testing.expect_value(t, g.filter_clear, render.Rect{796, 48, 24, 24})
	box, shown = ui.changes_filter_box(g, &view, &f.text)
	testing.expect(t, shown && box.rect.width == 796 - 488)
	ui.changes_layout(&state, &view, &f.text, &f.mono, g.diff.width, 1)

	field_x, field_y := centre(g.filter_field)
	clear_x, clear_y := centre(g.filter_clear)
	pad_x, pad_y := g.filter_popover.x + 4, g.filter_popover.y + g.filter_popover.height - 4
	// Closed, the points belong to what lies under the popover.
	testing.expect(t, ui.changes_hit(g, &view, &state, field_x, field_y).part != .Filter_Field)
	testing.expect(t, ui.changes_hit(g, &view, &state, clear_x, clear_y).part != .Filter_Clear)
	state.filter_open = true
	on_field := ui.changes_hit(g, &view, &state, field_x, field_y)
	testing.expect_value(t, on_field, ui.Changes_Hit{.Filter_Field, 0, 0})
	on_clear := ui.changes_hit(g, &view, &state, clear_x, clear_y)
	testing.expect_value(t, on_clear, ui.Changes_Hit{.Filter_Clear, 0, 0})
	on_padding := ui.changes_hit(g, &view, &state, pad_x, pad_y)
	testing.expect_value(t, on_padding, ui.Changes_Hit{.Filter_Field, -1, 0})
	// The open popover answers before the turn list under it.
	state.turn_list_open = true
	on_field = ui.changes_hit(g, &view, &state, field_x, field_y)
	testing.expect_value(t, on_field, ui.Changes_Hit{.Filter_Field, 0, 0})

	// A narrow pane keeps it inside, still under the button.
	narrow := ui.changes_geometry({0, 0, 300, 400}, 1, &view, &f.text)
	testing.expect_value(t, narrow.filter_popover.x, f32(8))
	testing.expect_value(t, narrow.filter_popover.width, f32(284))
}

@(test)
changes_filter_bar_shows_only_while_the_filter_hides_files :: proc(t: ^testing.T) {
	f: Changes_Fixture
	view: ui.Changes_View
	if !fixture_make(t, &f, &view) {return}
	defer font.system_destroy(f.fonts)
	state: ui.Changes_State
	defer ui.changes_state_destroy(&state)

	plain := ui.changes_geometry({0, 0, 900, 600}, 1, &view, &f.text)
	testing.expect_value(t, plain.filter_bar, render.Rect{})
	testing.expect_value(t, plain.diff, render.Rect{0, 28, 900, 572})

	view.filter_active, view.hidden_count, view.total_files = true, 3, 5
	g := ui.changes_geometry({0, 0, 900, 600}, 1, &view, &f.text)
	testing.expect_value(t, g.filter_bar, render.Rect{0, 28, 900, 24})
	testing.expect_value(t, g.diff, render.Rect{0, 52, 900, 548})
	clear := g.filter_bar_clear
	testing.expect(t, clear.width > 0 && clear.x + clear.width == 892)
	testing.expect(t, clear.y >= 28 && clear.y + clear.height <= 52)
	ui.changes_layout(&state, &view, &f.text, &f.mono, g.diff.width, 1)
	x, y := centre(clear)
	testing.expect_value(t, ui.changes_hit(g, &view, &state, x, y), ui.Changes_Hit{.Filter_Bar_Clear, 0, 0})
	testing.expect_value(t, ui.changes_hit(g, &view, &state, 40, 40), ui.Changes_Hit{})
	// The first file's header now starts under the bar.
	header := ui.changes_hit(g, &view, &state, 50, 52 + 5)
	testing.expect_value(t, header, ui.Changes_Hit{.File_Header, 0, 0})

	// Active but hiding nothing, or invalid, there is no bar.
	view.hidden_count = 0
	quiet := ui.changes_geometry({0, 0, 900, 600}, 1, &view, &f.text)
	testing.expect_value(t, quiet.filter_bar, render.Rect{})
	view.hidden_count, view.filter_active, view.filter_invalid = 3, false, true
	invalid := ui.changes_geometry({0, 0, 900, 600}, 1, &view, &f.text)
	testing.expect_value(t, invalid.filter_bar, render.Rect{})
	testing.expect_value(t, invalid.diff.y, f32(28))

	// A send bar still sits at the bottom with the filter bar at the top.
	view.filter_active, view.filter_invalid, view.send.count = true, false, 1
	both := ui.changes_geometry({0, 0, 900, 600}, 1, &view, &f.text)
	testing.expect_value(t, both.diff.y, f32(52))
	testing.expect_value(t, both.diff.y + both.diff.height, both.send_bar.y)
}

@(test)
changes_draw_shows_the_filter_bar_and_the_open_popover :: proc(t: ^testing.T) {
	device, device_error := render.device_create(.Warp)
	if !testing.expect_value(t, device_error, render.Error.None) {return}
	defer render.device_destroy(device)
	f: Changes_Fixture
	view: ui.Changes_View
	if !fixture_make(t, &f, &view) {return}
	defer font.system_destroy(f.fonts)
	cache: glyphs.Cache
	glyphs.init(&cache, f.fonts, device)
	defer glyphs.destroy(&cache)
	if !testing.expect(t, ui.text_init(&f.text, f.fonts, &cache, 13)) {return}
	f.mono = ui.text_mono(&f.text, f.text.family)
	state: ui.Changes_State
	defer ui.changes_state_destroy(&state)
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	editor: ui.Text_Field
	defer delete(editor.bytes)
	testing.expect(t, ui.field_set(&editor, "a") == nil)
	view.filter_editor = &editor
	view.filter_active, view.hidden_count, view.total_files = true, 1, 3
	state.filter_open = true

	g := ui.changes_geometry({0, 0, 900, 600}, 1, &view, &f.text)
	ui.changes_layout(&state, &view, &f.text, &f.mono, g.diff.width, 1)
	if !draw_into(t, &f, &list, &view, &state, g) {return}
	bar, hint := 0, 0
	hint_top := g.filter_field.y + g.filter_field.height
	for glyph in list.glyphs {
		y := glyph.rect.y + glyph.rect.height / 2
		x := glyph.rect.x
		in_bar := y >= g.filter_bar.y && y < g.filter_bar.y + g.filter_bar.height
		if in_bar && x < g.filter_popover.x {bar += 1}
		inside := x >= g.filter_field.x && x < g.filter_field.x + g.filter_field.width
		if inside && y > hint_top && y < g.filter_popover.y + g.filter_popover.height {hint += 1}
	}
	testing.expect(t, bar > 0)
	testing.expect(t, hint > 0)

	// Closed, the bar's counts show in the added and removed colours.
	state.filter_open = false
	view.shown_added, view.shown_removed, view.total_added, view.total_removed = 4, 1, 204, 1
	if !draw_into(t, &f, &list, &view, &state, g) {return}
	green, red := render.Color{0, 1, 0, 1}, render.Color{1, 0, 0, 1}
	added, removed, wide := 0, 0, 0
	for glyph in list.glyphs {
		y := glyph.rect.y + glyph.rect.height / 2
		if y < g.filter_bar.y || y >= g.filter_bar.y + g.filter_bar.height {continue}
		if glyph.rect.x < g.filter_bar_clear.x {wide += 1}
		if glyph.color == green {added += 1}
		if glyph.color == red {removed += 1}
	}
	// "+4" and "+204"; "−1" twice.
	testing.expect(t, added >= 4)
	testing.expect(t, removed >= 2)

	// A narrow pane fades the text before Clear, which stays and still answers.
	narrow := ui.changes_geometry({0, 0, 260, 600}, 1, &view, &f.text)
	ui.changes_layout(&state, &view, &f.text, &f.mono, narrow.diff.width, 1)
	if !draw_into(t, &f, &list, &view, &state, narrow) {return}
	clear := narrow.filter_bar_clear
	testing.expect(t, clear.width > 0)
	shown := 0
	for glyph in list.glyphs {
		y := glyph.rect.y + glyph.rect.height / 2
		if y < narrow.filter_bar.y || y >= narrow.filter_bar.y + narrow.filter_bar.height {continue}
		if glyph.rect.x >= clear.x {continue}
		shown += 1
		testing.expect(t, glyph.rect.x < clear.x - 8)
	}
	testing.expect(t, shown > 0 && shown < wide)
	clear_x, clear_y := centre(clear)
	on_clear := ui.changes_hit(narrow, &view, &state, clear_x, clear_y)
	testing.expect_value(t, on_clear, ui.Changes_Hit{.Filter_Bar_Clear, 0, 0})
	state.filter_open = true

	// Invalid: the error replaces the hint, and the bar goes.
	view.filter_active, view.filter_invalid = false, true
	view.filter_error = "Invalid regular expression: ["
	g = ui.changes_geometry({0, 0, 900, 600}, 1, &view, &f.text)
	testing.expect_value(t, g.filter_bar, render.Rect{})
	if !draw_into(t, &f, &list, &view, &state, g) {return}
}

@(test)
changes_geometry_keeps_the_send_bar_under_the_diff :: proc(t: ^testing.T) {
	f: Changes_Fixture
	view: ui.Changes_View
	if !fixture_make(t, &f, &view) {return}
	defer font.system_destroy(f.fonts)

	view.send.count = 2
	g := ui.changes_geometry({0, 0, 900, 600}, 1, &view, &f.text)
	height := ui.changes_send_bar_height(&view, 1)
	if !testing.expect(t, height > 0) {return}
	testing.expect_value(t, g.send_bar, render.Rect{0, 600 - height, 900, height})
	testing.expect_value(t, g.diff, render.Rect{0, 28, 900, 572 - height})

	// The notice centres in what is left above the bar.
	view.notice = .No_Changes
	n := ui.changes_geometry({0, 0, 900, 600}, 1, &view, &f.text)
	testing.expect(t, n.notice.y + n.notice.height <= n.send_bar.y)
}

@(test)
changes_geometry_fits_the_toolbar_controls :: proc(t: ^testing.T) {
	f: Changes_Fixture
	view: ui.Changes_View
	if !fixture_make(t, &f, &view) {return}
	defer font.system_destroy(f.fonts)

	without := ui.changes_geometry({0, 0, 900, 600}, 1, &view, &f.text)
	testing.expect_value(t, without.hooks.width, f32(0))
	view.hooks_offer = true
	offered := ui.changes_geometry({0, 0, 900, 600}, 1, &view, &f.text)
	testing.expect(t, offered.hooks.width > 0)
	// Install turn hooks sits left of the fold, filter, layout and file list buttons.
	testing.expect(t, abs(offered.hooks.x + offered.hooks.width - (offered.fold_button.x - 8)) < 0.01)
	testing.expect(t, offered.scope.x + offered.scope.width <= offered.hooks.x)
	testing.expect(t, offered.range_label.x + offered.range_label.width <= offered.hooks.x)
	testing.expect(t, offered.repository.x + offered.repository.width <= offered.hooks.x)

	tiny := ui.changes_geometry({0, 0, 120, 200}, 1, &view, &f.text)
	testing.expect(t, tiny.scope.x + tiny.scope.width <= tiny.hooks.x || tiny.scope.width == 0)
	testing.expect(t, tiny.hooks.x + tiny.hooks.width <= 120)
	testing.expect_value(t, tiny.strip_bars, 0)
	for r in ([]render.Rect{tiny.step_back, tiny.strip, tiny.step_forward, tiny.range_label}) {
		testing.expect(t, r.width == 0 || r.x + r.width <= tiny.hooks.x)
	}
}

@(test)
changes_geometry_centres_the_notice_below_the_toolbar :: proc(t: ^testing.T) {
	f: Changes_Fixture
	view: ui.Changes_View
	if !fixture_make(t, &f, &view) {return}
	defer font.system_destroy(f.fonts)
	view.turns = nil
	view.files = nil

	view.notice = .Recording_Off
	g := ui.changes_geometry({0, 0, 800, 500}, 1, &view, &f.text)
	diff := g.diff
	testing.expect_value(t, diff, render.Rect{0, 28, 800, 472})
	n, b := g.notice, g.notice_button
	testing.expect(t, n.width > 0 && n.width <= 360)
	testing.expect(t, n.x >= diff.x && n.x + n.width <= diff.x + diff.width)
	testing.expect(t, n.y >= diff.y && n.y + n.height <= diff.y + diff.height)
	testing.expect_value(t, b.height, f32(32))
	testing.expect(t, b.width > 0 && b.x >= n.x && b.x + b.width <= n.x + n.width)
	testing.expect(t, abs(b.x + b.width / 2 - (diff.x + diff.width / 2)) <= 1)
	testing.expect_value(t, b.y + b.height, n.y + n.height)
	testing.expect(t, abs((n.y - diff.y) - (diff.y + diff.height - (n.y + n.height))) <= 1)

	view.notice = .Not_Repository
	plain := ui.changes_geometry({0, 0, 800, 500}, 1, &view, &f.text)
	testing.expect_value(t, plain.notice_button.width, f32(0))
	testing.expect(t, plain.notice.width > 0 && plain.notice.height > 0)

	// A notice sits in the diff area, which spans the pane under a strip that still has turns.
	view.turns = f.rows[:]
	view.notice = .No_Changes
	kept := ui.changes_geometry({0, 0, 900, 600}, 1, &view, &f.text)
	testing.expect_value(t, kept.strip_bars, 5)
	testing.expect_value(t, kept.diff, render.Rect{0, 28, 900, 572})
	testing.expect(t, abs(kept.notice.x + kept.notice.width / 2 - 450) <= 1)
}

@(test)
changes_notice_text_follows_scope_and_detail :: proc(t: ^testing.T) {
	view := ui.Changes_View {
		notice = .No_Changes,
		scope  = .Repository,
	}
	title, body := ui.changes_notice_text(&view)
	testing.expect_value(t, title, "No changes")
	testing.expect_value(t, body, "The selected turns changed no files.")
	view.scope = .Staged
	_, body = ui.changes_notice_text(&view)
	testing.expect_value(t, body, "Nothing to show.")
	view.notice, view.detail = .Failed, "fatal: bad object"
	title, body = ui.changes_notice_text(&view)
	testing.expect_value(t, title, "Could not read changes")
	testing.expect_value(t, body, "fatal: bad object")
	view.notice = .None
	title, body = ui.changes_notice_text(&view)
	testing.expect_value(t, title, "")
	testing.expect_value(t, body, "")
}

@(test)
changes_layout_totals_expanded_and_collapsed_files :: proc(t: ^testing.T) {
	f: Changes_Fixture
	view: ui.Changes_View
	if !fixture_make(t, &f, &view) {return}
	defer font.system_destroy(f.fonts)
	state: ui.Changes_State
	defer ui.changes_state_destroy(&state)

	ui.changes_layout(&state, &view, &f.text, &f.mono, 900, 1)
	rows := state.rows
	line := int(f.mono.line_height) + 2
	hunk := line + 4
	body := hunk + 3 * line
	testing.expect_value(t, rows.header, 32)
	testing.expect_value(t, rows.line, line)
	testing.expect_value(t, rows.hunk, hunk)
	testing.expect_value(t, len(rows.tops), 3)
	testing.expect_value(t, rows.tops[0], 0)
	testing.expect_value(t, rows.tops[1], 32 + body + 8)
	testing.expect_value(t, rows.tops[2], 32 + body + 8 + 32 + 8)
	testing.expect_value(t, rows.total, rows.tops[2])

	// Untracked files left out add a footer row under the files.
	before := rows.total
	view.omitted = 4
	ui.changes_layout(&state, &view, &f.text, &f.mono, 900, 1)
	testing.expect_value(t, state.rows.total, before + 32)

	// Expanding the second file grows the stream even without a new revision.
	view.omitted = 0
	f.collapsed[1] = false
	ui.changes_layout(&state, &view, &f.text, &f.mono, 900, 1)
	testing.expect_value(t, state.rows.total, 2 * (32 + body + 8))

	// A file without hunks, and a binary one, take one note row.
	f.files[0].hunks = nil
	f.files[1].binary = true
	view.revision += 1
	ui.changes_layout(&state, &view, &f.text, &f.mono, 900, 1)
	testing.expect_value(t, state.rows.total, 2 * (32 + 24 + 8))

	view.notice = .Not_Repository
	view.revision += 1
	ui.changes_layout(&state, &view, &f.text, &f.mono, 900, 1)
	testing.expect_value(t, state.rows.total, 0)
}

@(test)
changes_layout_scales_with_the_window :: proc(t: ^testing.T) {
	f: Changes_Fixture
	view: ui.Changes_View
	if !fixture_make(t, &f, &view) {return}
	defer font.system_destroy(f.fonts)
	state: ui.Changes_State
	defer ui.changes_state_destroy(&state)

	ui.changes_layout(&state, &view, &f.text, &f.mono, 900, 1)
	small := state.rows.total
	ui.changes_layout(&state, &view, &f.text, &f.mono, 1800, 2)
	testing.expect_value(t, state.rows.header, 64)
	testing.expect_value(t, state.rows.gap, 16)
	testing.expect(t, state.rows.total > small)
}

@(test)
changes_hit_finds_toolbar_parts_headers_and_notice_button :: proc(t: ^testing.T) {
	f: Changes_Fixture
	view: ui.Changes_View
	if !fixture_make(t, &f, &view) {return}
	defer font.system_destroy(f.fonts)
	state: ui.Changes_State
	defer ui.changes_state_destroy(&state)
	view.hooks_offer = true
	g := ui.changes_geometry({0, 0, 900, 600}, 1, &view, &f.text)
	ui.changes_layout(&state, &view, &f.text, &f.mono, g.diff.width, 1)
	tops := state.rows.tops

	// Bars run oldest to newest from the left, so the leftmost is the last row.
	oldest_x, oldest_y := centre(ui.changes_strip_bar_rect(g, &state, &view, 4))
	oldest := ui.changes_hit(g, &view, &state, oldest_x, oldest_y)
	testing.expect_value(t, oldest, ui.Changes_Hit{.Strip_Bar, 4, 0})
	newest_x, _ := centre(ui.changes_strip_bar_rect(g, &state, &view, 0))
	// Anywhere in a bar's column counts, above a short bar too.
	top := ui.changes_hit(g, &view, &state, newest_x, g.strip.y + 1)
	testing.expect_value(t, top, ui.Changes_Hit{.Strip_Bar, 0, 0})

	// No selection: both steps work.
	back_x, back_y := centre(g.step_back)
	forward_x, forward_y := centre(g.step_forward)
	stepped := ui.changes_hit(g, &view, &state, back_x, back_y)
	testing.expect_value(t, stepped, ui.Changes_Hit{.Step_Back, 0, 0})
	testing.expect_value(
		t, ui.changes_hit(g, &view, &state, forward_x, forward_y), ui.Changes_Hit{.Step_Forward, 0, 0},
	)
	// At either end its step is disabled and answers nothing.
	view.first, view.last = 0, 0
	testing.expect_value(t, ui.changes_hit(g, &view, &state, forward_x, forward_y), ui.Changes_Hit{})
	back := ui.changes_hit(g, &view, &state, back_x, back_y)
	testing.expect_value(t, back, ui.Changes_Hit{.Step_Back, 0, 0})
	view.first, view.last = 2, 4
	testing.expect_value(t, ui.changes_hit(g, &view, &state, back_x, back_y), ui.Changes_Hit{})
	testing.expect_value(
		t, ui.changes_hit(g, &view, &state, forward_x, forward_y), ui.Changes_Hit{.Step_Forward, 0, 0},
	)
	view.first, view.last = -1, -1
	g = ui.changes_geometry({0, 0, 900, 600}, 1, &view, &f.text)

	label_x, label_y := centre(g.range_label)
	label := ui.changes_hit(g, &view, &state, label_x, label_y)
	testing.expect_value(t, label, ui.Changes_Hit{.Range_Label, 0, 0})

	first_header := ui.changes_hit(g, &view, &state, g.diff.x + 50, g.diff.y + 5)
	testing.expect_value(t, first_header, ui.Changes_Hit{.File_Header, 0, 0})
	second := ui.changes_hit(g, &view, &state, g.diff.x + 50, g.diff.y + f32(tops[1]) + 4)
	testing.expect_value(t, second, ui.Changes_Hit{.File_Header, 1, 0})
	past := ui.changes_hit(g, &view, &state, g.diff.x + 50, g.diff.y + f32(tops[2]) + 20)
	testing.expect_value(t, past, ui.Changes_Hit{.Diff, -1, 0})
	state.diff_scroll = tops[1]
	moved := ui.changes_hit(g, &view, &state, g.diff.x + 50, g.diff.y + 5)
	testing.expect_value(t, moved, ui.Changes_Hit{.File_Header, 1, 0})
	state.diff_scroll = 0

	scope := ui.changes_hit(g, &view, &state, g.scope.x + g.scope.width / 2, g.scope.y + 5)
	testing.expect_value(t, scope, ui.Changes_Hit{.Scope, 0, 0})
	hooks := ui.changes_hit(g, &view, &state, g.hooks.x + 3, g.hooks.y + 3)
	testing.expect_value(t, hooks, ui.Changes_Hit{.Hooks, 0, 0})
	gap := ui.changes_hit(g, &view, &state, g.repository.x + 1, g.repository.y + 3)
	testing.expect_value(t, gap, ui.Changes_Hit{})
	outside := ui.changes_hit(g, &view, &state, -5, -5)
	testing.expect_value(t, outside, ui.Changes_Hit{})

	view.turns, view.files = nil, nil
	view.notice = .Recording_Off
	view.revision += 1
	g = ui.changes_geometry({0, 0, 900, 600}, 1, &view, &f.text)
	ui.changes_layout(&state, &view, &f.text, &f.mono, g.diff.width, 1)
	button := g.notice_button
	pressed := ui.changes_hit(g, &view, &state, button.x + button.width / 2, button.y + button.height / 2)
	testing.expect_value(t, pressed, ui.Changes_Hit{.Notice_Button, 0, 0})
	elsewhere := ui.changes_hit(g, &view, &state, g.diff.x + 5, g.diff.y + 5)
	testing.expect_value(t, elsewhere, ui.Changes_Hit{})
}

@(test)
changes_hit_answers_the_open_turn_list_first :: proc(t: ^testing.T) {
	f: Changes_Fixture
	view: ui.Changes_View
	if !fixture_make(t, &f, &view) {return}
	defer font.system_destroy(f.fonts)
	state: ui.Changes_State
	defer ui.changes_state_destroy(&state)
	g := ui.changes_geometry({0, 0, 900, 600}, 1, &view, &f.text)
	ui.changes_layout(&state, &view, &f.text, &f.mono, g.diff.width, 1)
	list := g.turn_list
	x := list.x + 40
	third := list.y + 4 + 2 * 40 + 20

	// Closed, the point belongs to the diff under it.
	testing.expect(t, ui.changes_hit(g, &view, &state, x, third).part != .Turn_List_Row)
	state.turn_list_open = true
	testing.expect_value(t, ui.changes_hit(g, &view, &state, x, third), ui.Changes_Hit{.Turn_List_Row, 2, 0})
	first := ui.changes_hit(g, &view, &state, x, list.y + 4 + 1)
	testing.expect_value(t, first, ui.Changes_Hit{.Turn_List_Row, 0, 0})
	padding := ui.changes_hit(g, &view, &state, x, list.y + 1)
	testing.expect_value(t, padding, ui.Changes_Hit{.Turn_List_Row, -1, 0})
	// Outside the list the toolbar still answers.
	label_x, label_y := centre(g.range_label)
	label := ui.changes_hit(g, &view, &state, label_x, label_y)
	testing.expect_value(t, label, ui.Changes_Hit{.Range_Label, 0, 0})

	// A short pane cuts the list, which then scrolls on its own.
	short := ui.changes_geometry({0, 0, 900, 150}, 1, &view, &f.text)
	testing.expect_value(t, short.turn_list, render.Rect{short.range_label.x, 32, 320, 150 - 8 - 32})
	limit := 5 * 40 - int(short.turn_list.height - 8)
	testing.expect(t, ui.changes_scroll_turn_list(&state, short, &view, 10_000))
	testing.expect_value(t, state.turn_list_scroll, limit)
	testing.expect(t, !ui.changes_scroll_turn_list(&state, short, &view, 1))
	scrolled := ui.changes_hit(short, &view, &state, x, short.turn_list.y + 4 + 1)
	testing.expect_value(t, scrolled, ui.Changes_Hit{.Turn_List_Row, limit / 40, 0})
	bar, visible := ui.changes_turn_list_scrollbar(&state, short, &view)
	testing.expect(t, visible && bar.extent.total == 200)

	testing.expect(t, ui.changes_turn_list_reveal(&state, short, &view, 0))
	testing.expect_value(t, state.turn_list_scroll, 0)
	testing.expect(t, !ui.changes_turn_list_reveal(&state, short, &view, 0))
	testing.expect(t, ui.changes_turn_list_reveal(&state, short, &view, 4))
	testing.expect_value(t, state.turn_list_scroll, limit)
	testing.expect(t, !ui.changes_turn_list_reveal(&state, short, &view, 9))
}

@(test)
changes_strip_bars_grow_with_the_lines_and_follow_the_selection :: proc(t: ^testing.T) {
	f: Changes_Fixture
	view: ui.Changes_View
	if !fixture_make(t, &f, &view) {return}
	defer font.system_destroy(f.fonts)
	state: ui.Changes_State
	defer ui.changes_state_destroy(&state)
	f.rows[2].between = true
	f.rows[0].live = true

	g := ui.changes_geometry({0, 0, 900, 600}, 1, &view, &f.text)
	// Bottom-aligned 2 above the strip's bottom, 6 + 3 log2(lines + 1) high: five changed lines give 14.
	testing.expect_value(t, ui.changes_strip_bar_rect(g, &state, &view, 4), render.Rect{260, 10, 8, 14})
	testing.expect_value(t, ui.changes_strip_bar_rect(g, &state, &view, 3), render.Rect{271, 11, 8, 13})
	// Between turns stay short; a live turn stands full height.
	testing.expect_value(t, ui.changes_strip_bar_rect(g, &state, &view, 2), render.Rect{282, 16, 8, 8})
	testing.expect_value(t, ui.changes_strip_bar_rect(g, &state, &view, 0), render.Rect{304, 4, 8, 20})
	testing.expect_value(t, ui.changes_strip_bar_rect(g, &state, &view, 5), render.Rect{})
	testing.expect_value(t, ui.changes_strip_bar_rect(g, &state, &view, -1), render.Rect{})

	// A pane with room for two bars and the newer marker's slot.
	view.first, view.last = 0, 0
	narrow: ui.Changes_Geometry
	for width := f32(700); width > 250; width -= 1 {
		narrow = ui.changes_geometry({0, 0, width, 600}, 1, &view, &f.text, &state)
		if narrow.strip_bars == 2 {break}
	}
	if !testing.expect_value(t, narrow.strip_bars, 2) {return}
	testing.expect_value(t, narrow.strip.width, f32(19))
	// Unrevealed, the oldest bars show.
	testing.expect_value(t, ui.changes_strip_bar_rect(narrow, &state, &view, 0), render.Rect{})
	testing.expect(t, ui.changes_strip_bar_rect(narrow, &state, &view, 4).x == narrow.strip.x)

	// The selection's newest end comes into view and the newest bar sits at the right.
	testing.expect(t, ui.changes_strip_reveal(&state, narrow, &view))
	testing.expect_value(t, state.strip_offset, 3)
	testing.expect(t, !ui.changes_strip_reveal(&state, narrow, &view))
	testing.expect_value(t, ui.changes_strip_bar_rect(narrow, &state, &view, 0).x, narrow.strip.x + 11)
	testing.expect_value(t, ui.changes_strip_bar_rect(narrow, &state, &view, 1).x, narrow.strip.x)
	testing.expect_value(t, ui.changes_strip_bar_rect(narrow, &state, &view, 2), render.Rect{})
	x, y := centre(ui.changes_strip_bar_rect(narrow, &state, &view, 1))
	testing.expect_value(t, ui.changes_hit(narrow, &view, &state, x, y), ui.Changes_Hit{.Strip_Bar, 1, 0})

	view.first, view.last = 3, 4
	testing.expect(t, ui.changes_strip_reveal(&state, narrow, &view))
	testing.expect_value(t, state.strip_offset, 1)
	view.first, view.last = 4, 4
	testing.expect(t, ui.changes_strip_reveal(&state, narrow, &view))
	testing.expect_value(t, state.strip_offset, 0)

	// The wheel moves it within the bars there are.
	testing.expect(t, ui.changes_scroll_strip(&state, narrow, &view, 10))
	testing.expect_value(t, state.strip_offset, 3)
	testing.expect(t, !ui.changes_scroll_strip(&state, narrow, &view, 1))
	testing.expect(t, ui.changes_scroll_strip(&state, narrow, &view, -2))
	testing.expect_value(t, state.strip_offset, 1)
	testing.expect(t, ui.changes_scroll_strip(&state, narrow, &view, -10))
	testing.expect_value(t, state.strip_offset, 0)
}

@(test)
changes_strip_stays_where_paged_and_keeps_a_bar :: proc(t: ^testing.T) {
	device, device_error := render.device_create(.Warp)
	if !testing.expect_value(t, device_error, render.Error.None) {return}
	defer render.device_destroy(device)
	f: Changes_Fixture
	view: ui.Changes_View
	if !fixture_make(t, &f, &view) {return}
	defer font.system_destroy(f.fonts)
	cache: glyphs.Cache
	glyphs.init(&cache, f.fonts, device)
	defer glyphs.destroy(&cache)
	if !testing.expect(t, ui.text_init(&f.text, f.fonts, &cache, 13)) {return}
	f.mono = ui.text_mono(&f.text, f.text.family)
	state: ui.Changes_State
	defer ui.changes_state_destroy(&state)
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	more: [12]ui.Changes_Turn
	for &row, i in more {row = {title = "turn", files = 1, added = i, removed = 1, agent = -1}}
	view.turns = more[:]
	view.first, view.last = 0, 0

	// A narrow pane with four bars beside the older marker while on the newest turn.
	state.strip_offset = 1000
	area: render.Rect
	g: ui.Changes_Geometry
	for width := f32(900); width > 250; width -= 1 {
		area = {0, 0, width, 600}
		g = ui.changes_geometry(area, 1, &view, &f.text, &state)
		if g.strip_bars == 4 {break}
	}
	if !testing.expect_value(t, g.strip_bars, 4) {return}
	ui.changes_layout(&state, &view, &f.text, &f.mono, g.diff.width, 1)
	if !draw_into(t, &f, &list, &view, &state, g) {return}
	testing.expect_value(t, state.strip_offset, 8)

	// Paging older lands in the middle: both markers take room, so fewer bars fit, and the strip stays.
	testing.expect(t, ui.changes_scroll_strip(&state, g, &view, -g.strip_bars))
	testing.expect_value(t, state.strip_offset, 4)
	middle := ui.changes_geometry(area, 1, &view, &f.text, &state)
	testing.expect(t, middle.strip_bars >= 1 && middle.strip_bars < g.strip_bars)
	testing.expect(t, middle.strip_older.width > 0 && middle.strip_newer.width > 0)
	if !draw_into(t, &f, &list, &view, &state, middle) {return}
	testing.expect_value(t, state.strip_offset, 4)
	again := ui.changes_geometry(area, 1, &view, &f.text, &state)
	if !draw_into(t, &f, &list, &view, &state, again) {return}
	testing.expect_value(t, state.strip_offset, 4)
	// So does the wheel.
	testing.expect(t, ui.changes_scroll_strip(&state, again, &view, -1))
	wheeled := ui.changes_geometry(area, 1, &view, &f.text, &state)
	if !draw_into(t, &f, &list, &view, &state, wheeled) {return}
	testing.expect_value(t, state.strip_offset, 3)

	// Five turns in a pane with room for one bar beside a marker: selecting the middle turn keeps a bar,
	// and it is the selection's, with both markers beside it.
	view.turns = f.rows[:]
	state.strip_offset = 1000
	for width := f32(900); width > 250; width -= 1 {
		area = {0, 0, width, 600}
		g = ui.changes_geometry(area, 1, &view, &f.text, &state)
		if g.strip_bars == 1 {break}
	}
	if !testing.expect_value(t, g.strip_bars, 1) {return}
	if !draw_into(t, &f, &list, &view, &state, g) {return}
	view.first, view.last = 2, 2
	if !draw_into(t, &f, &list, &view, &state, ui.changes_geometry(area, 1, &view, &f.text, &state)) {return}
	fresh := ui.changes_geometry(area, 1, &view, &f.text, &state)
	testing.expect_value(t, fresh.strip_bars, 1)
	testing.expect(t, ui.changes_strip_bar_rect(fresh, &state, &view, 2).width > 0)
	older, newer := ui.changes_strip_hidden(fresh, &state, &view)
	testing.expect_value(t, older, 2)
	testing.expect_value(t, newer, 2)
	testing.expect(t, fresh.strip_older.width > 0 && fresh.strip_newer.width > 0)
}

@(test)
changes_strip_caps_at_ten_bars_and_counts_the_rest :: proc(t: ^testing.T) {
	device, device_error := render.device_create(.Warp)
	if !testing.expect_value(t, device_error, render.Error.None) {return}
	defer render.device_destroy(device)
	f: Changes_Fixture
	view: ui.Changes_View
	if !fixture_make(t, &f, &view) {return}
	defer font.system_destroy(f.fonts)
	cache: glyphs.Cache
	glyphs.init(&cache, f.fonts, device)
	defer glyphs.destroy(&cache)
	if !testing.expect(t, ui.text_init(&f.text, f.fonts, &cache, 13)) {return}
	f.mono = ui.text_mono(&f.text, f.text.family)
	state: ui.Changes_State
	defer ui.changes_state_destroy(&state)
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	many: [100]ui.Changes_Turn
	for &row, i in many {row = {title = "turn", files = 1, added = i, removed = 1, agent = -1}}
	view.turns = many[:]
	view.first, view.last = 0, 0

	// A wide pane shows ten bars of 8 with gaps of 3. Scrolled to the oldest, only newer turns are hidden,
	// so only the newer marker takes room.
	g := ui.changes_geometry({0, 0, 1400, 600}, 1, &view, &f.text, &state)
	ui.changes_layout(&state, &view, &f.text, &f.mono, g.diff.width, 1)
	testing.expect_value(t, g.strip_bars, ui.CHANGES_STRIP_MAX_BARS)
	testing.expect_value(t, g.strip.width, f32(10 * 11 - 3))
	testing.expect_value(t, g.strip_older, render.Rect{})
	testing.expect(t, g.strip_newer.width > 0)
	testing.expect_value(t, g.strip.x, g.step_back.x + g.step_back.width + 4)
	testing.expect_value(t, g.strip_newer.x, g.strip.x + g.strip.width + 4)
	testing.expect_value(t, g.step_forward.x, g.strip_newer.x + g.strip_newer.width + 4)
	older, newer := ui.changes_strip_hidden(g, &state, &view)
	testing.expect_value(t, older, 0)
	testing.expect_value(t, newer, 90)
	newer_x, newer_y := centre(g.strip_newer)
	on_newer := ui.changes_hit(g, &view, &state, newer_x, newer_y)
	testing.expect_value(t, on_newer, ui.Changes_Hit{.Strip_Newer, 0, 0})
	testing.expect_value(t, ui.changes_strip_bar_rect(g, &state, &view, 99).x, g.strip.x)

	// On the newest turn: 90 older turns hidden, none newer, and the older marker leads the strip.
	testing.expect(t, ui.changes_strip_reveal(&state, g, &view))
	g = ui.changes_geometry({0, 0, 1400, 600}, 1, &view, &f.text, &state)
	older, newer = ui.changes_strip_hidden(g, &state, &view)
	testing.expect_value(t, older, 90)
	testing.expect_value(t, newer, 0)
	testing.expect_value(t, g.strip_bars, 10)
	testing.expect_value(t, g.strip_newer, render.Rect{})
	testing.expect_value(t, g.strip_older.x, g.step_back.x + g.step_back.width + 4)
	testing.expect_value(t, g.strip.x, g.strip_older.x + g.strip_older.width + 4)
	testing.expect_value(t, g.step_forward.x, g.strip.x + g.strip.width + 4)
	testing.expect_value(t, ui.changes_strip_marker_rect(g, &state, &view, false), g.strip_older)
	testing.expect_value(t, ui.changes_strip_marker_rect(g, &state, &view, true), render.Rect{})
	older_x, older_y := centre(g.strip_older)
	on_older := ui.changes_hit(g, &view, &state, older_x, older_y)
	testing.expect_value(t, on_older, ui.Changes_Hit{.Strip_Older, 0, 0})
	if !draw_into(t, &f, &list, &view, &state, g) {return}
	marked := 0
	for glyph in list.glyphs {
		x := glyph.rect.x + glyph.rect.width / 2
		in_slot := x >= g.strip_older.x && x < g.strip_older.x + g.strip_older.width
		if in_slot && glyph.rect.y < g.toolbar.y + g.toolbar.height {marked += 1}
	}
	// "+90"
	testing.expect(t, marked >= 2)

	// In the middle both sides hide turns and both markers take room.
	state.strip_offset = 40
	middle := ui.changes_geometry({0, 0, 1400, 600}, 1, &view, &f.text, &state)
	older, newer = ui.changes_strip_hidden(middle, &state, &view)
	testing.expect_value(t, older, 40)
	testing.expect_value(t, newer, 50)
	testing.expect(t, middle.strip_older.width > 0 && middle.strip_newer.width > 0)
	testing.expect_value(t, middle.strip_bars, 10)

	// A narrow pane fits fewer bars; the older count takes the shortfall too.
	state.strip_offset = 1000
	narrow: ui.Changes_Geometry
	for width := f32(900); width > 250; width -= 1 {
		narrow = ui.changes_geometry({0, 0, width, 600}, 1, &view, &f.text, &state)
		if narrow.strip_bars == 4 {break}
	}
	if !testing.expect_value(t, narrow.strip_bars, 4) {return}
	older, newer = ui.changes_strip_hidden(narrow, &state, &view)
	testing.expect_value(t, older, 96)
	testing.expect_value(t, newer, 0)
	testing.expect_value(t, narrow.strip.width, f32(4 * 11 - 3))
	testing.expect_value(t, narrow.strip_newer, render.Rect{})

	// Twelve turns with room for three bars and the older marker: three bars and nine older turns.
	view.turns = many[:12]
	twelve: ui.Changes_Geometry
	for width := f32(900); width > 250; width -= 1 {
		twelve = ui.changes_geometry({0, 0, width, 600}, 1, &view, &f.text, &state)
		if twelve.strip_bars == 3 {break}
	}
	if !testing.expect_value(t, twelve.strip_bars, 3) {return}
	older, newer = ui.changes_strip_hidden(twelve, &state, &view)
	testing.expect_value(t, older, 9)
	testing.expect_value(t, newer, 0)
	testing.expect(t, twelve.strip_older.width > 0)
	testing.expect_value(t, twelve.strip_newer, render.Rect{})

	// Five turns: all five bars need less room than three bars and a marker, so a pane short of five
	// shows as many bars as fit beside the marker, never fewer than one while it and the marker fit.
	view.turns = f.rows[:]
	five: ui.Changes_Geometry
	for width := f32(900); width > 250; width -= 1 {
		five = ui.changes_geometry({0, 0, width, 600}, 1, &view, &f.text, &state)
		if five.strip_bars < 5 {break}
	}
	testing.expect(t, five.strip_bars >= 1 && five.strip_bars < 5)
	older, newer = ui.changes_strip_hidden(five, &state, &view)
	testing.expect_value(t, older, 5 - five.strip_bars)
	testing.expect_value(t, newer, 0)
	testing.expect(t, five.strip_older.width > 0)
	for width := five.area.width; width > 250; width -= 1 {
		five = ui.changes_geometry({0, 0, width, 600}, 1, &view, &f.text, &state)
		if five.strip_bars <= 1 {break}
	}
	testing.expect_value(t, five.strip_bars, 1)
	testing.expect(t, five.strip_older.width > 0)
	testing.expect(t, five.strip_older.x + five.strip_older.width + 4 == five.strip.x)

	// Ten turns or fewer that fit have no markers.
	view.turns = many[:10]
	ten := ui.changes_geometry({0, 0, 1400, 600}, 1, &view, &f.text, &state)
	testing.expect_value(t, ten.strip_bars, 10)
	testing.expect_value(t, ten.strip_older, render.Rect{})
	testing.expect_value(t, ten.strip_newer, render.Rect{})
	older, newer = ui.changes_strip_hidden(ten, &state, &view)
	testing.expect_value(t, older + newer, 0)
	// One more than the cap shows ten and counts one.
	view.turns = many[:11]
	eleven := ui.changes_geometry({0, 0, 1400, 600}, 1, &view, &f.text, &state)
	testing.expect_value(t, eleven.strip_bars, 10)
	older, newer = ui.changes_strip_hidden(eleven, &state, &view)
	testing.expect_value(t, older, 1)
	testing.expect_value(t, newer, 0)
}

@(test)
changes_range_label_and_tooltip_name_the_turns :: proc(t: ^testing.T) {
	f: Changes_Fixture
	view: ui.Changes_View
	if !fixture_make(t, &f, &view) {return}
	defer font.system_destroy(f.fonts)
	buf: [64]u8

	testing.expect_value(t, ui.changes_range_label(&view, buf[:]), "No turn selected")
	view.first, view.last = 0, 0
	testing.expect_value(t, ui.changes_range_label(&view, buf[:]), "Turn 5")
	view.first, view.last = 4, 4
	testing.expect_value(t, ui.changes_range_label(&view, buf[:]), "Turn 1")
	view.first, view.last = 1, 3
	testing.expect_value(t, ui.changes_range_label(&view, buf[:]), "Turns 2–4")
	f.rows[0].live = true
	view.first, view.last = 0, 0
	testing.expect_value(t, ui.changes_range_label(&view, buf[:]), "Working…")
	view.first, view.last = 0, 1
	testing.expect_value(t, ui.changes_range_label(&view, buf[:]), "Turns 4–5")
	view.turns = nil
	testing.expect_value(t, ui.changes_range_label(&view, buf[:]), "No turns")
	view.turns = f.rows[:]

	one := ui.changes_turn_tooltip(&view, 1, context.temp_allocator)
	testing.expect_value(t, one, "turn · now · +1 −1 · 2 files")
	live := ui.changes_turn_tooltip(&view, 0, context.temp_allocator)
	testing.expect_value(t, live, "Working… · turn · +0 −1 · 1 file")
	f.rows[2].title, f.rows[2].between, f.rows[2].detail = "", true, ""
	between := ui.changes_turn_tooltip(&view, 2, context.temp_allocator)
	testing.expect_value(t, between, "Changes between turns · +2 −1 · 3 files")
	testing.expect_value(t, ui.changes_turn_tooltip(&view, 5, context.temp_allocator), "")
}

// Draws the pane into `list` as the pane does: a fresh list over a layer, with glyphs to draw text with.
@(private = "file")
draw_into :: proc(
	t: ^testing.T,
	f: ^Changes_Fixture,
	list: ^render.Draw_List,
	view: ^ui.Changes_View,
	state: ^ui.Changes_State,
	g: ui.Changes_Geometry,
) -> bool {
	render.draw_list_reset(list)
	if !testing.expect_value(t, render.push_layer(list, g.area), render.Error.None) {return false}
	theme: ui.Theme
	theme.text, theme.muted = {1, 1, 1, 1}, {1, 1, 1, 1}
	theme.success, theme.error = {0, 1, 0, 1}, {1, 0, 0, 1}
	status, _ := ui.changes_draw(list, &f.text, &f.mono, &theme, g, view, state, 1, {-1, -1}, 0)
	return testing.expect_value(t, status, render.Build_Status.Ok)
}

@(test)
changes_draw_keeps_the_selected_bar_in_view_after_a_resize :: proc(t: ^testing.T) {
	device, device_error := render.device_create(.Warp)
	if !testing.expect_value(t, device_error, render.Error.None) {return}
	defer render.device_destroy(device)
	f: Changes_Fixture
	view: ui.Changes_View
	if !fixture_make(t, &f, &view) {return}
	defer font.system_destroy(f.fonts)
	cache: glyphs.Cache
	glyphs.init(&cache, f.fonts, device)
	defer glyphs.destroy(&cache)
	if !testing.expect(t, ui.text_init(&f.text, f.fonts, &cache, 13)) {return}
	f.mono = ui.text_mono(&f.text, f.text.family)
	state: ui.Changes_State
	defer ui.changes_state_destroy(&state)
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	more: [12]ui.Changes_Turn
	for &row, i in more {row = {title = "turn", files = 1, added = i, removed = 1, agent = -1}}
	view.turns = more[:]
	view.first, view.last = 0, 0

	narrow: ui.Changes_Geometry
	for width := f32(700); width > 250; width -= 1 {
		narrow = ui.changes_geometry({0, 0, width, 600}, 1, &view, &f.text)
		if narrow.strip_bars == 2 {break}
	}
	if !testing.expect_value(t, narrow.strip_bars, 2) {return}
	wide := ui.changes_geometry({0, 0, 900, 600}, 1, &view, &f.text)
	ui.changes_layout(&state, &view, &f.text, &f.mono, wide.diff.width, 1)

	// Nothing revealed the selection before the first draw, as for a pane drawn after a tab switch.
	if !draw_into(t, &f, &list, &view, &state, narrow) {return}
	testing.expect_value(t, state.strip_offset, 10)
	testing.expect(t, ui.changes_strip_bar_rect(narrow, &state, &view, 0).width > 0)
	// Wide, ten of the twelve show, newest at the right.
	if !draw_into(t, &f, &list, &view, &state, wide) {return}
	testing.expect_value(t, state.strip_offset, 2)
	// Narrowing again keeps the newest bar, which is selected, in view.
	if !draw_into(t, &f, &list, &view, &state, narrow) {return}
	testing.expect_value(t, state.strip_offset, 10)
	testing.expect(t, ui.changes_strip_bar_rect(narrow, &state, &view, 0).width > 0)

	// The wheel's offset stays while nothing changes.
	testing.expect(t, ui.changes_scroll_strip(&state, narrow, &view, -2))
	if !draw_into(t, &f, &list, &view, &state, narrow) {return}
	testing.expect_value(t, state.strip_offset, 8)

	// A turn that arrived while the pane was hidden is revealed when it is drawn. The draw lays the strip
	// out again for the new offset, so check against a fresh layout.
	view.turns = more[1:]
	if !draw_into(t, &f, &list, &view, &state, narrow) {return}
	fresh := ui.changes_geometry(narrow.area, 1, &view, &f.text, &state)
	testing.expect_value(t, state.strip_offset, 11 - fresh.strip_bars)
	testing.expect(t, ui.changes_strip_bar_rect(fresh, &state, &view, 0).width > 0)
	older, newer := ui.changes_strip_hidden(fresh, &state, &view)
	testing.expect_value(t, older, 11 - fresh.strip_bars)
	testing.expect_value(t, newer, 0)
}

@(test)
changes_comments_stay_reachable_under_a_notice :: proc(t: ^testing.T) {
	device, device_error := render.device_create(.Warp)
	if !testing.expect_value(t, device_error, render.Error.None) {return}
	defer render.device_destroy(device)
	f: Changes_Fixture
	view: ui.Changes_View
	if !fixture_make(t, &f, &view) {return}
	defer font.system_destroy(f.fonts)
	cache: glyphs.Cache
	glyphs.init(&cache, f.fonts, device)
	defer glyphs.destroy(&cache)
	if !testing.expect(t, ui.text_init(&f.text, f.fonts, &cache, 13)) {return}
	f.mono = ui.text_mono(&f.text, f.text.family)
	state: ui.Changes_State
	defer ui.changes_state_destroy(&state)
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)

	// A comment on lines of file 0 while the selected turn changed nothing.
	comments := [1]ui.Changes_Comment_View{{file = 0, first = 0, last = 1, text = "Check this"}}
	view.comments = comments[:]
	view.send.count = 1
	view.notice = .No_Changes
	g := ui.changes_geometry({0, 0, 900, 600}, 1, &view, &f.text)
	ui.changes_layout(&state, &view, &f.text, &f.mono, g.diff.width, 1)

	// The notice moves to the top and the stream, now only the comments, sits under it.
	testing.expect(t, g.notice.width > 0 && g.notice.y + g.notice.height <= g.diff.y)
	testing.expect_value(t, g.notice.y, f32(28 + 24))
	testing.expect_value(t, g.diff.y + g.diff.height, g.send_bar.y)
	rows := state.rows
	if !testing.expect(t, rows.detached > 0 && len(rows.cards) > 0 && rows.cards[0] > 0) {return}
	testing.expect_value(t, rows.total, rows.detached)

	// The card sits under the group's heading, 16 in from the stream's edges.
	card := render.Rect {
		g.diff.x + 16, g.diff.y + f32(rows.header) + 4, g.diff.width - 32, f32(rows.cards[0]),
	}
	on_card := ui.changes_hit(g, &view, &state, card.x + 20, card.y + card.height / 2)
	testing.expect_value(t, on_card, ui.Changes_Hit{.Comment_Card, 0, 0})
	on_delete := ui.changes_hit(g, &view, &state, card.x + card.width - 4 - 12, card.y + 4 + 12)
	testing.expect_value(t, on_delete, ui.Changes_Hit{.Comment_Delete, 0, 0})
	beside := ui.changes_hit(g, &view, &state, card.x + 20, card.y + card.height + 40)
	testing.expect_value(t, beside, ui.Changes_Hit{})

	if !draw_into(t, &f, &list, &view, &state, g) {return}
	heading, text := 0, 0
	for glyph in list.glyphs {
		y := glyph.rect.y + glyph.rect.height / 2
		if y >= g.diff.y && y < card.y {heading += 1}
		if y >= card.y && y < card.y + card.height {text += 1}
	}
	testing.expect(t, heading > 0)
	testing.expect(t, text > 0)
}

@(test)
changes_scroll_clamps_the_diff :: proc(t: ^testing.T) {
	f: Changes_Fixture
	view: ui.Changes_View
	if !fixture_make(t, &f, &view) {return}
	defer font.system_destroy(f.fonts)
	state: ui.Changes_State
	defer ui.changes_state_destroy(&state)
	g := ui.changes_geometry({0, 0, 900, 100}, 1, &view, &f.text)
	ui.changes_layout(&state, &view, &f.text, &f.mono, g.diff.width, 1)
	visible := int(g.diff.height)
	limit := state.rows.total - visible
	if !testing.expect(t, limit > 0) {return}

	testing.expect(t, ui.changes_scroll_diff(&state, g, 10_000))
	testing.expect_value(t, state.diff_scroll, limit)
	testing.expect(t, !ui.changes_scroll_diff(&state, g, 5))
	testing.expect(t, ui.changes_scroll_diff(&state, g, -3))
	testing.expect_value(t, state.diff_scroll, limit - 3)
	testing.expect(t, ui.changes_scroll_diff(&state, g, -10_000))
	testing.expect_value(t, state.diff_scroll, 0)
	testing.expect(t, !ui.changes_scroll_diff(&state, g, -1))

	extent := ui.changes_diff_extent(&state, g)
	testing.expect_value(t, extent, ui.Scroll_Extent{total = state.rows.total, visible = visible, offset = 0})
	state.diff_scroll = 99_999
	testing.expect_value(t, ui.changes_diff_extent(&state, g).offset, limit)
}

@(test)
changes_text_helpers_never_walk_a_whole_long_line :: proc(t: ^testing.T) {
	long := strings.repeat("x", 1 << 20, context.temp_allocator)
	prefix := ui.mono_prefix(long, 400, 8)
	testing.expect_value(t, len(prefix), 52)
	testing.expect(t, raw_data(prefix) == raw_data(long))
	testing.expect_value(t, ui.mono_prefix("short", 400, 8), "short")
	testing.expect_value(t, ui.mono_prefix("abcdef", 0, 8), "ab")
	// Multi-byte runes are counted as runes and never split.
	testing.expect_value(t, ui.mono_prefix("ééééé", 16, 8), "éééé")
	testing.expect_value(t, ui.mono_prefix("éé", 400, 0), "éé")

	clipped := ui.clip_bytes(long, 512)
	testing.expect_value(t, len(clipped), 512)
	testing.expect_value(t, ui.clip_bytes("abc", 512), "abc")
	testing.expect_value(t, ui.clip_bytes("ééé", 3), "é")
}

@(test)
changes_worktree_field_belongs_to_git_scopes_and_is_hit :: proc(t: ^testing.T) {
	f: Changes_Fixture
	view: ui.Changes_View
	if !fixture_make(t, &f, &view) {return}
	defer font.system_destroy(f.fonts)
	state: ui.Changes_State
	defer ui.changes_state_destroy(&state)

	turns_g := ui.changes_geometry({0, 0, 900, 600}, 1, &view, &f.text)
	testing.expect_value(t, turns_g.worktree.width, f32(0))

	view.scope, view.turns, view.worktree, view.following = .Uncommitted, nil, "wt-a", true
	view.hooks_offer = true
	g := ui.changes_geometry({0, 0, 900, 600}, 1, &view, &f.text)
	testing.expect(t, g.worktree.width > 0 && g.worktree.height == g.scope.height)
	testing.expect(t, g.worktree.x >= g.scope.x + g.scope.width)
	testing.expect(t, g.repository.x >= g.worktree.x + g.worktree.width)
	testing.expect(t, g.worktree.x + g.worktree.width <= g.hooks.x)
	ui.changes_layout(&state, &view, &f.text, &f.mono, g.diff.width, 1)
	hit := ui.changes_hit(g, &view, &state, g.worktree.x + 4, g.worktree.y + 4)
	testing.expect_value(t, hit, ui.Changes_Hit{.Worktree, 0, 0})
	scope := ui.changes_hit(g, &view, &state, g.scope.x + 4, g.scope.y + 4)
	testing.expect_value(t, scope, ui.Changes_Hit{.Scope, 0, 0})

	tiny := ui.changes_geometry({0, 0, 120, 200}, 1, &view, &f.text)
	testing.expect(t, tiny.worktree.x + tiny.worktree.width <= tiny.hooks.x || tiny.worktree.width == 0)
}

@(test)
changes_badges_fall_back_to_icons_when_the_path_has_no_room :: proc(t: ^testing.T) {
	f: Changes_Fixture
	view: ui.Changes_View
	if !fixture_make(t, &f, &view) {return}
	defer font.system_destroy(f.fonts)
	small := ui.text_styled(&f.text, .Detail)
	marked := [2]bool{true, true}
	ambiguous := [2]bool{false, true}
	view.marked, view.ambiguous = marked[:], ambiguous[:]

	roomy := ui.changes_badge_forms(&view, 0, &small, 2000, 1)
	testing.expect_value(t, roomy[.Marked], ui.Changes_Badge_Form.Text)
	testing.expect_value(t, roomy[.Ambiguous], ui.Changes_Badge_Form.Hidden)
	both := ui.changes_badge_forms(&view, 1, &small, 2000, 1)
	testing.expect_value(t, both[.Marked], ui.Changes_Badge_Form.Text)
	testing.expect_value(t, both[.Ambiguous], ui.Changes_Badge_Form.Text)

	labels := ui.CHANGES_BADGE_LABELS
	first := ui.text_width(&small, labels[.Marked])
	second := ui.text_width(&small, labels[.Ambiguous])
	// Room for the path and the first text only: the second falls back to its icon alone.
	partial := ui.changes_badge_forms(&view, 1, &small, first + 96 + 1, 1)
	testing.expect_value(t, partial[.Marked], ui.Changes_Badge_Form.Text)
	testing.expect_value(t, partial[.Ambiguous], ui.Changes_Badge_Form.Icon)
	_ = second
	narrow := ui.changes_badge_forms(&view, 1, &small, 50, 1)
	testing.expect_value(t, narrow[.Marked], ui.Changes_Badge_Form.Icon)
	testing.expect_value(t, narrow[.Ambiguous], ui.Changes_Badge_Form.Icon)

	view.marked, view.ambiguous = nil, nil
	none := ui.changes_badge_forms(&view, 0, &small, 2000, 1)
	testing.expect_value(t, none[.Marked], ui.Changes_Badge_Form.Hidden)
}
