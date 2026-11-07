package main

import "aio:input"
import "aio:layout"
import "aio:render"
import "aio:ui"
import "core:fmt"
import "core:math"
import "core:time"

// A drag carries the marked tabs. As with a pane, their workspace must keep content of its own.
@(require_results)
tab_window_source_allows :: proc(workspace: ^Workspace) -> bool {
	marked, kept := false, false
	for tab in workspace.tabs {
		if tab.marked {marked = true} else {kept = true}
	}
	return marked && kept
}

// The tab that takes over the source window: the nearest that stays, preferring the right as a close does.
@(private = "file", require_results)
tab_window_kept_index :: proc(workspace: ^Workspace) -> int {
	for i in workspace.selected ..< len(workspace.tabs) {
		if !workspace.tabs[i].marked {return i}
	}
	for i := workspace.selected - 1; i >= 0; i -= 1 {
		if !workspace.tabs[i].marked {return i}
	}
	return -1
}

// Tabs another window's drag would add here: its tabs open a gap at `slot`, and a ghost shows them landing.
// A count of 0 is no gap. tab_incoming_set is the only writer, driven by the dragging window's destination.
Tab_Incoming :: struct {
	source:      input.Window_Id,
	count, slot: int,
	ghost:       ui.Motion,
}

@(private = "file", require_results)
tabs_can_join :: proc(workspace, destination: ^Workspace) -> bool {
	for tab in workspace.tabs {
		if !tab.marked {continue}
		for node in tab.tree.nodes {
			pane := node.(layout.Pane) or_continue
			if !pane_content_can_join(pane.content, destination, tab) {return false}
		}
	}
	return true
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
		ui.motion_target(
			&incoming.ghost,
			f32(offer.slot),
			140 * time.Millisecond,
			.Decelerate,
			app.animations,
			time.tick_now(),
		)
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
		drag_retarget(app, w, a, nil)
		return
	}
	slot := tab_drop_slot(app, destination, tabs_marked_count(w.workspace), x, y)
	drag_retarget(app, w, a, Drop_Other_Window{destination.id, slot})
}

// Holds w's workspace dropdown open while the pointer is on it, as for a pane.
@(require_results)
tab_workspace_drag_move :: proc(app: ^App, source, w: ^Window, x, y: f32) -> bool {
	a, carry := tab_drag_state(source)
	if a == nil {return false}
	grabbed := carry.grabbed
	request := Workspace_Move_Request{source.workspace.id, grabbed.id, grabbed.tree.focus, true}
	allows := tab_window_source_allows(source.workspace)
	held, on := workspace_picker_drag_hover(app, a.destination, w, x, y, request, allows)
	if !on {
		if _, holding := a.destination.(Drop_Workspace_Dropdown); holding {drag_retarget(app, source, a, nil)}
		return false
	}
	drag_retarget(app, source, a, held)
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
	drag_retarget(app, w, a, Drop_Tear_Off{})
	_, ready := a.preview.(Preview_Ready)
	region := window_content_area(app, w)
	drag_thumbnail_sync(app, w, &a.thumbnail, region, ready, point.screen_x, point.screen_y)
	return true
}

@(require_results)
tab_window_preview_create :: proc(app: ^App, tab: ^Tab) -> ^Window {
	pane, valid := tab.tree.nodes[tab.tree.focus].(layout.Pane)
	if !valid {return nil}
	return window_preview_prepare(app, pane.content, "")
}

@(private, require_results)
tabs_marked_count :: proc(workspace: ^Workspace) -> int {
	count := 0
	for tab in workspace.tabs {if tab.marked {count += 1}}
	return count
}

// A record for each of `count` tabs, in temporary memory. A placeholder already in the destination is first.
@(private = "file", require_results)
tab_records_reserve :: proc(
	destination: ^Workspace,
	count: int,
	placeholder: ^Tab = nil,
) -> (
	[]^Tab,
	bool,
) {
	records, records_error := make([]^Tab, count, context.temp_allocator)
	if records_error != nil {return nil, false}
	reserved := false
	defer if !reserved {tab_records_free(records, placeholder)}
	for &record, i in records {
		if i == 0 && placeholder != nil {
			record = placeholder
			continue
		}
		created, record_error := tab_record_reserve(destination)
		if record_error != .None {return nil, false}
		record = created
	}
	if reserve(&destination.tabs, len(destination.tabs) + count) != nil {return nil, false}
	reserved = true
	return records, true
}

