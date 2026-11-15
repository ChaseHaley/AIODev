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
	testing.expect(t, abs(offered.hooks.x + offered.hooks.width - 892) < 0.01)
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

	// A pane with room for two bars.
	view.first, view.last = 0, 0
	narrow: ui.Changes_Geometry
	for width := f32(700); width > 250; width -= 1 {
		narrow = ui.changes_geometry({0, 0, width, 600}, 1, &view, &f.text)
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
	testing.expect_value(t, state.strip_offset, 3)
	testing.expect(t, ui.changes_strip_bar_rect(narrow, &state, &view, 0).width > 0)
	if !draw_into(t, &f, &list, &view, &state, wide) {return}
	testing.expect_value(t, state.strip_offset, 0)
	// Narrowing again keeps the newest bar, which is selected, in view.
	if !draw_into(t, &f, &list, &view, &state, narrow) {return}
	testing.expect_value(t, state.strip_offset, 3)
	testing.expect(t, ui.changes_strip_bar_rect(narrow, &state, &view, 0).width > 0)

	// The wheel's offset stays while nothing changes.
	testing.expect(t, ui.changes_scroll_strip(&state, narrow, &view, -2))
	if !draw_into(t, &f, &list, &view, &state, narrow) {return}
	testing.expect_value(t, state.strip_offset, 1)

	// A turn that arrived while the pane was hidden is revealed when it is drawn.
	view.turns = f.rows[1:]
	if !draw_into(t, &f, &list, &view, &state, narrow) {return}
	testing.expect_value(t, state.strip_offset, 2)
	testing.expect(t, ui.changes_strip_bar_rect(narrow, &state, &view, 0).width > 0)
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
