package ui_test

import "cosmos:font"
import "cosmos:glyphs"
import "aio:markdown"
import "cosmos:render"
import "aio:turns"
import "aio:ui"
import "core:strings"
import "core:testing"

@(private = "file")
Selection_Fixture :: struct {
	fonts:      ^font.System,
	text, mono: ui.Text,
	lines:      [40]turns.Diff_Line,
	hunks:      [1]turns.Hunk,
	files:      [1]turns.Diff_File,
	area:       ui.Text_Area,
	buffer:     markdown.Edit_Buffer,
	notes:      [2]ui.Changes_Comment_View,
}

@(private = "file")
SELECTION_LABELS :: "Clarify | blue | Explain it; Verify | #ff8800 | Check it; Good | green"

// One file with one hunk: a context line, a removed and an added one, a context line 200 bytes long, and
// filler to scroll through. Line 0 reads "alpha beta gamma" and line 2 "delta epsilon zeta".
@(private = "file")
select_make :: proc(t: ^testing.T, f: ^Selection_Fixture, view: ^ui.Changes_View) -> bool {
	err: font.Error
	f.fonts, err = font.system_create()
	if !testing.expect_value(t, err, font.Error.None) {return false}
	if !testing.expect(t, ui.text_init(&f.text, f.fonts, nil, 13)) {
		font.system_destroy(f.fonts)
		return false
	}
	f.mono = ui.text_mono(&f.text, f.text.family)
	f.lines[0] = {kind = .Context, old_line = 1, new_line = 1, text = "alpha beta gamma"}
	f.lines[1] = {kind = .Removed, old_line = 2, text = "gone"}
	f.lines[2] = {kind = .Added, new_line = 2, text = "delta epsilon zeta"}
	f.lines[3] = {
		kind     = .Context,
		old_line = 3,
		new_line = 3,
		text     = strings.repeat("0123456789", 20, context.temp_allocator),
	}
	for i in 4 ..< len(f.lines) {
		f.lines[i] = {kind = .Context, old_line = i32(i), new_line = i32(i), text = "filler"}
	}
	f.hunks = {{old_start = 1, old_count = 39, new_start = 1, new_count = 39, lines = f.lines[:]}}
	f.files = {{old_path = "a.odin", new_path = "a.odin", status = .Modified, added = 1, removed = 1,
		hunks = f.hunks[:]}}
	view^ = {
		scope         = .Uncommitted,
		first         = -1,
		last          = -1,
		files         = f.files[:],
		editing       = -1,
		editor        = &f.area,
		buffer        = &f.buffer,
		revision      = 1,
		quick_labels  = SELECTION_LABELS,
	}
	return true
}

@(private = "file")
select_destroy :: proc(f: ^Selection_Fixture) {
	markdown.edit_buffer_destroy(&f.buffer)
	ui.text_area_destroy(&f.area)
	font.system_destroy(f.fonts)
}

// Lays the pane out in an area `width` by `height` and places the selection bar, as the pane does.
@(private = "file")
select_place :: proc(
	f: ^Selection_Fixture, view: ^ui.Changes_View, state: ^ui.Changes_State, width: f32 = 900, height: f32 = 600,
) -> ui.Changes_Geometry {
	g := ui.changes_geometry({0, 0, width, height}, 1, view, &f.text, state)
	ui.changes_layout(state, view, &f.text, &f.mono, g.diff.width, 1)
	g.selection_bar = ui.changes_selection_place(g, view, state, &f.text, &f.mono)
	return g
}

@(private = "file")
near :: proc(a, b: f32) -> bool {return abs(a - b) < 0.01}

// A selection of text from byte `from` of flat line `first` to byte `to` of flat line `last` of file 0.
@(private = "file")
text_selection :: proc(first, last, from, to: int) -> ui.Changes_Selection {
	return {file = 0, first = first, last = last, active = true, partial = true, first_offset = from,
		last_offset = to}
}

@(private = "file")
colour_near :: proc(a, b: render.Color) -> bool {
	return near(a.r, b.r) && near(a.g, b.g) && near(a.b, b.b) && near(a.a, b.a)
}

