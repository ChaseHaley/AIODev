package main

import "aio:input"
import "aio:layout"
import "aio:render"
import "aio:ui"
import "core:fmt"
import "core:math"

// A drag carries the marked tabs. As with a pane, their workspace must keep content of its own.
@(require_results)
tab_window_source_allows :: proc(workspace: ^Workspace) -> bool {
	marked, kept := false, false
	for tab in workspace.tabs {
		if tab.marked {marked = true} else {kept = true}
	}
	return marked && kept
}

// Tabs another window's drag would add here: its tabs open a gap at `slot`, and a ghost shows them landing.
// A count of 0 is no gap. tab_incoming_set is the only writer, driven by the dragging window's destination.
Tab_Incoming :: struct {
	source:      input.Window_Id,
	count, slot: int,
	ghost:       ui.Motion,
}

// Where tabs dropped at a point in w would land, centring their group on the pointer. A drop away from the
// tabs lands after them.
@(require_results)
tab_drop_slot :: proc(app: ^App, w: ^Window, incoming: int, x, y: f32) -> int {
	count := len(w.workspace.tabs)
	offset, size: f32
	if w.tabs_horizontal {
		bar := window_tab_bar(app, w)
		if y >= bar.height {return count}
		offset, size = x - bar.x, bar.tab_width
	} else {
		area := rail_area(w)
		if !rail_visible(w) || x < area.x || x >= area.x + area.width || y < area.y {return count}
		rail, built := rail_current_layout(w)
		if !built {return count}
		offset, size = y - ui.rail_row_rect(rail, 0).y, rail.row_height
	}
	if size <= 0 {return count}
	return clamp(int(math.floor(offset / size - f32(incoming) / 2 + 0.5)), 0, count)
}

// Opens, moves or, with a count of 0, closes the gap of window `id` for an offer of tabs.
tab_incoming_set :: proc(app: ^App, id: input.Window_Id, offer: Tab_Incoming) {
	w := window_find(app, id)
	if w == nil {return}
	incoming := &w.tab_incoming
	switch {
	case offer.count == 0:
		if incoming.count == 0 {return}
		incoming^ = {}
	case incoming.count == 0:
		incoming^ = {
			source = offer.source,
			count  = offer.count,
			slot   = offer.slot,
			ghost  = {value = f32(offer.slot), target = f32(offer.slot)},
		}
	case incoming.slot != offer.slot:
		incoming.slot = offer.slot
		ui.motion_target(&incoming.ghost, f32(offer.slot), ui.REORDER_DURATION, .Decelerate, app.animations)
	case:
		return
	}
	w.dirty = true
}

// Offers the drop to `destination` at a point in its coordinates, which opens or moves its gap. Nil offers it
// to no other window.
tab_drag_over :: proc(app: ^App, w, destination: ^Window, x, y: f32) {
	a, _ := tab_drag_state(w)
	if a == nil {return}
	if destination == nil {
		tab_drag_retarget(app, w, a, nil)
		return
	}
	slot := tab_drop_slot(app, destination, tabs_marked_count(w.workspace), x, y)
	tab_drag_retarget(app, w, a, Drop_Other_Window{destination.id, slot})
}

// Holds w's workspace dropdown open while the pointer is on it, as for a pane.
@(require_results)
tab_workspace_drag_move :: proc(app: ^App, source, w: ^Window, x, y: f32) -> bool {
	a, carry := tab_drag_state(source)
	if a == nil {return false}
	grabbed := carry.grabbed
	request := Workspace_Move_Request{source.workspace.id, grabbed.id, grabbed.tree.focus, true}
	allows := tab_window_source_allows(source.workspace)
	held, on := workspace_picker_drag_hover(app, a, w, x, y, request, true, allows)
	if !on {
		if _, holding := carry.destination.(Drop_Workspace_Dropdown); holding {
			tab_drag_retarget(app, source, a, nil)
		}
		return false
	}
	tab_drag_retarget(app, source, a, held)
	source.dirty, w.dirty = true, true
	return true
}

