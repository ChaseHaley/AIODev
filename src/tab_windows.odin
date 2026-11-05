package main

import "aio:glyphs"
import "aio:layout"
import "aio:platform"
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
Tab_Incoming :: struct {
	source:      platform.Window_Id,
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

// Closes the gap in the window that was offered the drop.
tab_incoming_close :: proc(app: ^App, id: platform.Window_Id) {
	w := window_find(app, id)
	if w == nil || w.tab_incoming.count == 0 {return}
	w.tab_incoming = {}
	w.dirty = true
}

// Offers the drop to `destination` at a point in its coordinates, moving any open gap there. Nil offers it to
// no other window.
tab_drag_over :: proc(app: ^App, w, destination: ^Window, x, y: f32) {
	d := &w.tab_drag
	if destination == nil || d.destination_window != destination.id {
		tab_incoming_close(app, d.destination_window)
	}
	d.destination_window, d.destination_refused = 0, false
	if destination == nil {return}
	d.destination_window = destination.id
	d.elsewhere = false
	if d.new_window {w.dirty = true}
	d.new_window = false
	drag_thumbnail_sync(app, w, &d.thumbnail, {}, false, 0, 0)
	if !tabs_can_join(w.workspace, destination.workspace) {
		d.destination_refused = true
		tab_incoming_close(app, destination.id)
		return
	}
	incoming := &destination.tab_incoming
	count := tabs_marked_count(w.workspace)
	slot := tab_drop_slot(app, destination, count, x, y)
	if incoming.count == 0 {
		incoming^ = {
			source = w.id,
			count = count,
			slot = slot,
			ghost = {value = f32(slot), target = f32(slot)},
		}
		destination.dirty = true
	} else if incoming.slot != slot {
		incoming.slot = slot
		ui.motion_target(
			&incoming.ghost,
			f32(slot),
			140 * time.Millisecond,
			.Decelerate,
			app.animations,
			time.tick_now(),
		)
		destination.dirty = true
	}
}

// Tracks a tab drag leaving its window, returning whether the drag now offers another window or a new one.
@(require_results)
tab_drag_windows_move :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	d := &w.tab_drag
	d.pointer = {x, y}
	point, ok := drag_point(app, w, x, y)
	if ok && !w.linked && point.window != nil && point.window != w && !point.window.linked {
		tab_drag_over(app, w, point.window, f32(point.x), f32(point.y))
		return true
	}
	tab_drag_over(app, w, nil, 0, 0)
	tear_off := ok && point.window == nil && tab_window_source_allows(w.workspace)
	if d.new_window != tear_off {w.dirty = true}
	d.new_window = tear_off
	if !tear_off {
		drag_thumbnail_sync(app, w, &d.thumbnail, {}, false, 0, 0)
		return false
	}
	d.elsewhere = false
	if d.preview_window == 0 && !d.preview_failed {
		if preview := tab_window_preview_create(app, d.grabbed); preview != nil {
			d.preview_window = preview.id
		} else {
			d.preview_failed = true
			notify(app, .Error, "Could not prepare a new window. The tab was preserved.")
		}
	}
	region := window_content_area(app, w)
	drag_thumbnail_sync(app, w, &d.thumbnail, region, d.preview_window != 0, point.screen_x, point.screen_y)
	return true
}

@(require_results)
tab_window_preview_create :: proc(app: ^App, tab: ^Tab) -> ^Window {
	pane, valid := tab.tree.nodes[tab.tree.focus].(layout.Pane)
	if !valid {return nil}
	return window_preview_prepare(app, pane.content, "")
}

// Puts the marked tabs in the prepared window at the pointer and starts naming it there.
@(require_results)
tab_tear_off :: proc(
	app: ^App,
	source_window: ^Window,
	pointer: [2]f32,
	preview_id: platform.Window_Id,
) -> bool {
	preview := window_find(app, preview_id)
	if preview == nil || !window_place_at_pointer(app, preview, source_window, pointer) {return false}
	if !tabs_to_window(app, source_window, preview) {return false}
	workspace_name_begin(app, preview)
	return true
}

@(private = "file", require_results)
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
// the source, whose window must already show a tab that stays or be closed. Returns the selected tab's place
// in `records`.
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
	for i := len(workspace.tabs) - 1; i >= 0; i -= 1 {
		if workspace.tabs[i].tree.root == layout.INVALID_NODE {workspace_close_tab(app, workspace, i)}
	}
	return selected_index
}