@(test)
selection_bar_sits_above_the_first_line_and_below_the_last_when_there_is_no_room :: proc(t: ^testing.T) {
	f: Selection_Fixture
	view: ui.Changes_View
	if !select_make(t, &f, &view) {return}
	defer select_destroy(&f)
	state: ui.Changes_State
	defer ui.changes_state_destroy(&state)
	view.selection = {file = 0, first = 10, last = 11, active = true}
	g := select_place(&f, &view, &state)
	bar := g.selection_bar
	if !testing.expect(t, bar.bar.width > 0) {return}

	// Four padding around 24 tall buttons, and 6 between the bar and the first selected line: Delete, Comment,
	// a divider, Label. The bar's bottom edge is that far above the first line's top, not a row higher.
	first := ui.changes_line_rect(g, &view, &state, 0, 10)
	testing.expect_value(t, bar.bar.height, f32(32))
	testing.expect_value(t, bar.bar.y, first.y - 6 - 32)
	testing.expect_value(t, bar.bar.y + bar.bar.height + 6, first.y)
	for rect in ([?]render.Rect{bar.delete, bar.comment, bar.label}) {
		testing.expect_value(t, rect.height, f32(24))
		testing.expect_value(t, rect.y, bar.bar.y + 4)
	}
	testing.expect_value(t, bar.delete.x, bar.bar.x + 4)
	testing.expect_value(t, bar.comment.x, bar.delete.x + bar.delete.width)
	testing.expect_value(t, bar.divider.x, bar.comment.x + bar.comment.width)
	testing.expect_value(t, bar.label.x, bar.divider.x + bar.divider.width)
	testing.expect_value(t, bar.label.x + bar.label.width + 4, bar.bar.x + bar.bar.width)
	testing.expect(t, bar.words, "a wide pane has words beside the icons")
	testing.expect_value(t, ui.changes_hit(g, &view, &state, bar.delete.x + 2, bar.delete.y + 2),
		ui.Changes_Hit{.Toolbar_Delete, 0, 0})
	testing.expect_value(t, ui.changes_hit(g, &view, &state, bar.comment.x + 2, bar.comment.y + 2),
		ui.Changes_Hit{.Toolbar_Comment, 0, 0})
	testing.expect_value(t, ui.changes_hit(g, &view, &state, bar.label.x + 2, bar.label.y + 2),
		ui.Changes_Hit{.Toolbar_Label, 0, 0})
	testing.expect_value(t, ui.changes_hit(g, &view, &state, bar.bar.x + 1, bar.bar.y + 1),
		ui.Changes_Hit{.Toolbar, -1, 0})

	// Centred over the start of a text selection, as much of its first line as 200 DIP.
	view.selection = text_selection(3, 3, 60, 80)
	g = select_place(&f, &view, &state)
	_, column, _ := ui.changes_line_code(g, &view, &state, &f.mono, 0, 3)
	text := f.lines[3].text
	begin := ui.code_x_of(&f.mono, text, column.width, 60)
	stop := ui.code_x_of(&f.mono, text, column.width, 80)
	want := column.text_x + begin + min(stop - begin, 200) / 2
	bar = g.selection_bar
	testing.expect(t, abs(bar.bar.x + bar.bar.width / 2 - want) <= 1)

	// A start at the pane's edge is clamped inside it, 8 from the edge.
	view.selection = text_selection(3, 3, 160, 190)
	g = select_place(&f, &view, &state)
	bar = g.selection_bar
	testing.expect_value(t, bar.bar.x + bar.bar.width, g.diff.x + g.diff.width - 8)
	view.selection = text_selection(0, 0, 0, 3)
	g = select_place(&f, &view, &state)
	testing.expect_value(t, g.selection_bar.bar.x, g.diff.x + 8)

	// Scrolled until the first line is at the top, there is no room above: the bar goes below the last line.
	view.selection = {file = 0, first = 10, last = 11, active = true}
	state.diff_scroll += int(first.y - g.diff.y)
	g = select_place(&f, &view, &state)
	last := ui.changes_line_rect(g, &view, &state, 0, 11)
	testing.expect_value(t, g.selection_bar.bar.y, last.y + last.height + 6)

	// Out of view, there is no bar.
	view.selection = {file = 0, first = 0, last = 1, active = true}
	state.diff_scroll = 400
	g = select_place(&f, &view, &state)
	testing.expect_value(t, g.selection_bar.bar, render.Rect{})
	state.diff_scroll = 0
	g = select_place(&f, &view, &state)
	testing.expect(t, g.selection_bar.bar.width > 0)
	view.selecting = true
	g = select_place(&f, &view, &state)
	testing.expect_value(t, g.selection_bar.bar, render.Rect{})
	view.selecting = false
	view.editing = 0
	g = select_place(&f, &view, &state)
	testing.expect_value(t, g.selection_bar.bar, render.Rect{})
	view.editing = -1
	view.selection = {}
	g = select_place(&f, &view, &state)
	testing.expect_value(t, g.selection_bar.bar, render.Rect{})
	testing.expect_value(t, ui.changes_hit(g, &view, &state, bar.delete.x + 2, bar.delete.y + 2).part,
		ui.Changes_Part.Line)
}

