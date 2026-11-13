package main

import "aio:render"
import "aio:ui"

tab_press :: proc(app: ^App, w: ^Window, index: int, x, y: f32, modified: bool, chip: u32 = 0) {
	if index < 0 || index >= len(w.workspace.tabs) || !w.workspace.tabs[index].marked {return}
	offset: [2]f32
	if w.tabs_horizontal {
		bar := window_tab_bar(app, w)
		if bar.tab_width <= 0 {return}
		offset.x = x - tab_strip_x(w, bar, index)
	} else {
		row := rail_row_rect_for_tab(w, index)
		if row.height <= 0 {return}
		offset.y = (y - row.y) / row.height
	}
	drag_press(w, x, y, Tab_Grab{w.workspace.tabs[index], offset, modified, chip})
}

// A press on group `id`'s chip marks the group's tabs, so a drag carries them all; tab_drag_release folds the
// group instead when the press ends without one.
tab_chip_press :: proc(app: ^App, w: ^Window, id: u32, x, y: f32) {
	first := -1
	for tab, i in w.workspace.tabs {
		tab.marked = tab.group == id
		if tab.marked && first < 0 {first = i}
	}
	w.dirty = true
	tab_press(app, w, first, x, y, false, id)
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
		carry := Tab_Carry{grab = tab, order = order, rank = rank, whole = true}
		shared, first := u32(0), true
		for candidate in order {
			if !candidate.marked {continue}
			if first {shared = candidate.group} else if candidate.group != shared {shared = 0}
			first = false
			if candidate.group == 0 || !tab_group_carried_whole(w.workspace, candidate.group) {carry.whole = false}
		}
		carry.group = shared
		_ = drag_activate(w, carry, x, y)
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
	if !ui.tab_marked_order(marked, slot, order) {return false}
	for original, to in order {
		for tab, from in w.workspace.tabs {
			if tab == d.order[original] {tab_move(app, w, from, to); break}
		}
	}
	w.dirty = true
	return true
}

// How many tabs come before a block of tabs starting `edge` into the strip's pixels or the rail's rows, not
// counting the marked tabs when they are the block, `carried`. A tab comes before once the block's start
// passes its middle; a folded group's tabs have no width, so they pass with their chip, together. `unit` is
// a tab's width in those units.
@(private)
tab_drag_slot :: proc(w: ^Window, layout: Tab_Layout, edge, unit, scale: f32, carried := true) -> int {
	slot, lifted := 0, 0
	for tab, i in w.workspace.tabs {
		if carried && tab.marked {
			if tab_shown(w.workspace, i) {lifted += 1}
			continue
		}
		if i >= len(layout.places) {break}
		place := layout.places[i]
		start := (place.slot - f32(lifted)) * unit + place.offset * scale
		middle := start + (tab_shown(w.workspace, i) ? unit / 2 : 0)
		if edge >= middle {slot += 1}
	}
	return slot
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
	// Past a group at the strip's end the tabs may pull a little further, showing them coming loose.
	room := max(0, bar.end - bar.x - f32(count) * bar.tab_width)
	if tab_drag_end_grouped(w) {room += GROUP_DETACH_TRAVEL * bar.tab_width}
	edge := clamp(x - bar.x - d.offset.x - f32(d.rank) * bar.tab_width, 0, room)
	layout := tab_layout(app, w, true)
	slot := tab_drag_slot(w, layout, edge, bar.tab_width, w.scale)
	tab_drag_join(w, d, layout, edge, f32(count) * bar.tab_width, bar.tab_width, w.scale)
	if !tab_drag_apply_slot(app, w, slot) {return true}
	tab_drag_follow_pointer(w, edge / bar.tab_width)
	return true
}

