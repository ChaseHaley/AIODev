package views_test

import "cosmos:font"
import "cosmos:glyphs"
import "cosmos:render"
import "aio:views"
import "core:testing"
import "cosmos:ui"

@(private = "file")
middle :: proc(r: render.Rect) -> (x, y: f32) {return r.x + r.width / 2, r.y + r.height / 2}

@(test)
changes_row_has_the_summary_at_the_left_and_its_buttons_at_the_right :: proc(t: ^testing.T) {
	f: Changes_Fixture
	view: views.Changes_View
	if !fixture_make(t, &f, &view) {return}
	defer font.system_destroy(f.fonts)
	state: views.Changes_State
	defer views.changes_state_destroy(&state)

	g := views.changes_geometry({0, 0, 900, 600}, 1, &view, &f.text)
	views.changes_layout(&state, &view, &f.text, &f.mono, g.diff.width, 1)
	// A wide pane takes no step: the summary and all five buttons show.
	testing.expect_value(t, g.row_steps, 0)
	testing.expect_value(t, g.tools_button, render.Rect{})
	// A 32 tall row across the whole pane at its top, the diff under it.
	testing.expect_value(t, g.row, render.Rect{0, 0, 900, 32})
	testing.expect_value(t, g.diff.y, f32(32))
	// The summary is a 24 tall ghost button 4 from the left edge, not centred.
	testing.expect_value(t, g.summary.x, f32(4))
	testing.expect_value(t, g.summary.y, f32(4))
	testing.expect_value(t, g.summary.height, f32(24))
	testing.expect(t, g.summary.x + g.summary.width < 450)
	// At the right end: the files button 4 from the edge, 24 tall, with the 16 DIP icon, a gap and the count
	// in it; 8 before it wrap, select lines, filter, fold and layout 22 wide and 2 apart.
	testing.expect_value(t, g.files_button.y, f32(4))
	testing.expect_value(t, g.files_button.height, f32(24))
	testing.expect_value(t, g.files_button.x + g.files_button.width, f32(896))
	testing.expect(t, g.files_button.width > 2 * 8 + 16 + 4)
	testing.expect_value(t, g.wrap_button, render.Rect{g.files_button.x - 8 - 22, 5, 22, 22})
	testing.expect_value(t, g.select_lines_button, render.Rect{g.wrap_button.x - 2 - 22, 5, 22, 22})
	testing.expect_value(t, g.filter_button, render.Rect{g.select_lines_button.x - 2 - 22, 5, 22, 22})
	testing.expect_value(t, g.fold_button, render.Rect{g.filter_button.x - 2 - 22, 5, 22, 22})
	testing.expect_value(t, g.layout_button, render.Rect{g.fold_button.x - 2 - 22, 5, 22, 22})
	// The room between the summary and the buttons stays empty.
	testing.expect(t, g.layout_button.x - (g.summary.x + g.summary.width) > 100)

	// Each part answers as its own hit.
	x, y := middle(g.summary)
	testing.expect_value(t, views.changes_hit(g, &view, &state, x, y), views.Changes_Hit{.Summary, 0, 0})
	x, y = middle(g.layout_button)
	testing.expect_value(t, views.changes_hit(g, &view, &state, x, y), views.Changes_Hit{.Layout_Button, 0, 0})
	x, y = middle(g.fold_button)
	testing.expect_value(t, views.changes_hit(g, &view, &state, x, y), views.Changes_Hit{.Fold_Button, 0, 0})
	x, y = middle(g.filter_button)
	testing.expect_value(t, views.changes_hit(g, &view, &state, x, y), views.Changes_Hit{.Filter_Button, 0, 0})
	x, y = middle(g.select_lines_button)
	testing.expect_value(t, views.changes_hit(g, &view, &state, x, y), views.Changes_Hit{.Select_Lines_Button, 0, 0})
	x, y = middle(g.wrap_button)
	testing.expect_value(t, views.changes_hit(g, &view, &state, x, y), views.Changes_Hit{.Wrap_Button, 0, 0})
	x, y = middle(g.files_button)
	testing.expect_value(t, views.changes_hit(g, &view, &state, x, y), views.Changes_Hit{.Files_Button, 0, 0})
	// Folding needs files.
	view.files = nil
	view.revision += 1
	views.changes_layout(&state, &view, &f.text, &f.mono, g.diff.width, 1)
	x, y = middle(g.fold_button)
	testing.expect_value(t, views.changes_hit(g, &view, &state, x, y), views.Changes_Hit{})
	x, y = middle(g.files_button)
	testing.expect_value(t, views.changes_hit(g, &view, &state, x, y), views.Changes_Hit{})

	// The icon swap and the view do not move anything; a git scope keeps the circles in the same order.
	view.any_expanded, view.side_by_side = true, true
	same := views.changes_geometry({0, 0, 900, 600}, 1, &view, &f.text)
	testing.expect_value(t, same.fold_button, g.fold_button)
	view.scope, view.turns = .Staged, nil
	git := views.changes_geometry({0, 0, 900, 600}, 1, &view, &f.text)
	testing.expect_value(t, git.row_steps, 0)
	testing.expect(t, git.layout_button.x < git.fold_button.x && git.fold_button.x < git.filter_button.x)
	testing.expect(t, git.filter_button.x < git.select_lines_button.x)
	testing.expect(t, git.select_lines_button.x < git.wrap_button.x && git.wrap_button.x < git.files_button.x)

	// At twice the scale every DIP doubles.
	view.scope, view.turns = .Agent, f.rows[:]
	double := views.changes_geometry({0, 0, 1800, 1200}, 2, &view, &f.text)
	testing.expect_value(t, double.row.height, f32(64))
	testing.expect_value(t, double.layout_button.width, f32(44))
	testing.expect_value(t, double.fold_button.x, double.layout_button.x + 48)
}