@(test)
selection_bar_drops_its_words_in_a_narrow_pane :: proc(t: ^testing.T) {
	f: Selection_Fixture
	view: ui.Changes_View
	if !select_make(t, &f, &view) {return}
	defer select_destroy(&f)
	state: ui.Changes_State
	defer ui.changes_state_destroy(&state)
	view.selection = {file = 0, first = 10, last = 10, active = true}
	wide := select_place(&f, &view, &state).selection_bar
	narrow := select_place(&f, &view, &state, 300).selection_bar
	testing.expect(t, wide.words && !narrow.words)
	testing.expect(t, narrow.bar.width > 0 && narrow.bar.width < wide.bar.width)
	// The buttons are the icon, 8 either side; Label also holds its chevron and a gap.
	testing.expect_value(t, narrow.delete.width, f32(32))
	testing.expect_value(t, narrow.comment.width, f32(32))
	testing.expect_value(t, narrow.label.width, f32(32 + 4 + 12))
}

@(test)
label_menu_hangs_under_the_label_button_and_flips_above_without_room :: proc(t: ^testing.T) {
	f: Selection_Fixture
	view: ui.Changes_View
	if !select_make(t, &f, &view) {return}
	defer select_destroy(&f)
	state: ui.Changes_State
	defer ui.changes_state_destroy(&state)
	view.selection = {file = 0, first = 4, last = 4, active = true}
	g := select_place(&f, &view, &state)
	testing.expect_value(t, g.selection_bar.menu, render.Rect{})
	view.label_menu = true
	g = select_place(&f, &view, &state)
	bar := g.selection_bar
	if !testing.expect_value(t, bar.labels, 3) || !testing.expect_value(t, bar.shown, 3) {return}

	// Under the toolbar, from its Label button; three 32 rows, a divider and the Edit labels row, in 4 padding.
	testing.expect_value(t, bar.menu.y, bar.bar.y + bar.bar.height + 4)
	testing.expect_value(t, bar.menu.x, bar.label.x)
	testing.expect_value(t, bar.menu.height, f32(4 + 3 * 32 + 4 + 32 + 4))
	for k in 0 ..< 3 {
		row := ui.changes_label_row_rect(bar, k)
		testing.expect_value(t, row.height, f32(32))
		testing.expect_value(t, row.y, bar.menu.y + 4 + f32(k) * 32)
		at := render.Rect{row.x + 4, row.y + 4, 1, 1}
		testing.expect_value(t, ui.changes_hit(g, &view, &state, at.x, at.y), ui.Changes_Hit{.Label_Row, k, 0})
	}
	testing.expect_value(t, bar.edit.y, bar.menu.y + 4 + 3 * 32 + 4)
	testing.expect_value(t, ui.changes_hit(g, &view, &state, bar.edit.x + 4, bar.edit.y + 4),
		ui.Changes_Hit{.Label_Edit, 0, 0})
	testing.expect_value(t, ui.changes_hit(g, &view, &state, bar.menu.x + 1, bar.menu.y + 1),
		ui.Changes_Hit{.Label_Menu, -1, 0})
	testing.expect_value(t, ui.changes_hit(g, &view, &state, bar.rule.x + 4, bar.rule.y),
		ui.Changes_Hit{.Label_Menu, -1, 0})

	// Near the bottom of the pane there is no room below, so the menu goes above the toolbar.
	line := ui.changes_line_rect(g, &view, &state, 0, 12)
	g = select_place(&f, &view, &state, 900, line.y + line.height + 10)
	view.selection = {file = 0, first = 12, last = 12, active = true}
	g = select_place(&f, &view, &state, 900, line.y + line.height + 10)
	bar = g.selection_bar
	if !testing.expect(t, bar.menu.width > 0) {return}
	testing.expect_value(t, bar.menu.y + bar.menu.height + 4, bar.bar.y)
	testing.expect_value(t, bar.shown, 3)

	// Too little room for every label on either side shows a run of them around the one the keys are on.
	view.quick_labels = "A | blue; B | red; C | teal; D | gray; E | green; F | violet; G | yellow"
	view.label_row = 5
	g = select_place(&f, &view, &state, 900, line.y + line.height + 10)
	bar = g.selection_bar
	testing.expect_value(t, bar.labels, 7)
	testing.expect(t, bar.shown < 7 && bar.shown >= 1)
	testing.expect(t, bar.first <= 5 && 5 < bar.first + bar.shown)
}