// The dragged tabs ride on the pointer, `first` slots in, without the chips' offsets the tabs at rest take.
@(private)
tab_drag_follow_pointer :: proc(w: ^Window, first: f32) {
	rank := 0
	for tab, i in w.workspace.tabs {
		if !tab.marked {continue}
		if i < len(w.tab_positions) {
			ui.motion_target(&w.tab_positions[i], first + f32(rank), 0, .Linear, false)
		}
		if i < len(w.tab_offsets) {ui.motion_target(&w.tab_offsets[i], 0, 0, .Linear, false)}
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
	places := tab_layout(nil, w, false)
	rows := f32(max(0, places.slots - count))
	if tab_drag_end_grouped(w) {rows += GROUP_DETACH_TRAVEL}
	first_row := ui.rail_row_rect(layout, 0)
	first :=
		(y - first_row.y) / layout.row_height -
		d.offset.y -
		f32(d.rank)
	first = clamp(first, 0, rows)
	tab_drag_join(w, d, places, first, f32(count), 1, 0)
	if !tab_drag_apply_slot(app, w, tab_drag_slot(w, places, first, 1, 0)) {return true}
	first = clamp(first + (w.rail_scroll - layout.scroll) / layout.row_height, 0, rows)
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
		grab := state.grab.(Tab_Grab)
		if !grab.modified {workspace_tab_choose(w.workspace, w.workspace.selected)}
		if group := tab_group_find(w.workspace, grab.chip); group != nil {
			_ = tab_group_fold(app, w, grab.chip, !group.folded)
		}
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
			moved := make([dynamic]^Tab, 0, len(w.workspace.tabs), context.temp_allocator)
			for tab in w.workspace.tabs {if tab.marked {append(&moved, tab)}}
			tab_drag_group(app, w, moved[:], a.carry.(Tab_Carry))
			layout_state_touch(app)
			chip := a.carry.(Tab_Carry).grab.chip
			drag_let_go(app, w, a)
			// A chip's drag marked the group only to carry it; the marks go back to the shown tab.
			if chip != 0 {workspace_tab_choose(w.workspace, w.workspace.selected)}
		case nil:
			chip := a.carry.(Tab_Carry).grab.chip
			tab_drag_abandon(app, w, a)
			if chip != 0 {workspace_tab_choose(w.workspace, w.workspace.selected)}
		}
	}
}

// The drop may take the window's last tab, and the window with it.
tab_drag_finish :: proc(app: ^App, w: ^Window) {
	id := w.id
	tab_drag_release(app, w)
	if window_find(app, id) != nil {rail_overlay_dismiss(app, w)}
}

// How far dragged tabs may pull past a group ending the tabs, and how far past a group's edge, in tab widths
// or rows, their block's middle must go to leave the group or to join another.
GROUP_DETACH_TRAVEL :: f32(0.6)
GROUP_DETACH_MARGIN :: f32(0.3)

// Whether the last tab not being dragged is in a group, so tabs dragged to the end would leave it.
@(private = "file")
tab_drag_end_grouped :: proc(w: ^Window) -> bool {
	#reverse for tab in w.workspace.tabs {
		if !tab.marked {return tab.group != 0}
	}
	return false
}

// Tabs dropped in the strip or the rail keep whole groups, as a chip's drag carries; otherwise they join the
// group the drag last showed them joining, folded or not, and leave any other.
@(private)
tab_drag_group :: proc(app: ^App, w: ^Window, moved: []^Tab, carry: Tab_Carry) {
	workspace := w.workspace
	if carry.whole {
		tab_groups_tidy(workspace)
		return
	}
	group := tab_group_find(workspace, carry.group)
	target := group != nil ? carry.group : 0
	if group != nil && group.folded {
		for tab, i in workspace.tabs {if tab == moved[0] {tab_group_add(app, w, i, target); return}}
	}
	for tab in moved {tab.group = target}
	tab_groups_tidy(workspace)
}

// Aims the dragged block, `size` long from `start`, at the group whose chip and tabs, as they rest without
// it, surround its middle. The group it is in holds it until its middle passes the edge by a margin, and
// another takes it only once its middle passes that much inside, so neither flickers at an edge. Units are
// tab_drag_slot's.
@(private = "file")
tab_drag_join :: proc(w: ^Window, d: ^Tab_Carry, layout: Tab_Layout, start, size, unit, scale: f32) {
	if d.whole {return}
	middle := start + size / 2
	found: u32
	for run in layout.runs {
		lifted, first, last: f32 = 0, -1, -1
		for tab, i in w.workspace.tabs {
			if tab.marked {
				if tab_shown(w.workspace, i) {lifted += 1}
				continue
			}
			if tab.group != run.group.id || i >= len(layout.places) {continue}
			place := layout.places[i]
			at := (place.slot - lifted) * unit + place.offset * scale
			if first < 0 {first = at}
			last = at
		}
		if first < 0 {continue}
		chip := scale > 0 ? run.width * scale : unit
		begin, end := first - chip, last + (run.group.folded ? 0 : unit)
		reach := size / 2 + (run.group.id == d.group ? 1 : -1) * GROUP_DETACH_MARGIN * unit
		if middle < begin - reach || middle >= end + reach {continue}
		if run.group.id == d.group {return}
		if found == 0 {found = run.group.id}
	}
	if d.group != found {w.dirty = true}
	d.group = found
}