@(private = "file")
tab_records_free :: proc(records: []^Tab, placeholder: ^Tab = nil) {
	for record in records {if record != nil && record != placeholder {tab_record_free(record)}}
}

// Sessions never restart: each marked tab's tree changes owner whole, so panes keep their arrangement and a
// linked window follows its panes. Records join the destination in order at `at`, and the emptied tabs leave
// the source, whose window must already show a tab that stays unless all of them go. Returns the selected
// tab's place in `records`.
@(private = "file")
tabs_carry :: proc(
	app: ^App,
	workspace, destination: ^Workspace,
	records: []^Tab,
	selected: ^Tab,
	at: int,
	has_placeholder := false,
) -> int {
	selected_index, index, insert := 0, 0, at
	for tab in workspace.tabs {
		if !tab.marked {continue}
		record := records[index]
		if tab == selected {selected_index = index}
		placeholder := has_placeholder && index == 0
		if placeholder {layout.destroy(&record.tree)}
		record.tree, tab.tree = tab.tree, {root = layout.INVALID_NODE, focus = layout.INVALID_NODE}
		record.name, tab.name = tab.name, ""
		record.marked = true
		if placeholder {
			tab_update_title(app, record)
		} else {
			tab_record_commit(app, destination, record, insert)
			insert += 1
		}
		index += 1
	}
	// With nothing left there is no tab to show while the rest close, so the windows let go of all of them.
	if index == len(workspace.tabs) {
		for w in app.windows {
			if w.workspace != workspace {continue}
			w.tree = nil
			tab_presentation_clear(&w.presentation)
		}
		for tab in workspace.tabs {tab_record_free(tab)}
		clear(&workspace.tabs)
		workspace.selected = 0
		workspace_settings_sync(app, workspace)
		return selected_index
	}
	for i := len(workspace.tabs) - 1; i >= 0; i -= 1 {
		if workspace.tabs[i].tree.root == layout.INVALID_NODE {workspace_close_tab(app, workspace, i)}
	}
	return selected_index
}

// Every step that can fail comes before the first layout moves, and the window shows before the tabs move, so
// a failure leaves the source as it was and the preview still prepared.
@(require_results)
tabs_to_window :: proc(app: ^App, source_window, preview: ^Window) -> bool {
	workspace, destination := source_window.workspace, preview.workspace
	if preview.phase != .Preparing || !tab_window_source_allows(workspace) {return false}
	// The first tab takes over the preview's placeholder, which is already the window's selected tab.
	records, reserved := tab_records_reserve(destination, tabs_marked_count(workspace), destination.tabs[0])
	if !reserved {return false}
	name := workspace_default_name(app)
	if name == "" || !window_commit(app, preview) {
		delete(name)
		tab_records_free(records, destination.tabs[0])
		return false
	}

	selected := selected_tab(workspace)
	tab_select(app, source_window, tab_window_kept_index(workspace), true)
	selected_index := tabs_carry(app, workspace, destination, records, selected, 1, true)
	tab_select_one(workspace, workspace.selected)

	destination.provisional = false
	destination.name = name
	destination.selected = selected_index
	destination.selection_anchor = records[selected_index].id
	preview.tree = &records[selected_index].tree
	workspace_pickers_refresh(app)
	mark_all_dirty(app)
	window_relayout(app, preview)
	focus_enter(app, preview)
	workspace_settings_sync(app, destination)
	_ = window_activate(app, preview)
	return true
}