@(test)
text_point_maps_x_to_the_nearest_byte_in_the_half_it_is_in :: proc(t: ^testing.T) {
	f: Selection_Fixture
	view: ui.Changes_View
	if !select_make(t, &f, &view) {return}
	defer select_destroy(&f)
	state: ui.Changes_State
	defer ui.changes_state_destroy(&state)
	g := select_place(&f, &view, &state)
	_, column, _ := ui.changes_line_code(g, &view, &state, &f.mono, 0, 0)
	// A point nearer the boundary after a byte than the one before it lands on that later boundary.
	text := f.lines[0].text
	two, three := ui.code_x_of(&f.mono, text, column.width, 2), ui.code_x_of(&f.mono, text, column.width, 3)
	at, _, ok := ui.changes_text_point(g, &view, &state, &f.mono, 0, 0, column.text_x + two + 0.6 * (three - two))
	testing.expect(t, ok)
	testing.expect_value(t, at, 3)
	at, _, _ = ui.changes_text_point(g, &view, &state, &f.mono, 0, 0, column.text_x + two + 0.4 * (three - two))
	testing.expect_value(t, at, 2)
	at, _, _ = ui.changes_text_point(g, &view, &state, &f.mono, 0, 0, column.text_x - 10)
	testing.expect_value(t, at, 0)
	at, _, _ = ui.changes_text_point(g, &view, &state, &f.mono, 0, 0, g.diff.x + g.diff.width - 1)
	testing.expect_value(t, at, len("alpha beta gamma"))
	// A line with no row has no byte.
	_, _, ok = ui.changes_text_point(g, &view, &state, &f.mono, 0, 99, column.text_x)
	testing.expect(t, !ok)

	// Side by side a context line is in both halves, and a point in the right one measures from there.
	view.side_by_side = true
	view.revision += 1
	g = select_place(&f, &view, &state)
	left_point, left, _ := ui.changes_text_point(g, &view, &state, &f.mono, 0, 0, g.diff.x + 8 + 70)
	right_x := g.diff.x + g.diff.width / 2 + 70
	right_point, right, _ := ui.changes_text_point(g, &view, &state, &f.mono, 0, 0, right_x)
	testing.expect(t, left.x < right.x && left.x + left.width <= right.x)
	testing.expect_value(t, right_point, left_point)
	// A removed line is only in the left half, whatever side the point is on.
	_, removed, _ := ui.changes_text_point(g, &view, &state, &f.mono, 0, 1, right_x)
	testing.expect_value(t, removed.x, left.x)
}


// The rects of the list drawn in `color`.
@(private = "file")
rects_of :: proc(list: ^render.Draw_List, color: render.Color) -> [dynamic]render.Rect {
	found: [dynamic]render.Rect
	for r in list.rects {
		if colour_near(r.color, color) {append(&found, r.rect)}
	}
	return found
}