// The x of the leftmost button of the row's right end.
@(private = "file")
buttons_left :: proc(g: views.Changes_Geometry) -> f32 {
	return g.layout_button.width > 0 ? g.layout_button.x : g.tools_button.x
}

// Sweeps the pane from wide to narrow and checks the collapse ladder: no step while the summary fits with
// 4 DIP to spare before the buttons, each step taken only when the one before no longer fits, the three
// buttons becoming one ⋯ at the first.
@(private = "file")
ladder_check :: proc(t: ^testing.T, f: ^Changes_Fixture, view: ^views.Changes_View, skipped: int) {
	state: views.Changes_State
	defer views.changes_state_destroy(&state)
	steps := 0
	previous: views.Changes_Geometry
	wide_files := views.changes_geometry({0, 0, 1400, 600}, 1, view, &f.text).files_button
	reached: [6]bool
	for width := f32(1400); width >= 100; width -= 1 {
		g := views.changes_geometry({0, 0, width, 600}, 1, view, &f.text)
		testing.expect_value(t, g.row.width, width)
		testing.expect(t, g.row_steps >= steps)
		testing.expect(t, g.row_steps != skipped)
		reached[g.row_steps] = true
		// The summary never runs into the buttons.
		testing.expect(t, g.summary.x + g.summary.width <= buttons_left(g))
		if g.row_steps > steps {
			// It did not fit at this width, and did one pixel wider, with exactly the 4 DIP gap.
			testing.expect_value(t, buttons_left(previous) - (previous.summary.x + previous.summary.width), f32(4))
			testing.expect(t, width < 1400)
		}
		if g.row_steps == 0 {
			testing.expect(t, g.layout_button.width > 0 && g.fold_button.width > 0 && g.filter_button.width > 0)
			testing.expect(t, g.select_lines_button.width > 0 && g.wrap_button.width > 0)
			testing.expect_value(t, g.tools_button, render.Rect{})
		} else {
			testing.expect_value(t, g.layout_button, render.Rect{})
			testing.expect_value(t, g.fold_button, render.Rect{})
			testing.expect_value(t, g.filter_button, render.Rect{})
			testing.expect_value(t, g.select_lines_button, render.Rect{})
			testing.expect_value(t, g.wrap_button, render.Rect{})
			testing.expect(t, g.tools_button.width > 0)
		}
		testing.expect(t, g.files_button.width > 0)
		// The files button keeps its icon and number to the last, and loses the word at the second step.
		if g.row_steps >= 2 {testing.expect(t, g.files_button.width < wide_files.width)}
		steps, previous = g.row_steps, g
	}
	testing.expect(t, reached[0] && reached[1] && reached[2] && reached[3])
	testing.expect(t, reached[5])
	testing.expect_value(t, reached[4], skipped != 4)
	// Natural widths only fall: each step gave something up.
	wide := views.changes_geometry({0, 0, 1400, 600}, 1, view, &f.text)
	narrow := views.changes_geometry({0, 0, 300, 600}, 1, view, &f.text)
	testing.expect(t, narrow.summary.width < wide.summary.width)
}

