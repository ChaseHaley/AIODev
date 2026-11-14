package ui_test

import "aio:font"
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
	for &row, i in f.rows {row = {title = "turn", detail = "now", files = i + 1, added = i, removed = 1}}
	view^ = {
		scope     = .Agent,
		turns     = f.rows[:],
		first     = -1,
		last      = -1,
		files     = f.files[:],
		collapsed = f.collapsed[:],
		revision  = 1,
	}
	return true
}

@(test)
changes_geometry_puts_the_turn_list_beside_or_above_the_diff :: proc(t: ^testing.T) {
	f: Changes_Fixture
	view: ui.Changes_View
	if !fixture_make(t, &f, &view) {return}
	defer font.system_destroy(f.fonts)

	wide := ui.changes_geometry({0, 0, 900, 600}, 1, &view, &f.text)
	testing.expect_value(t, wide.narrow, false)
	testing.expect_value(t, wide.toolbar, render.Rect{0, 0, 900, 28})
	testing.expect_value(t, wide.turns, render.Rect{0, 28, 264, 572})
	testing.expect_value(t, wide.diff, render.Rect{264, 28, 636, 572})
	testing.expect_value(t, wide.turn_row, f32(40))
	testing.expect(t, wide.scope.y >= wide.toolbar.y && wide.scope.height == 24)

	narrow := ui.changes_geometry({10, 20, 500, 400}, 1, &view, &f.text)
	testing.expect_value(t, narrow.narrow, true)
	testing.expect_value(t, narrow.turns, render.Rect{10, 48, 500, 112})
	testing.expect_value(t, narrow.diff, render.Rect{10, 160, 500, 260})

	view.scope = .Uncommitted
	view.turns = nil
	git := ui.changes_geometry({0, 0, 900, 600}, 1, &view, &f.text)
	testing.expect_value(t, git.turns.width, f32(0))
	testing.expect_value(t, git.diff, render.Rect{0, 28, 900, 572})

	view.scope = .Agent
	view.turns = f.rows[:]
	double := ui.changes_geometry({0, 0, 1800, 1200}, 2, &view, &f.text)
	testing.expect_value(t, double.turns.width, f32(528))
	testing.expect_value(t, double.turn_row, f32(80))
	testing.expect_value(t, double.toolbar.height, f32(56))
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
	testing.expect(t, offered.repository.x + offered.repository.width <= offered.hooks.x)

	tiny := ui.changes_geometry({0, 0, 120, 200}, 1, &view, &f.text)
	testing.expect(t, tiny.scope.x + tiny.scope.width <= tiny.hooks.x || tiny.scope.width == 0)
	testing.expect(t, tiny.hooks.x + tiny.hooks.width <= 120)
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

	// A notice sits in the diff area, so a turn list that still exists stays beside it.
	view.turns = f.rows[:]
	view.notice = .No_Changes
	kept := ui.changes_geometry({0, 0, 900, 600}, 1, &view, &f.text)
	testing.expect_value(t, kept.turns.width, f32(264))
	testing.expect(t, kept.notice.x >= kept.diff.x)
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

	ui.changes_layout(&state, &view, &f.mono, 1)
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
	ui.changes_layout(&state, &view, &f.mono, 1)
	testing.expect_value(t, state.rows.total, before + 32)

	// Expanding the second file grows the stream even without a new revision.
	view.omitted = 0
	f.collapsed[1] = false
	ui.changes_layout(&state, &view, &f.mono, 1)
	testing.expect_value(t, state.rows.total, 2 * (32 + body + 8))

	// A file without hunks, and a binary one, take one note row.
	f.files[0].hunks = nil
	f.files[1].binary = true
	view.revision += 1
	ui.changes_layout(&state, &view, &f.mono, 1)
	testing.expect_value(t, state.rows.total, 2 * (32 + 24 + 8))

	view.notice = .Not_Repository
	view.revision += 1
	ui.changes_layout(&state, &view, &f.mono, 1)
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

	ui.changes_layout(&state, &view, &f.mono, 1)
	small := state.rows.total
	ui.changes_layout(&state, &view, &f.mono, 2)
	testing.expect_value(t, state.rows.header, 64)
	testing.expect_value(t, state.rows.gap, 16)
	testing.expect(t, state.rows.total > small)
}