// How many rects of the list are drawn in `color`.
@(private = "file")
rect_count :: proc(list: ^render.Draw_List, color: render.Color) -> (count: int) {
	for r in list.rects {
		if colour_near(r.color, color) {count += 1}
	}
	return
}

@(private = "file")
draw_selection :: proc(
	t: ^testing.T,
	f: ^Selection_Fixture,
	list: ^render.Draw_List,
	theme: ^ui.Theme,
	view: ^ui.Changes_View,
	state: ^ui.Changes_State,
) -> (
	g: ui.Changes_Geometry,
	ok: bool,
) {
	g = select_place(f, view, state)
	render.draw_list_reset(list)
	if !testing.expect_value(t, render.push_layer(list, g.area), render.Error.None) {return}
	status, _ := ui.changes_draw(list, &f.text, &f.mono, theme, g, view, state, 1, {-1, -1}, 0)
	return g, testing.expect_value(t, status, render.Build_Status.Ok)
}

@(test)
text_selection_tints_its_bytes_and_a_line_selection_the_row :: proc(t: ^testing.T) {
	device, device_error := render.device_create(.Warp)
	if !testing.expect_value(t, device_error, render.Error.None) {return}
	defer render.device_destroy(device)
	f: Selection_Fixture
	view: ui.Changes_View
	if !select_make(t, &f, &view) {return}
	defer select_destroy(&f)
	cache: glyphs.Cache
	glyphs.init(&cache, f.fonts, device)
	defer glyphs.destroy(&cache)
	if !testing.expect(t, ui.text_init(&f.text, f.fonts, &cache, 13)) {return}
	f.mono = ui.text_mono(&f.text, f.text.family)
	state: ui.Changes_State
	defer ui.changes_state_destroy(&state)
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	theme: ui.Theme
	theme.text, theme.muted = {1, 1, 1, 1}, {1, 1, 1, 1}
	theme.selection = {0, 0.5, 1, 0.5}
	theme.accent = {0.5, 0, 1, 1}
	theme.error = {1, 0, 0, 1}

	// Bytes 2 to 7 of "delta epsilon zeta": one tint behind them, no wider than they are.
	view.selection = text_selection(2, 2, 2, 7)
	g, ok := draw_selection(t, &f, &list, &theme, &view, &state)
	if !ok {return}
	tints := rects_of(&list, theme.selection)
	defer delete(tints)
	if !testing.expect_value(t, len(tints), 1) {return}
	_, column, _ := ui.changes_line_code(g, &view, &state, &f.mono, 0, 2)
	text := f.lines[2].text
	begin, stop := ui.code_x_of(&f.mono, text, column.width, 2), ui.code_x_of(&f.mono, text, column.width, 7)
	testing.expect(t, near(tints[0].x, column.text_x + begin))
	testing.expect(t, near(tints[0].width, stop - begin))
	row := ui.changes_line_rect(g, &view, &state, 0, 2)
	testing.expect_value(t, tints[0].height, row.height)
	testing.expect_value(t, tints[0].y, row.y)

	// Across two lines: the first from its byte to its end, the last from its start to its byte.
	view.selection = text_selection(0, 2, 6, 5)
	g, ok = draw_selection(t, &f, &list, &theme, &view, &state)
	if !ok {return}
	spread := rects_of(&list, theme.selection)
	defer delete(spread)
	// Lines 0, 1 and 2 each have one run, whole between the ends.
	testing.expect_value(t, len(spread), 3)
	first_text := f.lines[0].text
	_, column, _ = ui.changes_line_code(g, &view, &state, &f.mono, 0, 0)
	start := ui.code_x_of(&f.mono, first_text, column.width, 6)
	testing.expect(t, near(spread[0].x, column.text_x + start))
	testing.expect(t, near(spread[0].width, ui.code_x_of(&f.mono, first_text, column.width, len(first_text)) - start))

	// A selection of lines tints each whole row and no bytes.
	view.selection = {file = 0, first = 1, last = 2, active = true}
	g, ok = draw_selection(t, &f, &list, &theme, &view, &state)
	if !ok {return}
	rows := rects_of(&list, theme.selection)
	defer delete(rows)
	testing.expect_value(t, len(rows), 2)
	for r in rows {testing.expect(t, near(r.width, g.diff.width - 16))}
}