@(test)
changes_rail_collapses_one_step_at_a_time_and_only_when_out_of_room :: proc(t: ^testing.T) {
	f: Changes_Fixture
	view: views.Changes_View
	if !fixture_make(t, &f, &view) {return}
	defer font.system_destroy(f.fonts)
	view.source_label = "Claude Code"
	view.shown_added, view.shown_removed = 12, 3
	view.first, view.last = 1, 3
	ladder_check(t, &f, &view, -1)
}

@(test)
changes_rail_skips_the_agent_name_step_in_git_scopes :: proc(t: ^testing.T) {
	f: Changes_Fixture
	view: views.Changes_View
	if !fixture_make(t, &f, &view) {return}
	defer font.system_destroy(f.fonts)
	view.scope, view.turns, view.first, view.last = .Uncommitted, nil, -1, -1
	view.source_label = "Uncommitted changes"
	view.shown_added, view.shown_removed = 12, 3
	// The scope's name takes the range's place, and there is no agent name to give up: step 4 never shows.
	ladder_check(t, &f, &view, 4)
}

@(test)
changes_range_label_shortens_for_a_row_short_of_room :: proc(t: ^testing.T) {
	f: Changes_Fixture
	view: views.Changes_View
	if !fixture_make(t, &f, &view) {return}
	defer font.system_destroy(f.fonts)
	buf: [64]u8

	testing.expect_value(t, views.changes_range_label_short(&view, buf[:]), "No turn selected")
	view.first, view.last = 0, 0
	testing.expect_value(t, views.changes_range_label_short(&view, buf[:]), "T5")
	view.first, view.last = 1, 3
	testing.expect_value(t, views.changes_range_label_short(&view, buf[:]), "T2–4")
	view.turns = nil
	testing.expect_value(t, views.changes_range_label_short(&view, buf[:]), "No turns")
	view.turns = f.rows[:]

	// The title under the strip: the one turn's, or the run's count and its ends.
	view.first, view.last = 2, 2
	testing.expect_value(t, views.changes_range_title(&view, buf[:]), "turn")
	view.first, view.last = 1, 3
	testing.expect_value(t, views.changes_range_title(&view, buf[:]), "3 turns · now–now")
	f.rows[3].detail = ""
	testing.expect_value(t, views.changes_range_title(&view, buf[:]), "3 turns")
	view.first, view.last = -1, -1
	testing.expect_value(t, views.changes_range_title(&view, buf[:]), "")
}