// Every step that can fail comes before the first layout moves.
@(require_results)
tabs_to_window :: proc(app: ^App, source_window, preview: ^Window) -> bool {
	workspace, destination := source_window.workspace, preview.workspace
	if !preview.preparing || !tab_window_source_allows(workspace) {return false}
	// The first tab takes over the preview's placeholder, which is already the window's selected tab.
	records, reserved := tab_records_reserve(destination, tabs_marked_count(workspace), destination.tabs[0])
	if !reserved {return false}
	name := workspace_default_name(app)
	if name == "" {
		tab_records_free(records, destination.tabs[0])
		return false
	}

	selected := selected_tab(workspace)
	tab_select(app, source_window, tab_window_kept_index(workspace), true)
	selected_index := tabs_carry(app, workspace, destination, records, selected, 1, true)
	tab_select_one(workspace, workspace.selected)

	preview.preparing = false
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
	if !window_show_prepared(app, preview) {
		notify(app, .Error, "The tabs moved, but their window could not be shown. Reopen it from the tray.")
		return true
	}
	_ = window_activate(app, preview)
	return true
}

// Moves the marked tabs into the workspace another window shows, inserting them at `slot`. Every step that
// can fail comes before the first layout moves. Taking the source's last tabs closes its window and deletes
// its workspace, so a caller must look `source_window` up before using it again.
@(require_results)
tabs_to_workspace :: proc(app: ^App, source_window, destination_window: ^Window, slot: int) -> bool {
	workspace, destination := source_window.workspace, destination_window.workspace
	if source_window == destination_window ||
	   source_window.linked ||
	   destination_window.linked ||
	   destination_window.preparing ||
	   !tabs_can_join(workspace, destination) {
		return false
	}
	count := tabs_marked_count(workspace)
	if count == 0 {return false}
	records, reserved := tab_records_reserve(destination, count)
	if !reserved {return false}
	at := clamp(slot, 0, len(destination.tabs))
	if !tab_presentation_reserve(&destination_window.presentation, len(destination.tabs) + count) {
		tab_records_free(records)
		return false
	}

	// The destination takes focus first, so Windows does not hand it to another app as the source closes.
	_ = window_activate(app, destination_window)
	focus_leave(app, destination_window)
	selected := selected_tab(workspace)
	kept := tab_window_kept_index(workspace)
	if kept < 0 {
		focus_leave(app, source_window)
		window_close(app, source_window)
	} else {
		tab_select(app, source_window, kept, true)
	}
	for tab in destination.tabs {tab.marked = false}
	selected_index := tabs_carry(app, workspace, destination, records, selected, at)
	if kept >= 0 {
		tab_select_one(workspace, workspace.selected)
	} else {
		workspace_close_empty(app, workspace, replace_window = false)
	}

	destination_window.tab_incoming = {}
	destination_window.tab_hover = -1
	tab_presentation_insert(&destination_window.presentation, at, count)
	destination.selected = at + selected_index
	destination.selection_anchor = records[selected_index].id
	destination_window.tree = &records[selected_index].tree
	workspace_pickers_refresh(app)
	mark_all_dirty(app)
	window_relayout(app, destination_window)
	rail_reveal_active(destination_window)
	focus_enter(app, destination_window)
	workspace_settings_sync(app, destination)
	return true
}

// Finishes a drag held over another window. A refused or failed drop puts the tabs back.
tab_drag_release_on_window :: proc(app: ^App, w: ^Window) {
	d := w.tab_drag
	// Moving the tabs ends this window's gestures, which must not restore the order being kept.
	w.tab_drag = {}
	drag_thumbnail_destroy(&d.thumbnail)
	w.dirty = true
	if d.preview_window != 0 {pane_window_preview_discard(app, d.preview_window)}
	d.preview_window = 0
	destination := window_find(app, d.destination_window)
	if destination != nil && !d.destination_refused {
		if tabs_to_workspace(app, w, destination, destination.tab_incoming.slot) {
			delete(d.order)
			return
		}
	}
	w.tab_drag = d
	tab_drag_cancel(app, w)
	if d.destination_refused {
		notify(app, .Warning, "That workspace already has Settings open. The tabs stayed here.")
	} else {
		notify(app, .Error, "Could not move the tabs. Both windows were preserved.")
	}
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
tab_incoming_draw :: proc(app: ^App, w: ^Window) -> glyphs.Result {
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
	if source == nil || source.tab_drag.grabbed == nil {return .Ok}
	label := incoming.count == 1 ? source.tab_drag.grabbed.title : fmt.tprintf("%d tabs", incoming.count)
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
tab_drag_draw :: proc(app: ^App, w: ^Window) -> glyphs.Result {
	if w.tab_drag.new_window && w.tab_drag.preview_window != 0 {tab_drag_outline(app, w)}
	if w.tab_incoming.count > 0 {return tab_incoming_draw(app, w)}
	return .Ok
}