@(test)
notes_mark_their_bytes_and_lines_and_strengthen_while_their_card_is_pointed_at :: proc(t: ^testing.T) {
	device, device_error := render.device_create(.Warp)
	if !testing.expect_value(t, device_error, render.Error.None) {return}
	defer render.device_destroy(device)
	f: Selection_Fixture
	view: ui.Changes_View
	if !select_make(t, &f, &view) {return}
	defer select_destroy(&f)
	cache: glyphs.Cache
	glyphs.init(&cache, f.fonts, device)
	defer glyphs.destroy(&cache)
	if !testing.expect(t, ui.text_init(&f.text, f.fonts, &cache, 13)) {return}
	f.mono = ui.text_mono(&f.text, f.text.family)
	state: ui.Changes_State
	defer ui.changes_state_destroy(&state)
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	theme: ui.Theme
	theme.text, theme.muted = {1, 1, 1, 1}, {1, 1, 1, 1}
	theme.accent = {0.5, 0, 1, 1}
	theme.error = {1, 0, 0, 1}

	// A label on bytes 6 to 13 of line 2, and the deletion of line 0 whole.
	f.notes = {
		{file = 0, first = 2, last = 2, partial = true, first_offset = 6, last_offset = 13, kind = .Label,
			label_name = "Good", label_colour = "#00ff00"},
		{file = 0, first = 0, last = 0, kind = .Delete},
	}
	view.comments = f.notes[:]
	g, ok := draw_selection(t, &f, &list, &theme, &view, &state)
	if !ok {return}
	_, column, _ := ui.changes_line_code(g, &view, &state, &f.mono, 0, 2)
	text := f.lines[2].text
	begin, stop := ui.code_x_of(&f.mono, text, column.width, 6), ui.code_x_of(&f.mono, text, column.width, 13)
	tint := rects_of(&list, {0, 1, 0, 0.16})
	defer delete(tint)
	if !testing.expect_value(t, len(tint), 1) {return}
	testing.expect(t, near(tint[0].x, column.text_x + begin) && near(tint[0].width, stop - begin))
	// The line under it is 1.5 DIP, rounded to 2 pixels, at the bottom of the row, in 80 % of the colour.
	line := rects_of(&list, {0, 1, 0, 0.8})
	defer delete(line)
	if !testing.expect_value(t, len(line), 1) {return}
	row := ui.changes_line_rect(g, &view, &state, 0, 2)
	testing.expect_value(t, line[0].height, f32(2))
	testing.expect_value(t, line[0].y, row.y + row.height - 2)
	testing.expect(t, near(line[0].x, tint[0].x) && near(line[0].width, tint[0].width))

	// The deleted line has a 2 DIP bar at its left in the error colour and a line through its text.
	deleted := ui.changes_line_rect(g, &view, &state, 0, 0)
	bars := rects_of(&list, theme.error)
	defer delete(bars)
	found := false
	for bar in bars {
		if near(bar.x, deleted.x) && near(bar.y, deleted.y) && near(bar.width, 2) {found = true}
	}
	testing.expect(t, found, "a whole-line note has a bar at the row's left")
	strikes := rects_of(&list, {1, 0, 0, 0.8})
	defer delete(strikes)
	if !testing.expect_value(t, len(strikes), 1) {return}
	_, whole, _ := ui.changes_line_code(g, &view, &state, &f.mono, 0, 0)
	testing.expect(t, near(strikes[0].x, whole.text_x))
	testing.expect(t, strikes[0].y > deleted.y && strikes[0].y < deleted.y + deleted.height)

	// Pointing at the label's card strengthens its tint; at the deletion's card tints its row.
	state.hover = {.Comment_Card, 0, 0}
	_, ok = draw_selection(t, &f, &list, &theme, &view, &state)
	if !ok {return}
	strong := rects_of(&list, {0, 1, 0, 0.3})
	defer delete(strong)
	testing.expect_value(t, len(strong), 1)
	testing.expect_value(t, rect_count(&list, {0, 1, 0, 0.16}), 0)
	state.hover = {.Comment_Card, 1, 0}
	_, ok = draw_selection(t, &f, &list, &theme, &view, &state)
	if !ok {return}
	row_tint := rects_of(&list, {1, 0, 0, 0.12})
	defer delete(row_tint)
	if !testing.expect_value(t, len(row_tint), 1) {return}
	testing.expect_value(t, row_tint[0].y, deleted.y)

	// The overview marks each card in its note's colour.
	testing.expect_value(t, ui.changes_note_color(theme, f.notes[0]), render.Color{0, 1, 0, 1})
	testing.expect_value(t, ui.changes_note_color(theme, f.notes[1]), theme.error)
	testing.expect_value(t, ui.changes_note_color(theme, {kind = .Comment}), theme.accent)
	cards := 0
	for tick in state.rows.ticks {
		if tick.kind == .Comment {
			testing.expect_value(t, int(tick.card), cards)
			cards += 1
		} else {
			testing.expect_value(t, tick.card, i32(-1))
		}
	}
	testing.expect_value(t, cards, 2)
}