@(test)
changes_tools_menu_hangs_under_the_collapsed_button_and_answers_first :: proc(t: ^testing.T) {
	f: Changes_Fixture
	view: views.Changes_View
	if !fixture_make(t, &f, &view) {return}
	defer font.system_destroy(f.fonts)
	state: views.Changes_State
	defer views.changes_state_destroy(&state)

	// The wide row has no menu.
	wide := views.changes_geometry({0, 0, 900, 600}, 1, &view, &f.text)
	testing.expect_value(t, wide.tools_menu, render.Rect{})

	g := views.changes_geometry({0, 0, 260, 600}, 1, &view, &f.text)
	if !testing.expect(t, g.row_steps >= 1 && g.tools_button.width > 0) {return}
	views.changes_layout(&state, &view, &f.text, &f.mono, g.diff.width, 1)
	testing.expect_value(t, g.tools_button.width, f32(22))
	testing.expect_value(t, g.files_button.x, g.tools_button.x + 22 + 8)
	// Five 32 DIP rows under the button, right-aligned to it and inside the pane.
	menu := g.tools_menu
	testing.expect_value(t, menu.y, g.row.y + g.row.height + 4)
	testing.expect_value(t, menu.height, f32(5 * 32 + 8))
	testing.expect(t, menu.x >= 8 && menu.x + menu.width <= 260 - 8)
	for row, i in g.tools_rows {
		testing.expect_value(t, row.height, f32(32))
		testing.expect_value(t, row.y, menu.y + 4 + f32(i) * 32)
		testing.expect(t, row.x >= menu.x && row.x + row.width <= menu.x + menu.width)
	}

	// Closed, the menu answers nothing; open, its rows answer in order and its padding answers itself.
	x, y := middle(g.tools_rows[2])
	testing.expect(t, views.changes_hit(g, &view, &state, x, y).part != .Tools_Row)
	state.tools_open = true
	testing.expect_value(t, views.changes_hit(g, &view, &state, x, y), views.Changes_Hit{.Tools_Row, 2, 0})
	x, y = middle(g.tools_rows[0])
	testing.expect_value(t, views.changes_hit(g, &view, &state, x, y), views.Changes_Hit{.Tools_Row, 0, 0})
	wrap_row := int(views.Row_Button.Wrap)
	x, y = middle(g.tools_rows[wrap_row])
	testing.expect_value(t, views.changes_hit(g, &view, &state, x, y), views.Changes_Hit{.Tools_Row, wrap_row, 0})
	padding := views.changes_hit(g, &view, &state, menu.x + 1, menu.y + 1)
	testing.expect_value(t, padding, views.Changes_Hit{.Tools_Row, -1, 0})
	// The fold row is disabled without files.
	view.files = nil
	view.revision += 1
	views.changes_layout(&state, &view, &f.text, &f.mono, g.diff.width, 1)
	x, y = middle(g.tools_rows[1])
	testing.expect_value(t, views.changes_hit(g, &view, &state, x, y), views.Changes_Hit{})
	// The button itself is a hit while the menu is closed or open.
	x, y = middle(g.tools_button)
	testing.expect_value(t, views.changes_hit(g, &view, &state, x, y), views.Changes_Hit{.Tools_Button, 0, 0})
	// The filter popover hangs under ⋯ too, and answers before the menu.
	testing.expect(t, g.filter_popover.width > 0)
	testing.expect_value(t, g.filter_popover.y, menu.y)
}

