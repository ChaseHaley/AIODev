package main

import "cosmos:render"
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
	layout := tab_layout(app, w, true)
	items := tab_drag_items(w, layout, bar.tab_width, w.scale, d.whole)
	// A whole group's block starts at its chip, before its first tab.
	chip: f32
	if d.whole {for run in layout.runs {if run.carried {chip = run.width * w.scale; break}}}
	room := tab_drag_room(w, d, items, bar.tab_width)
	start := clamp(x - bar.x - d.offset.x - f32(d.rank) * bar.tab_width - chip, 0, room)
	if !tab_drag_aim(app, w, d, items, start, bar.tab_width) {return true}
	tab_drag_follow_pointer(w, (start + chip) / bar.tab_width)
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
	items := tab_drag_items(w, tab_layout(nil, w, false), 1, 0, d.whole)
	// A whole group's block starts at its chip's row, above its first tab.
	chip := f32(d.whole ? 1 : 0)
	room := tab_drag_room(w, d, items, 1)
	first_row := ui.rail_row_rect(layout, 0)
	start := clamp((y - first_row.y) / layout.row_height - d.offset.y - f32(d.rank) - chip, 0, room)
	if !tab_drag_aim(app, w, d, items, start, 1) {return true}
	tab_drag_follow_pointer(w, start + chip + (w.rail_scroll - layout.scroll) / layout.row_height)
	return true
}

// One thing dragged tabs pass among the tabs at rest (WORK-459): a group's chip, a tab, or in a whole
// group's drag, an ungrouped tab or a whole other group, chip and all. `tabs` counts the tabs it stands
// for, so a folded group's chip stands for its hidden tabs; `size` is its room in the strip's pixels or
// the rail's rows.
@(private = "file")
Drag_Item :: struct {
	group: u32,
	chip:  bool,
	tabs:  int,
	size:  f32,
}

// The items the marked tabs pass, in order, in temporary memory: a tab is `unit` long, and in the strip, with
// `scale`, a chip takes its run's room in `layout`; in the rail a chip takes a row.
@(private = "file")
tab_drag_items :: proc(w: ^Window, layout: Tab_Layout, unit, scale: f32, whole: bool) -> []Drag_Item {
	workspace := w.workspace
	items := make([dynamic]Drag_Item, 0, len(workspace.tabs) + len(layout.runs), context.temp_allocator)
	previous: u32
	for tab in workspace.tabs {
		if tab.marked {continue}
		group := tab_group_find(workspace, tab.group)
		if group != nil && tab.group != previous {
			size := unit
			if scale > 0 {
				for run in layout.runs {if run.group == group && !run.carried {size = run.width * scale}}
			}
			append(&items, Drag_Item{group = tab.group, chip = true, size = size})
		}
		previous = tab.group
		if group != nil && (group.folded || whole) {
			chip := &items[len(items) - 1]
			chip.tabs += 1
			if !group.folded {chip.size += unit}
			continue
		}
		append(&items, Drag_Item{group = tab.group, tabs = 1, size = unit})
	}
	return items[:]
}

// How far along the items the dragged block may start: up to their end, and a little past a group ending
// them, which tabs dragged on their own pull loose from.
@(private = "file")
tab_drag_room :: proc(w: ^Window, d: ^Tab_Carry, items: []Drag_Item, unit: f32) -> f32 {
	room: f32
	for item in items {room += item.size}
	if !d.whole && tab_drag_end_grouped(w) {room += GROUP_DETACH_TRAVEL * unit}
	return room
}

// Puts the dragged block, starting `start` along the items, where it passes them, and for tabs dragged on
// their own, into the group it would join there. The block passes an item once its start passes the item's
// middle, a chip as a tab. Just after a group's chip, or between two of its tabs, it is in that group. Just
// after a group's last tab it stays in the group until its start is GROUP_DETACH_MARGIN of a tab past the
// group's end, and comes into it only that far inside, so neither flickers. A folded group is passed whole.
// False when the tabs could not be moved.
@(private = "file")
tab_drag_aim :: proc(app: ^App, w: ^Window, d: ^Tab_Carry, items: []Drag_Item, start, unit: f32) -> bool {
	slot, passed := 0, 0
	at: f32
	for item in items {
		if start < at + item.size / 2 {break}
		at += item.size
		slot += item.tabs
		passed += 1
	}
	if !d.whole {
		group: u32
		if passed > 0 {
			before := items[passed - 1]
			switch {
			case before.chip:
				if before.tabs == 0 {group = before.group}
			case before.group == 0:
			case passed < len(items) && items[passed].group == before.group:
				group = before.group
			case:
				margin := GROUP_DETACH_MARGIN * unit
				if start < at + (d.group == before.group ? margin : -margin) {group = before.group}
			}
		}
		if group != d.group {w.dirty = true}
		d.group = group
	}
	return tab_drag_apply_slot(app, w, slot)
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

// How far dragged tabs may pull past a group ending the tabs, and how far past a group's end, in tab widths
// or rows, their block's start must go to leave the group or come inside to join it.
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
