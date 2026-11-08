package main

import "aio:render"
import "aio:ui"
import "core:math"

tab_press :: proc(app: ^App, w: ^Window, index: int, x, y: f32, modified: bool) {
	if index < 0 || index >= len(w.workspace.tabs) || !w.workspace.tabs[index].marked {return}
	offset: [2]f32
	if w.tabs_horizontal {
		bar := window_tab_bar(app, w)
		if bar.tab_width <= 0 {return}
		offset.x = x - (bar.x + tab_position(w, index) * bar.tab_width)
	} else {
		row := rail_row_rect_for_tab(w, index)
		if row.height <= 0 {return}
		offset.y = (y - row.y) / row.height
	}
	drag_press(w, x, y, Tab_Grab{w.workspace.tabs[index], offset, modified})
}

// Moves a tab and everything indexed by tab position, keeping the selected tab selected.
tab_move :: proc(app: ^App, w: ^Window, from, to: int) {
	tabs := &w.workspace.tabs
	if from == to || from < 0 || to < 0 || from >= len(tabs) || to >= len(tabs) {return}
	tab := tabs[from]
	ordered_remove(tabs, from)
	inject_at(tabs, to, tab)
	tab_presentation_move(&w.presentation, from, to)
	w.workspace.selected = tab_selected_after_move(w.workspace.selected, from, to)
	rail_reveal_active(w)
	mark_all_dirty(app)
}

// The active tab drag in w, or nil.
@(private)
tab_drag_state :: proc(w: ^Window) -> (^Drag_Active, ^Tab_Carry) {
	a := drag_active(w)
	if a == nil {return nil, nil}
	carry, tab := &a.carry.(Tab_Carry)
	if !tab {return nil, nil}
	return a, carry
}

tab_drag_move :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	if grab, passed := drag_threshold_passed(w, x, y); passed {
		tab, is_tab := grab.(Tab_Grab)
		if !is_tab {return false}
		order, err := make([dynamic]^Tab, len(w.workspace.tabs))
		if err != nil {
			_ = drag_end(w)
			notify(app, .Error, "Could not begin tab dragging.")
			return true
		}
		copy(order[:], w.workspace.tabs[:])
		rank := 0
		for candidate in order {if candidate == tab.grabbed {break}; if candidate.marked {rank += 1}}
		_ = drag_activate(w, Tab_Carry{grab = tab, order = order, rank = rank}, x, y)
	}
	if !tab_drag_active(w) {return false}
	if tab_drag_windows_move(app, w, x, y) {return true}
	if w.tabs_horizontal {return tab_drag_move_strip(app, w, x)}
	return tab_drag_move_rail(app, w, x, y)
}

@(private)
tab_drag_apply_slot :: proc(app: ^App, w: ^Window, slot: int) -> bool {
	_, d := tab_drag_state(w)
	marked, mark_error := make([]bool, len(d.order), context.temp_allocator)
	if mark_error !=
	   nil {tab_drag_cancel(app, w); notify(app, .Error, "Could not move tabs."); return false}
	count := 0
	for tab, i in d.order {marked[i] = tab.marked; if tab.marked {count += 1}}
	if len(d.order) - count <= 0 {return false}
	order, order_error := make([]int, len(d.order), context.temp_allocator)
	if order_error !=
	   nil {tab_drag_cancel(app, w); notify(app, .Error, "Could not move tabs."); return false}
	if !ui.tab_group_order(marked, slot, order) {return false}
	for original, to in order {
		for tab, from in w.workspace.tabs {
			if tab == d.order[original] {tab_move(app, w, from, to); break}
		}
	}
	w.dirty = true
	return true
}

@(private)
tab_drag_move_strip :: proc(app: ^App, w: ^Window, x: f32) -> bool {
	a, d := tab_drag_state(w)
	tab_drag_retarget(app, w, a, Drop_Reorder{})
	bar := window_tab_bar(app, w)
	if bar.tab_width <= 0 {return true}
	count := 0
	for tab in d.order {if tab.marked {count += 1}}
	if len(d.order) - count <= 0 {return true}
	first := clamp(
		(x - bar.x - d.offset.x) / bar.tab_width - f32(d.rank),
		0,
		f32(len(d.order) - count),
	)
	if !tab_drag_apply_slot(app, w, int(math.floor(first + 0.5))) {return true}
	tab_drag_follow_pointer(w, first)
	return true
}