@(test)
changes_panel_lists_the_source_and_worktree_chips :: proc(t: ^testing.T) {
	f: Changes_Fixture
	view: views.Changes_View
	if !fixture_make(t, &f, &view) {return}
	defer font.system_destroy(f.fonts)
	state: views.Changes_State
	defer views.changes_state_destroy(&state)
	sources := [6]string {
		"Claude Code",
		"Codex",
		"All agents",
		"Uncommitted changes",
		"Staged changes",
		"Unstaged changes",
	}
	view.sources, view.source_current = sources[:], 1

	g := views.changes_geometry({0, 0, 900, 600}, 1, &view, &f.text)
	views.changes_layout(&state, &view, &f.text, &f.mono, g.diff.width, 1)
	if !testing.expect_value(t, len(g.source_chips), 6) {return}
	testing.expect_value(t, len(g.worktree_chips), 0)
	inner := render.Rect{g.panel.x + 12, g.panel.y, g.panel.width - 24, g.panel.height}
	for chip, i in g.source_chips {
		testing.expect_value(t, chip.height, f32(24))
		testing.expect(t, chip.x >= inner.x && chip.x + chip.width <= inner.x + inner.width)
		testing.expect(t, chip.y >= g.source_caption.y + g.source_caption.height)
		testing.expect(t, chip.y + chip.height <= g.panel.y + g.panel.height)
		if i > 0 {
			before := g.source_chips[i - 1]
			// In order, left to right and then down, never overlapping.
			beside := chip.y == before.y && chip.x >= before.x + before.width + 4
			below := chip.y >= before.y + before.height + 4 && chip.x == inner.x
			testing.expect(t, beside || below)
		}
	}
	// The first three fit on one row of a wide panel.
	testing.expect_value(t, g.source_chips[2].y, g.source_chips[0].y)

	// Closed, the chips are not there to hit; open, each answers with its index.
	x, y := middle(g.source_chips[3])
	testing.expect(t, views.changes_hit(g, &view, &state, x, y).part != .Source_Chip)
	state.panel_open = true
	testing.expect_value(t, views.changes_hit(g, &view, &state, x, y), views.Changes_Hit{.Source_Chip, 3, 0})

	// A narrow panel wraps them onto more rows, each still inside it.
	narrow := views.changes_geometry({0, 0, 300, 600}, 1, &view, &f.text)
	testing.expect_value(t, narrow.panel.width, f32(284))
	testing.expect(t, narrow.source_chips[5].y > narrow.source_chips[0].y)
	for chip in narrow.source_chips {
		testing.expect(t, chip.x >= narrow.panel.x && chip.x + chip.width <= narrow.panel.x + narrow.panel.width)
	}
	testing.expect(t, narrow.step_back.y > narrow.source_chips[5].y + 24)

	// A git scope lists its worktrees instead of turns, and the strip goes.
	labels := [3]string{"Follow the agent", "odin-wt-a", "odin-wt-b"}
	view.scope, view.turns, view.first, view.last = .Uncommitted, nil, -1, -1
	view.worktree_labels, view.worktree_current = labels[:], 1
	git := views.changes_geometry({0, 0, 900, 600}, 1, &view, &f.text)
	if !testing.expect_value(t, len(git.worktree_chips), 3) {return}
	testing.expect(t, git.worktree_caption.y >= git.source_chips[0].y + 24)
	testing.expect(t, git.worktree_chips[0].y >= git.worktree_caption.y + git.worktree_caption.height)
	testing.expect_value(t, git.turns_caption, render.Rect{})
	testing.expect_value(t, git.strip, render.Rect{})
	x, y = middle(git.worktree_chips[2])
	testing.expect_value(t, views.changes_hit(git, &view, &state, x, y), views.Changes_Hit{.Worktree_Chip, 2, 0})
	// A git scope with no other worktrees has no Worktree section.
	view.worktree_labels = nil
	lone := views.changes_geometry({0, 0, 900, 600}, 1, &view, &f.text)
	testing.expect_value(t, len(lone.worktree_chips), 0)
	testing.expect_value(t, lone.worktree_caption, render.Rect{})

	// The panel never leaves a short or narrow pane.
	short := views.changes_geometry({0, 0, 900, 200}, 1, &view, &f.text)
	testing.expect(t, short.panel.y + short.panel.height <= 200 - 8)
	sliver := views.changes_geometry({0, 0, 100, 400}, 1, &view, &f.text)
	testing.expect(t, sliver.panel.x >= 8 && sliver.panel.x + sliver.panel.width <= 100 - 8)
}

// Expands both fixture files, so the stream is as tall as it gets.
@(private = "file")
expand_files :: proc(f: ^Changes_Fixture, view: ^views.Changes_View) {
	f.collapsed = {false, false}
	view.revision += 1
}