@(test)
quick_labels_are_read_from_the_setting_text_in_order :: proc(t: ^testing.T) {
	testing.expect_value(t, ui.changes_label_count(SELECTION_LABELS), 3)
	testing.expect_value(t, ui.changes_label_count(""), 0)
	label, ok := ui.changes_label_at(SELECTION_LABELS, 1)
	testing.expect(t, ok)
	testing.expect_value(t, label.name, "Verify")
	testing.expect_value(t, label.colour, "#ff8800")
	testing.expect_value(t, label.instruction, "Check it")
	_, ok = ui.changes_label_at(SELECTION_LABELS, 3)
	testing.expect(t, !ok)
	_, ok = ui.changes_label_at(SELECTION_LABELS, -1)
	testing.expect(t, !ok)
}

// Side by side a context line is drawn in both halves; the tint, a note's marks and the toolbar belong to the
// half the selection was made in.
@(test)
a_selection_marks_and_anchors_only_the_half_it_was_made_in :: proc(t: ^testing.T) {
	device, device_error := render.device_create(.Warp)
	if !testing.expect_value(t, device_error, render.Error.None) {return}
	defer render.device_destroy(device)
	f: Selection_Fixture
	view: ui.Changes_View
	if !select_make(t, &f, &view) {return}
	defer select_destroy(&f)
	cache: glyphs.Cache
	glyphs.init(&cache, f.fonts, device)
	defer glyphs.destroy(&cache)
	if !testing.expect(t, ui.text_init(&f.text, f.fonts, &cache, 13)) {return}
	f.mono = ui.text_mono(&f.text, f.text.family)
	state: ui.Changes_State
	defer ui.changes_state_destroy(&state)
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	theme: ui.Theme
	theme.text, theme.muted = {1, 1, 1, 1}, {1, 1, 1, 1}
	theme.selection = {0, 0.5, 1, 0.5}
	theme.accent = {0.5, 0, 1, 1}
	view.side_by_side = true

	// A line selection of context line 0, made in each half, tints that half's cell and the toolbar centres over
	// it.
	for half in ([?]ui.Changes_Half{.Left, .Right}) {
		view.selection = {file = 0, first = 0, last = 0, active = true, half = half}
		g, ok := draw_selection(t, &f, &list, &theme, &view, &state)
		if !ok {return}
		middle := g.diff.x + g.diff.width / 2
		tints := rects_of(&list, theme.selection)
		defer delete(tints)
		if !testing.expect_value(t, len(tints), 1) {return}
		bar := g.selection_bar.bar
		if half == .Left {
			testing.expect(t, tints[0].x + tints[0].width <= middle + 1)
			testing.expect(t, bar.x + bar.width / 2 < middle)
		} else {
			testing.expect(t, tints[0].x >= middle)
			testing.expect(t, bar.x + bar.width / 2 > middle)
		}
	}
	// A selection that was made in neither, such as a hunk's, tints both cells.
	view.selection = {file = 0, first = 0, last = 0, active = true}
	_, ok := draw_selection(t, &f, &list, &theme, &view, &state)
	if !ok {return}
	testing.expect_value(t, rect_count(&list, theme.selection), 2)

	// A text selection in the right half tints its bytes there only.
	view.selection = text_selection(0, 0, 2, 5)
	view.selection.half = .Right
	g, drawn := draw_selection(t, &f, &list, &theme, &view, &state)
	if !drawn {return}
	text_tints := rects_of(&list, theme.selection)
	defer delete(text_tints)
	if !testing.expect_value(t, len(text_tints), 1) {return}
	testing.expect(t, text_tints[0].x >= g.diff.x + g.diff.width / 2)

	// A note keeps the half it was made in.
	f.notes[0] = {file = 0, first = 0, last = 0, partial = true, first_offset = 1, last_offset = 4, kind = .Label,
		label_name = "Good", label_colour = "#00ff00", half = .Left}
	view.comments = f.notes[:1]
	view.selection = {}
	g, drawn = draw_selection(t, &f, &list, &theme, &view, &state)
	if !drawn {return}
	marks := rects_of(&list, {0, 1, 0, 0.16})
	defer delete(marks)
	if !testing.expect_value(t, len(marks), 1) {return}
	testing.expect(t, marks[0].x + marks[0].width <= g.diff.x + g.diff.width / 2 + 1)
}