@(private)
tab_drag_follow_pointer :: proc(w: ^Window, first: f32) {
	rank := 0
	for tab, i in w.workspace.tabs {
		if !tab.marked {continue}
		if i < len(w.tab_positions) {
			ui.motion_target(&w.tab_positions[i], first + f32(rank), 0, .Linear, false)
		}
		rank += 1
	}
}

@(private)
tab_drag_move_rail :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	a, d := tab_drag_state(w)
	layout, ok := rail_current_layout(w)
	if !ok || !rail_visible(w) || layout.list.height <= 0 || layout.row_height <= 0 {
		tab_drag_retarget(app, w, a, nil)
		w.dirty = true
		return true
	}
	if !render.rect_contains(rail_area(w), x, y) {
		tab_drag_retarget(app, w, a, nil)
		w.dirty = true
		return true
	}
	tab_drag_retarget(app, w, a, Drop_Reorder{})
	if layout.count == 0 {return true}
	count := 0
	for tab in d.order {if tab.marked {count += 1}}
	if len(d.order) - count <= 0 {return true}
	first_row := ui.rail_row_rect(layout, 0)
	first :=
		(y - first_row.y) / layout.row_height -
		d.offset.y -
		f32(d.rank)
	first = clamp(first, 0, f32(len(d.order) - count))
	if !tab_drag_apply_slot(app, w, int(math.floor(first + 0.5))) {return true}
	first = clamp(first + (w.rail_scroll - layout.scroll) / layout.row_height, 0, f32(len(d.order) - count))
	tab_drag_follow_pointer(w, first)
	return true
}

tab_drag_cancel :: proc(app: ^App, w: ^Window) {
	if !tab_drag_held(w) {return}
	d := drag_end(w)
	if a, active := &d.(Drag_Active); active {tab_drag_abandon(app, w, a)}
}

// Puts an ended tab drag's tabs back in their order and lets go of everything it held.
@(private)
tab_drag_abandon :: proc(app: ^App, w: ^Window, a: ^Drag_Active) {
	for tab, to in a.carry.(Tab_Carry).order {
		for current, from in w.workspace.tabs {if current == tab {tab_move(app, w, from, to); break}}
	}
	drag_let_go(app, w, a)
}

// Drops the tabs at the destination. A click without a drag selects only the pressed tab, unless it changed
// the marks.
tab_drag_release :: proc(app: ^App, w: ^Window) {
	if !tab_drag_held(w) {return}
	d := drag_end(w)
	switch &state in d {
	case Drag_Pressed:
		if !state.grab.(Tab_Grab).modified {workspace_tab_choose(w.workspace, w.workspace.selected)}
	case Drag_Active:
		a := &state
		drag_thumbnail_destroy(&a.thumbnail)
		switch destination in a.carry.(Tab_Carry).destination {
		case Drop_Workspace_Dropdown:
			tab_workspace_drag_release(app, w, a, destination)
		case Drop_Other_Window:
			tab_drag_release_on_window(app, w, a, destination)
		case Drop_Tear_Off:
			_, ready := a.preview.(Preview_Ready)
			if ready && tear_off_commit(app, w, a) {
				drag_free(app, a)
				return
			}
			tab_drag_abandon(app, w, a)
			if ready {notify(app, .Error, "Could not move the tabs. The source was preserved.")}
		case Drop_Reorder:
			drag_let_go(app, w, a)
		case nil:
			tab_drag_abandon(app, w, a)
		}
	}
}

// The drop may take the window's last tab, and the window with it.
tab_drag_finish :: proc(app: ^App, w: ^Window) {
	id := w.id
	tab_drag_release(app, w)
	if window_find(app, id) != nil {rail_overlay_dismiss(app, w)}
}