@(test)
changes_overview_is_the_shared_scrollbar_over_the_map :: proc(t: ^testing.T) {
	f: Changes_Fixture
	view: views.Changes_View
	if !fixture_make(t, &f, &view) {return}
	defer font.system_destroy(f.fonts)
	state: views.Changes_State
	defer views.changes_state_destroy(&state)
	expand_files(&f, &view)

	// A pane that fits the stream has nothing to scroll, so no thumb.
	roomy := views.changes_geometry({0, 0, 900, 900}, 1, &view, &f.text)
	views.changes_layout(&state, &view, &f.text, &f.mono, roomy.diff.width, 1)
	testing.expect_value(t, roomy.overview.width, f32(12))
	testing.expect_value(t, views.changes_overview_thumb(&state, roomy), render.Rect{})

	g := views.changes_geometry({0, 0, 900, 150}, 1, &view, &f.text)
	views.changes_layout(&state, &view, &f.text, &f.mono, g.diff.width, 1)
	lane := g.overview
	testing.expect_value(t, lane, render.Rect{888, 32, 12, 118})
	total, visible := state.rows.total, int(g.diff.height)
	limit := total - visible
	if !testing.expect(t, limit > 0) {return}

	// The lane is the track and the thumb is the visible part: at least as tall as the shared bar's
	// smallest thumb, flush with the lane's ends at the stream's ends, and inside its width.
	bar, shown := views.changes_overview_bar(&state, g)
	if !testing.expect(t, shown) {return}
	testing.expect_value(t, bar.track, lane)
	thumb := bar.thumb
	testing.expect(t, thumb.height >= 24)
	testing.expect(t, thumb.x > lane.x && thumb.x + thumb.width < lane.x + lane.width)
	testing.expect_value(t, thumb.y, lane.y)
	state.diff_scroll = limit
	thumb = views.changes_overview_thumb(&state, g)
	testing.expect(t, abs(thumb.y + thumb.height - (lane.y + lane.height)) < 0.01)
	state.diff_scroll = 0

	// The lane answers with its own part, over what lies under it.
	x, y := middle(lane)
	testing.expect_value(t, views.changes_hit(g, &view, &state, x, y), views.Changes_Hit{.Overview, 0, 0})
	testing.expect(t, views.changes_hit(g, &view, &state, lane.x - 2, y).part != .Overview)

	// Like every scrollbar: rest away from the pointer, hover under it, held while dragged.
	testing.expect_value(t, views.changes_overview_state(&state, g, {lane.x - 20, y}), ui.Scrollbar_State.Collapsed)
	testing.expect_value(t, views.changes_overview_state(&state, g, {x, y}), ui.Scrollbar_State.Hovered)

	// A press on the track pages one view toward the pointer and holds nothing.
	state.diff_scroll = views.changes_overview_press(&state, g, lane.y + lane.height - 1)
	testing.expect_value(t, state.diff_scroll, min(visible, limit))
	testing.expect(t, !state.overview_drag.active)
	state.diff_scroll = limit
	testing.expect_value(t, views.changes_overview_press(&state, g, lane.y + 1), max(0, limit - visible))
	testing.expect(t, !state.overview_drag.active)

	// A press on the thumb leaves the view and keeps where it was grabbed; a drag moves by the pointer's
	// distance in the lane, and the ends of the lane reach the ends of the stream.
	state.diff_scroll = limit / 2
	thumb = views.changes_overview_thumb(&state, g)
	grab := thumb.y + 3
	testing.expect_value(t, views.changes_overview_press(&state, g, grab), limit / 2)
	testing.expect(t, state.overview_drag.active)
	testing.expect_value(t, state.overview_drag.grab, f32(3))
	testing.expect_value(t, views.changes_overview_state(&state, g, {lane.x - 20, y}), ui.Scrollbar_State.Active)
	moved := views.changes_overview_drag(&state, g, grab + 10)
	per_dip := f32(limit) / (lane.height - thumb.height)
	testing.expect(t, abs(f32(moved - limit / 2) - 10 * per_dip) <= 1)
	testing.expect_value(t, views.changes_overview_drag(&state, g, lane.y - 500), 0)
	testing.expect_value(t, views.changes_overview_drag(&state, g, lane.y + lane.height + 500), limit)

	// Under a notice the stream is not a diff, so there is no lane.
	view.notice = .No_Changes
	n := views.changes_geometry({0, 0, 900, 150}, 1, &view, &f.text)
	testing.expect_value(t, n.overview, render.Rect{})
	testing.expect_value(t, n.diff.width, f32(900))
}

