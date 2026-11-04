package main

import "aio:layout"
import "aio:platform"
import "core:log"
import "core:math"
import "core:strings"

@(private = "file")
PANE_THUMBNAIL_WIDTH :: f32(300)
@(private = "file")
PANE_THUMBNAIL_HEIGHT :: f32(190)
// The drop places the new window so the pointer rests on its title bar.
@(private = "file")
TEAR_OFF_GRAB_X :: f32(160)
@(private = "file")
TEAR_OFF_GRAB_Y :: f32(20)

pane_source_workspace :: proc(app: ^App, source: ^Tab) -> ^Workspace {
	for workspace in app.workspaces {
		for tab in workspace.tabs {if tab == source {return workspace}}
	}
	return nil
}

@(private)
pane_window_source_allows :: proc(workspace: ^Workspace) -> bool {
	if workspace == nil {return false}
	walk := workspace_panes(nil, workspace)
	count := 0
	for _, ok := workspace_pane_next(&walk); ok; _, ok = workspace_pane_next(&walk) {
		count += 1
		if count > 1 {return true}
	}
	return false
}

// Whether the pane can leave for a window of its own: its workspace keeps content, and its tab keeps a
// pane it can show when the pane is not already linked.
@(require_results)
pane_window_source_can_lose :: proc(app: ^App, source: ^Tab, node: layout.Node_Id) -> bool {
	home, linked, found := pane_link_origin(app, source, node)
	if !found || !pane_window_source_allows(home.workspace) {return false}
	return linked || pane_link_tab_can_lose(home.tab)
}

// Preview tabs borrow their source runtime; discarding one must never close its session.
@(private)
pane_preview_workspace_discard :: proc(app: ^App, workspace: ^Workspace) {
	for tab in workspace.tabs {tab_record_free(tab)}
	clear(&workspace.tabs)
	if !workspace_discard_empty(app, workspace) {
		log.error("discarding the pane preview workspace failed")
	}
}

pane_window_preview_discard :: proc(app: ^App, id: platform.Window_Id) {
	preview := window_find(app, id)
	if preview == nil || !preview.preparing {return}
	workspace_id := preview.workspace.id
	window_close(app, preview)
	if workspace := workspace_find(app, workspace_id); workspace != nil && workspace.provisional {
		pane_preview_workspace_discard(app, workspace)
	}
}

// Prepares the hidden destination window of a tear-off, proving the pane fits before the drop.
@(require_results)
pane_window_preview_create :: proc(app: ^App, source: ^Tab, node: layout.Node_Id) -> ^Window {
	home, linked, found := pane_link_origin(app, source, node)
	if !found {return nil}
	source_workspace := home.workspace
	if !pane_window_source_allows(source_workspace) {return nil}
	if !linked && !pane_link_tab_can_lose(home.tab) {return nil}
	pane, valid := workspace_pane_at(
		app,
		source_workspace,
		tab_index_by_id(source_workspace, home.tab.id),
		home.node,
	)
	if !valid {return nil}
	workspace := workspace_create_empty(app, true)
	if workspace == nil {return nil}
	success := false
	defer if !success {pane_preview_workspace_discard(app, workspace)}
	tab, record_error := tab_record_reserve(workspace)
	if record_error != .None {return nil}
	if layout.init(&tab.tree, pane.content) != nil {tab_record_free(tab); return nil}
	if home.node == home.tab.tree.root && home.tab.name != "" {
		name, name_error := strings.clone(home.tab.name)
		if name_error != nil {tab_record_free(tab); return nil}
		tab.name = name
	}
	tab_record_commit(app, workspace, tab)
	preview := window_prepare(app, workspace)
	if preview == nil {return nil}
	defer if !success {window_close(app, preview)}
	area := window_content_area(app, preview)
	panes := [?]layout.Pane_Rect{{content = pane.content, rect = area}}
	if !pane_minimum_allows(app, preview, panes[:], nil, notify_failure = false) {return nil}
	workspace_pickers_refresh(app)
	success = true
	return preview
}

// Shows the dragged pane's thumbnail at the pointer, or hides it when the drop would not open a window.
// A thumbnail that cannot be made costs only the picture: the tear-off still works.
pane_drag_thumbnail_sync :: proc(app: ^App, w: ^Window, d: ^Pane_Drag, shown: bool, x, y: i32) {
	if !shown {
		if d.thumbnail_shown {platform.thumbnail_hide(d.thumbnail)}
		d.thumbnail_shown = false
		return
	}
	if d.thumbnail == {} && !d.thumbnail_failed {
		d.thumbnail_failed = !pane_drag_thumbnail_create(app, w, d)
	}
	if d.thumbnail == {} {return}
	offset := i32(math.round(16 * w.scale))
	platform.thumbnail_place(d.thumbnail, x + offset, y + offset)
	d.thumbnail_shown = true
}