// The index of the layer that holds a rect of `rect`'s place drawn in `color`; -1 for none.
@(private = "file")
layer_of :: proc(list: ^render.Draw_List, rect: render.Rect, color: render.Color) -> int {
	for layer, i in list.layers {
		for r in list.rects[layer.rect_start:layer.rect_start + layer.rect_count] {
			if r.rect == rect && colour_near(r.color, color) {return i}
		}
	}
	return -1
}

// The pinned file header takes a layer of its own so the lines scrolled under it do not show through; the
// toolbar, which floats over the same lines, has to come after it, or the header would cover it.
@(test)
the_toolbar_draws_in_a_layer_above_the_pinned_file_header :: proc(t: ^testing.T) {
	device, device_error := render.device_create(.Warp)
	if !testing.expect_value(t, device_error, render.Error.None) {return}
	defer render.device_destroy(device)
	f: Selection_Fixture
	view: ui.Changes_View
	if !select_make(t, &f, &view) {return}
	defer select_destroy(&f)
	cache: glyphs.Cache
	glyphs.init(&cache, f.fonts, device)
	defer glyphs.destroy(&cache)
	if !testing.expect(t, ui.text_init(&f.text, f.fonts, &cache, 13)) {return}
	f.mono = ui.text_mono(&f.text, f.text.family)
	state: ui.Changes_State
	defer ui.changes_state_destroy(&state)
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	theme: ui.Theme
	theme.text, theme.muted = {1, 1, 1, 1}, {1, 1, 1, 1}
	theme.pane = {0.1, 0.2, 0.3, 1}
	theme.surface = {0.4, 0.3, 0.2, 1}

	// Scrolled past the file's header, which pins itself, with a selection lower down.
	state.diff_scroll = 40
	view.selection = {file = 0, first = 20, last = 21, active = true}
	g, ok := draw_selection(t, &f, &list, &theme, &view, &state)
	if !ok {return}
	sticky, header := ui.changes_sticky_header(&state, &view, g)
	if !testing.expect_value(t, sticky, 0) {return}
	bar := g.selection_bar.bar
	if !testing.expect(t, bar.width > 0) {return}
	pinned := layer_of(&list, header, theme.pane)
	floating := layer_of(&list, bar, theme.surface)
	testing.expect(t, pinned >= 0 && floating >= 0)
	testing.expect(t, floating > pinned, "the toolbar is drawn after the pinned header's layer")
	// The toolbar's own words are in its layer or a later one, never before the header's.
	for glyph in list.glyphs[list.layers[floating].glyph_start:][:list.layers[floating].glyph_count] {
		testing.expect(t, glyph.rect.y >= bar.y - 1)
	}
}