// Moves the marked tabs into another workspace, inserting them at `slot`. Every step that can fail comes
// before the first layout moves. A workspace no window shows comes to the source window, as with moving a
// pane. When the last tabs go, the source workspace is deleted and its window closes if the destination has a
// window of its own, so a caller must look `source_window` up before using it again.
@(require_results)
tabs_to_workspace :: proc(app: ^App, source_window: ^Window, destination: ^Workspace, slot: int) -> bool {
	workspace := source_window.workspace
	if workspace == destination ||
	   window_linked(source_window) ||
	   !workspace_eligible(app, destination) ||
	   !tabs_can_join(workspace, destination) {
		return false
	}
	count := tabs_marked_count(workspace)
	if count == 0 {return false}
	records, reserved := tab_records_reserve(destination, count)
	if !reserved {return false}
	at := clamp(slot, 0, len(destination.tabs))
	owner := window_for_workspace(app, destination)
	if owner != nil && !tab_presentation_reserve(&owner.presentation, len(destination.tabs) + count) {
		tab_records_free(records)
		return false
	}

	// The destination takes focus first, so Windows does not hand it to another app as the source closes.
	if owner != nil {
		_ = window_activate(app, owner)
		focus_leave(app, owner)
	}
	selected := selected_tab(workspace)
	kept := tab_window_kept_index(workspace)
	if kept < 0 {
		// Every tab goes, so the window stays left until it adopts the destination or closes with its
		// emptied workspace.
		focus_leave(app, source_window)
	} else {
		tab_select(app, source_window, kept, true)
	}
	for tab in destination.tabs {tab.marked = false}
	selected_index := tabs_carry(app, workspace, destination, records, selected, at)
	if kept >= 0 {tab_select_one(workspace, workspace.selected)}
	destination.selected = at + selected_index
	destination.selection_anchor = records[selected_index].id

	if owner != nil {
		tab_incoming_set(app, owner.id, {})
		owner.tab_hover = -1
		tab_presentation_insert(&owner.presentation, at, count)
		owner.tree = &records[selected_index].tree
		window_relayout(app, owner)
		rail_reveal_active(owner)
		focus_enter(app, owner)
	} else if !workspace_select(app, source_window, destination) {
		notify(app, .Error, "The tabs moved, but their workspace could not be displayed.")
	}
	workspace_settings_sync(app, destination)
	workspace_close_empty(app, workspace, replace_window = owner == nil)
	workspace_pickers_refresh(app)
	mark_all_dirty(app)
	return true
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
		moved = tabs_to_chosen_workspace(app, w, row.id)
	}
	if moved {
		drag_free(app, a)
		return
	}
	tab_drag_abandon(app, w, a)
	if attempted {notify(app, .Error, "Could not move the tabs. The source was preserved.")}
}

// An id of 0 moves them into a new workspace, which takes a suggested name to edit in its chip.
@(private = "file", require_results)
tabs_to_chosen_workspace :: proc(app: ^App, w: ^Window, id: u32) -> bool {
	destination := id == 0 ? workspace_create_empty(app) : workspace_find(app, id)
	if destination == nil {return false}
	if !tabs_to_workspace(app, w, destination, len(destination.tabs)) {
		if id == 0 {_ = workspace_discard_empty(app, destination)}
		return false
	}
	if id == 0 {
		if owner := window_for_workspace(app, destination); owner != nil {workspace_name_begin(app, owner)}
	}
	return true
}

// Finishes a drag held over another window, whose gap closes as the tabs arrive. A failed drop puts the tabs
// back.
tab_drag_release_on_window :: proc(app: ^App, w: ^Window, a: ^Drag_Active, offer: Drop_Other_Window) {
	tear_off_preview_discard(app, a)
	destination := window_find(app, offer.window)
	if destination != nil && tabs_to_workspace(app, w, destination.workspace, offer.slot) {
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
		inset, height := 2 * w.scale, ui.HEIGHT_TOOLBAR * w.scale
		r = {
			bar.x + incoming.ghost.value * bar.tab_width + inset,
			(bar.height - height) / 2,
			max(0, f32(incoming.count) * bar.tab_width - 2 * inset),
			height,
		}
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
		_, tear_off := a.destination.(Drop_Tear_Off)
		_, ready := a.preview.(Preview_Ready)
		if tear_off && ready {tab_drag_outline(app, w)}
	}
	if w.tab_incoming.count > 0 {return tab_incoming_draw(app, w)}
	return .Ok
}