@(test)
changes_layout_builds_the_overview_ticks_once_per_layout :: proc(t: ^testing.T) {
	f: Changes_Fixture
	view: views.Changes_View
	if !fixture_make(t, &f, &view) {return}
	defer font.system_destroy(f.fonts)
	state: views.Changes_State
	defer views.changes_state_destroy(&state)

	// File 0 is expanded and file 1 collapsed: a removed and an added row of file 0 and nothing of file 1.
	views.changes_layout(&state, &view, &f.text, &f.mono, 900, 1)
	rows := &state.rows
	if !testing.expect_value(t, len(rows.ticks), 2) {return}
	first := rows.tops[0] + rows.header + rows.hunk
	testing.expect_value(t, rows.ticks[0], views.Changes_Tick{i32(first + rows.line), i32(rows.line), .Removed, -1})
	testing.expect_value(t, rows.ticks[1], views.Changes_Tick{i32(first + 2 * rows.line), i32(rows.line), .Added, -1})

	// Unfolding adds the second file's two runs further down.
	f.collapsed[1] = false
	views.changes_layout(&state, &view, &f.text, &f.mono, 900, 1)
	if !testing.expect_value(t, len(rows.ticks), 4) {return}
	second := rows.tops[1] + rows.header + rows.hunk
	testing.expect_value(t, rows.ticks[2].y, i32(second + rows.line))
	testing.expect_value(t, rows.ticks[3].kind, views.Changes_Tick_Kind.Added)

	// Side by side, the removed and added line share one row, so their ticks share it.
	f.collapsed[1] = true
	view.side_by_side = true
	views.changes_layout(&state, &view, &f.text, &f.mono, 900, 1)
	if !testing.expect_value(t, len(rows.ticks), 2) {return}
	testing.expect_value(t, rows.ticks[0].y, rows.ticks[1].y)
	testing.expect(t, rows.ticks[0].kind != rows.ticks[1].kind)
	view.side_by_side = false

	// A comment card is a tick of its own height, and pushes the rows under it down.
	comments := [1]views.Changes_Comment_View{{file = 0, first = 1, last = 1, text = "Check this"}}
	view.comments = comments[:]
	views.changes_layout(&state, &view, &f.text, &f.mono, 900, 1)
	if !testing.expect_value(t, len(rows.ticks), 3) {return}
	card := rows.ticks[2]
	testing.expect_value(t, card.kind, views.Changes_Tick_Kind.Comment)
	testing.expect_value(t, int(card.height), rows.cards[0])
	// Under the row of its line, after the room its notch needs.
	testing.expect_value(t, int(card.y), first + 2 * rows.line + 6)
	testing.expect(t, int(rows.ticks[1].y) >= int(card.y) + int(card.height))
	view.comments = nil

	// A notice shows no diff, so there is nothing to mark.
	view.notice = .No_Changes
	views.changes_layout(&state, &view, &f.text, &f.mono, 900, 1)
	testing.expect_value(t, len(rows.ticks), 0)
}