@(test)
changes_hit_finds_turns_headers_scope_and_notice_button :: proc(t: ^testing.T) {
	f: Changes_Fixture
	view: ui.Changes_View
	if !fixture_make(t, &f, &view) {return}
	defer font.system_destroy(f.fonts)
	state: ui.Changes_State
	defer ui.changes_state_destroy(&state)
	view.hooks_offer = true
	g := ui.changes_geometry({0, 0, 900, 600}, 1, &view, &f.text)
	ui.changes_layout(&state, &view, &f.mono, 1)
	tops := state.rows.tops

	third := ui.changes_hit(g, &view, &state, g.turns.x + 10, g.turns.y + 2 * 40 + 20)
	testing.expect_value(t, third, ui.Changes_Hit{.Turn, 2})
	state.turn_scroll = 40
	scrolled := ui.changes_hit(g, &view, &state, g.turns.x + 10, g.turns.y + 2 * 40 + 20)
	testing.expect_value(t, scrolled, ui.Changes_Hit{.Turn, 3})
	state.turn_scroll = 0
	below := ui.changes_hit(g, &view, &state, g.turns.x + 10, g.turns.y + 300)
	testing.expect_value(t, below, ui.Changes_Hit{.Turn_List, 0})

	first_header := ui.changes_hit(g, &view, &state, g.diff.x + 50, g.diff.y + 5)
	testing.expect_value(t, first_header, ui.Changes_Hit{.File_Header, 0})
	body := ui.changes_hit(g, &view, &state, g.diff.x + 50, g.diff.y + 40)
	testing.expect_value(t, body, ui.Changes_Hit{.Diff, 0})
	second := ui.changes_hit(g, &view, &state, g.diff.x + 50, g.diff.y + f32(tops[1]) + 4)
	testing.expect_value(t, second, ui.Changes_Hit{.File_Header, 1})
	past := ui.changes_hit(g, &view, &state, g.diff.x + 50, g.diff.y + f32(tops[2]) + 20)
	testing.expect_value(t, past, ui.Changes_Hit{.Diff, -1})
	state.diff_scroll = 10
	shifted := ui.changes_hit(g, &view, &state, g.diff.x + 50, g.diff.y + 5)
	testing.expect_value(t, shifted, ui.Changes_Hit{.File_Header, 0})
	state.diff_scroll = tops[1]
	moved := ui.changes_hit(g, &view, &state, g.diff.x + 50, g.diff.y + 5)
	testing.expect_value(t, moved, ui.Changes_Hit{.File_Header, 1})
	state.diff_scroll = 0

	scope := ui.changes_hit(g, &view, &state, g.scope.x + g.scope.width / 2, g.scope.y + 5)
	testing.expect_value(t, scope, ui.Changes_Hit{.Scope, 0})
	hooks := ui.changes_hit(g, &view, &state, g.hooks.x + 3, g.hooks.y + 3)
	testing.expect_value(t, hooks, ui.Changes_Hit{.Hooks, 0})
	gap := ui.changes_hit(g, &view, &state, g.repository.x + 1, g.repository.y + 3)
	testing.expect_value(t, gap, ui.Changes_Hit{})
	outside := ui.changes_hit(g, &view, &state, -5, -5)
	testing.expect_value(t, outside, ui.Changes_Hit{})

	view.turns, view.files = nil, nil
	view.notice = .Recording_Off
	view.revision += 1
	g = ui.changes_geometry({0, 0, 900, 600}, 1, &view, &f.text)
	ui.changes_layout(&state, &view, &f.mono, 1)
	button := g.notice_button
	pressed := ui.changes_hit(g, &view, &state, button.x + button.width / 2, button.y + button.height / 2)
	testing.expect_value(t, pressed, ui.Changes_Hit{.Notice_Button, 0})
	elsewhere := ui.changes_hit(g, &view, &state, g.diff.x + 5, g.diff.y + 5)
	testing.expect_value(t, elsewhere, ui.Changes_Hit{})
}

@(test)
changes_scroll_clamps_the_diff_and_the_turn_list :: proc(t: ^testing.T) {
	f: Changes_Fixture
	view: ui.Changes_View
	if !fixture_make(t, &f, &view) {return}
	defer font.system_destroy(f.fonts)
	state: ui.Changes_State
	defer ui.changes_state_destroy(&state)
	g := ui.changes_geometry({0, 0, 900, 100}, 1, &view, &f.text)
	ui.changes_layout(&state, &view, &f.mono, 1)
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
	state.diff_scroll = 0

	turn_limit := 5 * 40 - int(g.turns.height)
	if !testing.expect(t, turn_limit > 0) {return}
	testing.expect(t, ui.changes_scroll_turns(&state, g, &view, 10_000))
	testing.expect_value(t, state.turn_scroll, turn_limit)
	testing.expect(t, !ui.changes_scroll_turns(&state, g, &view, 1))
	testing.expect(t, ui.changes_scroll_turns(&state, g, &view, -10_000))
	testing.expect_value(t, state.turn_scroll, 0)
	testing.expect(t, !ui.changes_scroll_turns(&state, g, &view, -1))
}

@(test)
changes_turn_rect_and_reveal_follow_the_turn_scroll :: proc(t: ^testing.T) {
	f: Changes_Fixture
	view: ui.Changes_View
	if !fixture_make(t, &f, &view) {return}
	defer font.system_destroy(f.fonts)
	state: ui.Changes_State
	defer ui.changes_state_destroy(&state)
	g := ui.changes_geometry({0, 0, 900, 100}, 1, &view, &f.text)

	testing.expect_value(t, ui.changes_turn_rect(g, &state, 1), render.Rect{0, 28 + 40, 264, 32})
	testing.expect_value(t, ui.changes_turn_rect(g, &state, 4), render.Rect{})
	testing.expect_value(t, ui.changes_turn_rect(g, &state, -1), render.Rect{})

	testing.expect(t, ui.changes_turn_reveal(&state, g, &view, 4))
	testing.expect_value(t, state.turn_scroll, 5 * 40 - int(g.turns.height))
	testing.expect(t, !ui.changes_turn_reveal(&state, g, &view, 4))
	testing.expect_value(t, ui.changes_turn_rect(g, &state, 4).height, f32(40))
	testing.expect(t, ui.changes_turn_reveal(&state, g, &view, 0))
	testing.expect_value(t, state.turn_scroll, 0)
	testing.expect(t, !ui.changes_turn_reveal(&state, g, &view, 9))
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
