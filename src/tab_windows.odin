package main

import "aio:layout"
import "aio:platform"
import "aio:render"

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

// Tracks a tab drag past every app window, returning whether the drag now offers a new window.
@(require_results)
tab_drag_tear_off_move :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	d := &w.tab_drag
	d.pointer = {x, y}
	point, ok := drag_point(app, w, x, y)
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

// The thumbnail copies the tab live, so the source marks it with an outline and nothing over its text.
tab_drag_draw :: proc(app: ^App, w: ^Window) {
	if !w.tab_drag.new_window || w.tab_drag.preview_window == 0 {return}
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
