package app_test

import app "../../src"
import "aio:layout"
import "aio:ui"
import "core:testing"
import "core:time"

@(test)
tab_reorder_motion_follows_pointer_and_displaces_rows_in_both_orientations :: proc(t: ^testing.T) {
	for horizontal in ([?]bool{true, false}) {
		state := app.App{animations = true}
		workspace: app.Workspace
		w := app.Window{workspace = &workspace, width = 1000, height = 700, scale = 1,
			rail_auto = true, tabs_horizontal = horizontal}
		append(&state.windows, &w)
		defer delete(state.windows)
		defer delete(workspace.tabs)
		defer delete(w.rail_rows)
		defer app.tab_presentation_destroy(&w.presentation)
		tabs: [4]app.Tab
		for &tab, i in tabs {
			tab.id = u32(i + 1)
			testing.expect_value(t, layout.init(&tab.tree, {.Terminal, u32(i + 1)}), nil)
			defer layout.destroy(&tab.tree)
			append(&workspace.tabs, &tab)
		}
		tabs[0].marked = true
		w.tree = &tabs[0].tree
		if !testing.expect(t, app.tab_presentation_resize(&w.presentation, len(tabs))) {return}
		first := horizontal ? app.window_tab_rect(&state, &w, 0) : app.rail_row_rect_for_tab(&w, 0)
		x, y := first.x + first.width / 2, first.y + first.height / 2
		app.tab_press(&state, &w, 0, x, y, false)
		if horizontal {x += 1.25 * first.width} else {y += 1.25 * first.height}
		testing.expect(t, app.tab_drag_move(&state, &w, x, y))
		testing.expect(t, workspace.tabs[1] == &tabs[0])
		moved := horizontal ? app.window_tab_rect(&state, &w, 1) : app.rail_row_rect_for_tab(&w, 1)
		attached := horizontal ? (moved.x - first.x) / first.width : (moved.y - first.y) / first.height
		testing.expect_value(t, attached, f32(1.25))
		if !horizontal {
			l, ok := app.rail_current_layout(&w)
			testing.expect(t, ok)
			testing.expect_value(t, app.rail_tab_hit(&w, l, moved.x + moved.width / 2, moved.y + 2), 1)
			close := ui.rail_close_rect(l, 1, w.scale)
			close.y += 0.25 * first.height
			hit := app.rail_tab_interaction_hit(&w, close.x + close.width / 2, close.y + close.height / 2, .Left)
			testing.expect_value(t, hit.kind, app.Tab_Interaction_Kind.Close)
			testing.expect_value(t, hit.index, 1)
			testing.expect_value(t, app.rail_tab_hit(&w, l, moved.x, l.footer.y + 1), -1)
		}
		app.update_motion(&state)
		displaced := horizontal ? app.window_tab_rect(&state, &w, 0) : app.rail_row_rect_for_tab(&w, 0)
		distance := horizontal ? (displaced.x - first.x) / first.width : (displaced.y - first.y) / first.height
		testing.expect(t, distance > 0 && distance <= 1)
		testing.expect_value(t, w.tab_positions[0].duration, 140 * time.Millisecond)
		testing.expect_value(t, w.tab_positions[0].easing, ui.Easing.Decelerate)
		app.tab_drag_release(&state, &w)
		app.update_motion(&state)
		testing.expect(t, ui.motion_active(w.tab_positions[1]))
		state.animations = false
		app.update_motion(&state)
		for position, i in w.tab_positions {testing.expect_value(t, position.value, f32(i))}
		testing.expect(t, !app.motion_active(&state))
	}
}

@(test)
tab_reorder_scrolling_groups_and_cancellation_keep_pointer_and_identity :: proc(t: ^testing.T) {
	state: app.App
	workspace: app.Workspace
	w := app.Window{workspace = &workspace, width = 1200, height = 300, scale = 1.5,
		rail_auto = true, rail_scroll = 48}
	append(&state.windows, &w)
	defer delete(state.windows)
	defer delete(workspace.tabs)
	defer delete(w.rail_rows)
	defer app.tab_presentation_destroy(&w.presentation)
	tabs: [6]app.Tab
	for &tab, i in tabs {
		tab.id = u32(i + 1)
		testing.expect_value(t, layout.init(&tab.tree, {.Terminal, u32(i + 1)}), nil)
		defer layout.destroy(&tab.tree)
		append(&workspace.tabs, &tab)
	}
	tabs[1].marked, tabs[3].marked = true, true
	workspace.selected = 1
	w.tree = &tabs[1].tree
	if !testing.expect(t, app.tab_presentation_resize(&w.presentation, len(tabs))) {return}
	first := app.rail_row_rect_for_tab(&w, 1)
	x, y := first.x + first.width / 2, first.y + 0.25 * first.height
	app.tab_press(&state, &w, 1, x, y, false)
	y += 1.25 * first.height
	testing.expect(t, app.tab_drag_move(&state, &w, x, y))
	testing.expect(t, workspace.tabs[2] == &tabs[1] && workspace.tabs[3] == &tabs[3])
	moved := app.rail_row_rect_for_tab(&w, 2)
	testing.expect_value(t, moved.y + 0.25 * moved.height, y)
	group := app.rail_row_rect_for_tab(&w, 3)
	testing.expect_value(t, group.y - moved.y, moved.height)
	app.tab_drag_move(&state, &w, 500, y)
	testing.expect(t, w.tab_drag.elsewhere)
	app.tab_drag_release(&state, &w)
	app.update_motion(&state)
	for tab, i in workspace.tabs {
		testing.expect(t, tab == &tabs[i])
		testing.expect_value(t, w.tab_positions[i].value, f32(i))
	}
	testing.expect(t, !w.tab_drag.active && !app.motion_active(&state))
	tabs[1].marked, tabs[3].marked, tabs[0].marked = false, false, true
	workspace.selected, w.tree, w.rail_scroll = 0, &tabs[0].tree, 0
	first = app.rail_row_rect_for_tab(&w, 0)
	x, y = first.x + first.width / 2, first.y + first.height / 2
	app.tab_press(&state, &w, 0, x, y, false)
	y += 2.75 * first.height
	testing.expect(t, app.tab_drag_move(&state, &w, x, y))
	testing.expect(t, w.rail_scroll > 0)
	moved = app.rail_row_rect_for_tab(&w, 3)
	testing.expect_value(t, moved.y + moved.height / 2, y)
	app.tab_drag_cancel(&state, &w)
}