@(private = "file")
pane_drag_thumbnail_create :: proc(app: ^App, w: ^Window, d: ^Pane_Drag) -> bool {
	for pane in w.panes {
		if pane.node != d.node {continue}
		r := pane.rect
		if r.width <= 0 || r.height <= 0 {return false}
		fit := min(PANE_THUMBNAIL_WIDTH * w.scale / r.width, PANE_THUMBNAIL_HEIGHT * w.scale / r.height, 1)
		width, height := max(1, i32(r.width * fit)), max(1, i32(r.height * fit))
		thumbnail, err := platform.thumbnail_create(
			&app.platform,
			w.id,
			i32(r.x),
			i32(r.y),
			i32(r.width),
			i32(r.height),
			width,
			height,
			app.settings.active_theme.colors[.Accent].rgb,
		)
		if err != .None {return false}
		d.thumbnail, d.thumbnail_width, d.thumbnail_height = thumbnail, width, height
		return true
	}
	return false
}

pane_drag_thumbnail_destroy :: proc(d: ^Pane_Drag) {
	if d.thumbnail != {} {platform.thumbnail_destroy(&d.thumbnail)}
	d.thumbnail_shown = false
}

// Puts the pane in the prepared window at the pointer and starts naming it there.
@(require_results)
pane_tear_off :: proc(app: ^App, source_window: ^Window, d: Pane_Drag) -> bool {
	preview := window_find(app, d.preview_window)
	if preview == nil {return false}
	x, y, screen_error := platform.window_to_screen(
		&app.platform,
		source_window.id,
		i32(d.pointer.x),
		i32(d.pointer.y),
	)
	if screen_error != .None {return false}
	place_error := platform.window_place_on_monitor(
		&app.platform,
		preview.id,
		x - i32(TEAR_OFF_GRAB_X * preview.scale),
		y - i32(TEAR_OFF_GRAB_Y * preview.scale),
	)
	if place_error != .None {return false}
	dpi := platform.window_dpi(&app.platform, preview.id)
	if dpi != 0 && f32(dpi) / 96 != preview.scale {window_set_dpi(app, preview, dpi)}
	width, height, size_error := platform.window_client_size(&app.platform, preview.id)
	if size_error != .None {return false}
	if width != preview.width || height != preview.height {window_resize(app, preview, width, height)}
	if !pane_to_window(app, source_window, d.source, d.node, preview.id) {return false}
	workspace_name_begin(app, preview)
	return true
}

@(require_results)
pane_to_window :: proc(
	app: ^App,
	source_window: ^Window,
	source: ^Tab,
	node: layout.Node_Id,
	preview_id: platform.Window_Id,
) -> bool {
	preview := window_find(app, preview_id)
	home, linked, found := pane_link_origin(app, source, node)
	if !found {return false}
	workspace := home.workspace
	if preview == nil ||
	   !preview.preparing ||
	   workspace == nil ||
	   !(source_window.workspace == workspace ||
			   (source_window.linked && source_window.link_workspace == workspace.id)) ||
	   !pane_window_source_allows(workspace) {
		return false
	}
	if !linked && !pane_link_tab_can_lose(home.tab) {return false}
	pane, valid := workspace_pane_at(
		app,
		workspace,
		tab_index_by_id(workspace, home.tab.id),
		home.node,
	)
	destination := selected_tab(preview.workspace)
	if !valid ||
	   destination == nil ||
	   destination.tree.nodes[destination.tree.root].(layout.Pane).content !=
		   pane.content {return false}
	layout_pane := home.tab.tree.nodes[home.node].(layout.Pane)
	// A pane that leaves its slot joins an ordinary window, where it must be shown.
	layout_pane.linked = false
	area := window_content_area(app, preview)
	panes := [?]layout.Pane_Rect{{content = pane.content, rect = area}}
	if !pane_minimum_allows(app, preview, panes[:], nil, notify_failure = true) {return false}
	name := workspace_default_name(app)
	if name == "" {return false}
	was_linked := source_window.linked
	move := pane_move_begin(app, preview, home.tab, workspace)
	if !layout.remove(&home.tab.tree, home.node) {
		delete(name)
		pane_move_abort(app, move)
		return false
	}
	destination.tree.nodes[destination.tree.root] = layout_pane
	destination.tree.next_pane_order = layout_pane.order
	preview.preparing = false
	preview.workspace.provisional = false
	preview.workspace.name = name
	workspace_pickers_refresh(app)
	pane_move_finish(app, move, destination)
	if was_linked {pane_link_refresh_source(app, source_window, pane.content)}
	if !window_show_prepared(app, preview) {return false}
	_ = window_activate(app, preview)
	return true
}