// Tracks a tab drag leaving its tabs, returning whether it now offers a dropdown, a window or a new window.
@(require_results)
tab_drag_windows_move :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	a, _ := tab_drag_state(w)
	a.pointer = {x, y}
	point, ok := drag_point(app, w, x, y)
	if ok && !window_linked(w) && point.window != nil && !window_linked(point.window) {
		px, py := f32(point.x), f32(point.y)
		if tab_workspace_drag_move(app, w, point.window, px, py) {return true}
		if point.window != w {
			tab_drag_over(app, w, point.window, px, py)
			return true
		}
	}
	if !ok || point.window != nil || !tab_window_source_allows(w.workspace) {return false}
	_ = tear_off_preview_ensure(app, a, true)
	tab_drag_retarget(app, w, a, Drop_Tear_Off{})
	_, ready := a.preview.(Preview_Ready)
	region := window_content_area(app, w)
	drag_thumbnail_sync(app, w, &a.thumbnail, region, ready, point.screen_x, point.screen_y)
	return true
}

@(require_results)
tab_window_preview_create :: proc(app: ^App, tab: ^Tab) -> ^Window {
	content, valid := layout.focused_content(&tab.tree)
	if !valid {return nil}
	return window_preview_prepare(app, content, "")
}

@(private, require_results)
tabs_marked_count :: proc(workspace: ^Workspace) -> int {
	count := 0
	for tab in workspace.tabs {if tab.marked {count += 1}}
	return count
}

// The ids of the marked tabs a drag carries, in their order, in temporary memory.
@(private = "file", require_results)
tabs_marked_ids :: proc(workspace: ^Workspace) -> ([]u32, bool) {
	ids, err := make([]u32, tabs_marked_count(workspace), context.temp_allocator)
	if err != nil {return nil, false}
	index := 0
	for tab in workspace.tabs {
		if !tab.marked {continue}
		ids[index] = tab.id
		index += 1
	}
	return ids, true
}

// Every step that can fail comes before the first tab moves, and the window shows before the tabs move, so
// a failure leaves the source as it was and the preview still prepared.
@(require_results)
tabs_to_window :: proc(app: ^App, source_window, preview: ^Window) -> bool {
	workspace, destination := source_window.workspace, preview.workspace
	if preview.phase != .Preparing || !tab_window_source_allows(workspace) {return false}
	tabs, listed := tabs_marked_ids(workspace)
	if !listed {return false}
	// The tabs take the place of the preview's placeholder, which is already the window's selected tab.
	placeholder := destination.tabs[0]
	transfer := Workspace_Tab_Transfer{workspace, destination, tabs, 1, selected_tab(workspace).id, placeholder}
	if !workspace_tabs_transfer_reserve(app, transfer) {return false}
	name := workspace_default_name(app)
	if name == "" || !tear_off_window_show(app, preview, name) {return false}

	tab_select(app, source_window, tab_kept_index(workspace, tabs), .Preserve_Marks)
	workspace_tabs_transfer(app, transfer)
	workspace_tab_choose(workspace, workspace.selected)
	window_relayout(app, source_window)
	rail_reveal_active(source_window)
	window_preview_publish(preview, name)
	window_relayout(app, preview)
	focus_enter(app, preview)
	workspace_mutation_finish(app, workspace, {.Structure})
	workspace_mutation_finish(app, destination, {.Structure, .Names})
	_ = window_activate(app, preview)
	return true
}

// Moves the marked tabs into another workspace, inserting them at `slot`, as workspace_tabs_move does.
@(require_results)
tabs_to_workspace :: proc(
	app: ^App,
	source_window: ^Window,
	destination: ^Workspace,
	slot: int,
) -> Tab_Move_Result {
	tabs, listed := tabs_marked_ids(source_window.workspace)
	selected := selected_tab(source_window.workspace)
	if !listed || selected == nil || destination == nil {return .Failed}
	return workspace_tabs_move(app, source_window, destination, tabs, selected.id, slot)
}

// Finishes a drag held on a workspace dropdown, whose rows are the other workspaces, then a new workspace and
// a new window. Anywhere else on it, or a failed drop, puts the tabs back.
tab_workspace_drag_release :: proc(app: ^App, w: ^Window, a: ^Drag_Active, held: Drop_Workspace_Dropdown) {
	drop := workspace_picker_drag_drop(app, held)
	if _, new_window := drop.(Workspace_Drop_New_Window); !new_window {tear_off_preview_discard(app, a)}
	moved, attempted := false, false
	switch row in drop {
	case Workspace_Drop_New_Window:
		attempted = true
		moved = tear_off_preview_ensure(app, a, false) != nil && tear_off_commit(app, w, a)
	case Workspace_Drop_Row:
		attempted = true
		moved = tabs_to_chosen_workspace(app, w, Workspace_Move_Existing{row.id})
	case Workspace_Drop_New_Workspace:
		attempted = true
		moved = tabs_to_chosen_workspace(app, w, Workspace_Move_New{})
	}
	if moved {
		drag_free(app, a)
		return
	}
	tab_drag_abandon(app, w, a)
	if attempted {notify(app, .Error, "Could not move the tabs. The source was preserved.")}
}