@(test)
changes_draw_paints_the_row_the_panel_the_menu_and_the_overview :: proc(t: ^testing.T) {
	device, device_error := render.device_create(.Warp)
	if !testing.expect_value(t, device_error, render.Error.None) {return}
	defer render.device_destroy(device)
	f: Changes_Fixture
	view: views.Changes_View
	if !fixture_make(t, &f, &view) {return}
	defer font.system_destroy(f.fonts)
	cache: glyphs.Cache
	glyphs.init(&cache, f.fonts, device)
	defer glyphs.destroy(&cache)
	if !testing.expect(t, ui.text_init(&f.text, f.fonts, &cache, 13)) {return}
	f.mono = ui.text_mono(&f.text, f.text.family)
	state: views.Changes_State
	defer views.changes_state_destroy(&state)
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	view.source_label = "A very long agent name that cannot possibly fit in a narrow row at all"
	view.shown_added, view.shown_removed = 120, 30
	view.first, view.last = 1, 3
	sources := [3]string{"Claude Code", "All agents", "Uncommitted changes"}
	view.sources, view.source_current = sources[:], 0
	expand_files(&f, &view)

	// The row's text stays inside the summary and the files button at every width, clipped when nothing else is left to give up.
	for width := f32(1000); width >= 100; width -= 37 {
		g := views.changes_geometry({0, 0, width, 600}, 1, &view, &f.text, &state)
		views.changes_layout(&state, &view, &f.text, &f.mono, g.diff.width, 1)
		if !draw_into(t, &f, &list, &view, &state, g) {return}
		inside := 0
		for glyph in list.glyphs {
			y := glyph.rect.y + glyph.rect.height / 2
			if y < g.row.y || y >= g.row.y + g.row.height {continue}
			inside += 1
			in_summary := glyph.rect.x >= g.summary.x && glyph.rect.x < g.summary.x + g.summary.width
			in_files := glyph.rect.x >= g.files_button.x && glyph.rect.x < g.files_button.x + g.files_button.width
			testing.expect(t, in_summary || in_files)
		}
		testing.expect(t, inside > 0 || g.summary.width < 60)
	}

	// Open, the panel paints its captions and chips inside itself, and no Files section.
	g := views.changes_geometry({0, 0, 900, 600}, 1, &view, &f.text, &state)
	views.changes_layout(&state, &view, &f.text, &f.mono, g.diff.width, 1)
	closed := 0
	if !draw_into(t, &f, &list, &view, &state, g) {return}
	for glyph in list.glyphs {
		if glyph.rect.y >= g.panel.y + 6 && glyph.rect.y < g.panel.y + g.panel.height - 6 {
			if glyph.rect.x >= g.panel.x + 12 && glyph.rect.x < g.panel.x + g.panel.width - 12 {closed += 1}
		}
	}
	state.panel_open = true
	if !draw_into(t, &f, &list, &view, &state, g) {return}
	painted, on_chip := 0, 0
	for glyph in list.glyphs {
		y := glyph.rect.y + glyph.rect.height / 2
		if y < g.panel.y || y >= g.panel.y + g.panel.height {continue}
		if glyph.rect.x < g.panel.x || glyph.rect.x >= g.panel.x + g.panel.width {continue}
		painted += 1
		chip := g.source_chips[1]
		if y >= chip.y && y < chip.y + chip.height && glyph.rect.x >= chip.x && glyph.rect.x < chip.x + chip.width {
			on_chip += 1
		}
	}
	testing.expect(t, painted > closed)
	// "All agents".
	testing.expect(t, on_chip >= 8)

	// The ⋯ menu paints every row when the header is collapsed.
	state.panel_open, state.tools_open = false, true
	narrow := views.changes_geometry({0, 0, 260, 600}, 1, &view, &f.text, &state)
	views.changes_layout(&state, &view, &f.text, &f.mono, narrow.diff.width, 1)
	if !draw_into(t, &f, &list, &view, &state, narrow) {return}
	for row, i in narrow.tools_rows {
		text := 0
		for glyph in list.glyphs {
			y := glyph.rect.y + glyph.rect.height / 2
			if y >= row.y && y < row.y + row.height && glyph.rect.x >= row.x && glyph.rect.x < row.x + row.width {
				text += 1
			}
		}
		testing.expect(t, text > 0)
		_ = i
	}
	state.tools_open = false

	// The overview strip draws a tick in the added and the removed colour for each run of the diff.
	tall := views.changes_geometry({0, 0, 900, 200}, 1, &view, &f.text, &state)
	views.changes_layout(&state, &view, &f.text, &f.mono, tall.diff.width, 1)
	if !draw_into(t, &f, &list, &view, &state, tall) {return}
	green, red := render.Color{0, 1, 0, 1}, render.Color{1, 0, 0, 1}
	// A tick the thumb crosses is split into its dimmed and full parts, so each run draws at least one rect.
	same :: proc(a, b: render.Color) -> bool {return a.r == b.r && a.g == b.g && a.b == b.b}
	added, removed := 0, 0
	for rect in list.rects {
		lane := tall.overview
		if rect.rect.x < lane.x || rect.rect.x >= lane.x + lane.width {continue}
		if rect.rect.y < lane.y || rect.rect.y >= lane.y + lane.height {continue}
		if same(rect.color, green) {added += 1}
		if same(rect.color, red) {removed += 1}
	}
	testing.expect(t, added >= len(state.rows.ticks) / 2)
	testing.expect(t, removed >= len(state.rows.ticks) / 2)
}