@(private = "file", require_results)
tabs_to_chosen_workspace :: proc(app: ^App, w: ^Window, destination: Workspace_Move_Destination) -> bool {
	workspace, created := workspace_move_destination(app, destination)
	if workspace == nil {return false}
	moved := tabs_to_workspace(app, w, workspace, len(workspace.tabs)) != .Failed
	workspace_move_destination_settle(app, workspace, created, moved)
	return moved
}

// Finishes a drag held over another window, whose gap closes as the tabs arrive. A failed drop puts the tabs
// back.
tab_drag_release_on_window :: proc(app: ^App, w: ^Window, a: ^Drag_Active, offer: Drop_Other_Window) {
	tear_off_preview_discard(app, a)
	destination := window_find(app, offer.window)
	if destination != nil && tabs_to_workspace(app, w, destination.workspace, offer.slot) != .Failed {
		drag_free(app, a)
		return
	}
	tab_drag_abandon(app, w, a)
	notify(app, .Error, "Could not move the tabs. Both windows were preserved.")
}

@(private = "file")
tab_drag_outline :: proc(app: ^App, w: ^Window) {
	area := window_content_area(app, w)
	if render.push_layer(&w.list, {0, 0, f32(w.width), f32(w.height)}) != .None {return}
	_ = render.push_rect(
		&w.list,
		{
			rect = {area.x, area.y, area.width, area.height},
			color = app.theme.accent,
			radius = f32(app.settings.pane.corner_radius) * w.scale,
			stroke = 2 * w.scale,
		},
	)
}

// The arriving tabs in the gap they would take. With no tabs on screen, the content takes an outline instead.
@(private = "file")
tab_incoming_draw :: proc(app: ^App, w: ^Window) -> render.Build_Status {
	incoming := w.tab_incoming
	r, clip: render.Rect
	if w.tabs_horizontal && !pane_fill_active(w) {
		bar := window_tab_bar(app, w)
		x := bar.x + incoming.ghost.value * bar.tab_width
		r = ui.tab_tile_rect(bar, x, f32(incoming.count) * bar.tab_width, 0, w.scale)
		clip = {0, 0, f32(w.width), bar.height}
	} else if rail, built := rail_current_layout(w); built && rail_visible(w) {
		first := ui.rail_row_rect(rail, 0)
		r = {
			first.x,
			first.y + incoming.ghost.value * rail.row_height,
			first.width,
			f32(incoming.count) * rail.row_height,
		}
		clip = rail.list
	} else {
		tab_drag_outline(app, w)
		return .Ok
	}
	if render.push_layer(&w.list, clip) != .None {return .Ok}
	radius := ui.RADIUS_CONTROL * w.scale
	fill := app.theme.accent
	fill.a *= 0.16
	if render.push_rect(&w.list, {rect = r, color = fill, radius = radius}) != .None {return .Ok}
	if render.push_rect(
		   &w.list,
		   {rect = r, color = app.theme.accent, radius = radius, stroke = 2 * w.scale},
	   ) !=
	   .None {return .Ok}
	source := window_find(app, incoming.source)
	if source == nil {return .Ok}
	_, carry := tab_drag_state(source)
	if carry == nil {return .Ok}
	label := incoming.count == 1 ? carry.grabbed.title : fmt.tprintf("%d tabs", incoming.count)
	text := ui.text_styled(&w.ui_text, .Strong)
	padding := ui.SPACE_2 * w.scale
	return ui.draw_text(
		&text,
		&w.list,
		label,
		r.x + max(padding, (r.width - ui.text_width(&text, label)) / 2),
		r.y + (r.height - text.line_height) / 2 + text.ascent,
		app.theme.text,
		max(1, r.width - 2 * padding),
	)
}

// The thumbnail copies the tab live, so the source marks it with an outline and nothing over its text.
tab_drag_draw :: proc(app: ^App, w: ^Window) -> render.Build_Status {
	if a, _ := tab_drag_state(w); a != nil {
		tear_off := drag_tearing_off(a)
		_, ready := a.preview.(Preview_Ready)
		if tear_off && ready {tab_drag_outline(app, w)}
	}
	if w.tab_incoming.count > 0 {return tab_incoming_draw(app, w)}
	return .Ok
}
