package main

import "aio:input"
import "aio:layout"
import "aio:platform"
import "core:log"
import "core:math"
import "core:strings"

@(private = "file")
DRAG_THUMBNAIL_WIDTH :: f32(300)
@(private = "file")
DRAG_THUMBNAIL_HEIGHT :: f32(190)
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

pane_window_preview_discard :: proc(app: ^App, id: input.Window_Id) {
	preview := window_find(app, id)
	if preview == nil || preview.phase != .Preparing {return}
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
	name := home.node == home.tab.tree.root ? home.tab.name : ""
	preview := window_preview_prepare(app, pane.content, name)
	if preview == nil {return nil}
	area := window_content_area(app, preview)
	panes := [?]layout.Pane_Rect{{content = pane.content, rect = area}}
	if !pane_minimum_allows(app, preview, panes[:], nil, notify_failure = false) {
		pane_window_preview_discard(app, preview.id)
		return nil
	}
	return preview
}

// The hidden window a tear-off lands in, showing one tab that borrows `content` until the drop commits.
@(require_results)
window_preview_prepare :: proc(app: ^App, content: layout.Content, tab_name: string) -> ^Window {
	workspace := workspace_create_empty(app, true)
	if workspace == nil {return nil}
	success := false
	defer if !success {pane_preview_workspace_discard(app, workspace)}
	tab, record_error := tab_record_reserve(workspace)
	if record_error != .None {return nil}
	if layout.init(&tab.tree, content) != nil {tab_record_free(tab); return nil}
	if tab_name != "" {
		name, name_error := strings.clone(tab_name)
		if name_error != nil {tab_record_free(tab); return nil}
		tab.name = name
	}
	tab_record_commit(app, workspace, tab)
	preview := window_prepare(app, workspace)
	if preview == nil {return nil}
	workspace_pickers_refresh(app)
	success = true
	return preview
}

// A small live picture of what a drag would carry into a new window.
Drag_Thumbnail :: struct {
	image:         platform.Thumbnail,
	width, height: i32,
	shown, failed: bool,
}

// Shows the thumbnail of `region` at the pointer, or hides it when the drop would not open a window.
// A thumbnail that cannot be made costs only the picture: the tear-off still works.
drag_thumbnail_sync :: proc(
	app: ^App,
	w: ^Window,
	t: ^Drag_Thumbnail,
	region: layout.Rect,
	shown: bool,
	x, y: i32,
) {
	if !shown {
		if t.shown {platform.thumbnail_hide(t.image)}
		t.shown = false
		return
	}
	if t.image == {} && !t.failed {
		t.failed = !drag_thumbnail_create(app, w, t, region)
	}
	if t.image == {} {return}
	offset := i32(math.round(16 * w.scale))
	platform.thumbnail_place(t.image, x + offset, y + offset)
	t.shown = true
}

@(private = "file")
drag_thumbnail_create :: proc(app: ^App, w: ^Window, t: ^Drag_Thumbnail, r: layout.Rect) -> bool {
	if r.width <= 0 || r.height <= 0 {return false}
	fit := min(DRAG_THUMBNAIL_WIDTH * w.scale / r.width, DRAG_THUMBNAIL_HEIGHT * w.scale / r.height, 1)
	width, height := max(1, i32(r.width * fit)), max(1, i32(r.height * fit))
	image, err := platform.thumbnail_create(
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
	t.image, t.width, t.height = image, width, height
	return true
}

drag_thumbnail_destroy :: proc(t: ^Drag_Thumbnail) {
	if t.image != {} {platform.thumbnail_destroy(&t.image)}
	t.shown = false
}

// What a drag's pointer is over: the app window that would take a drop, if any, in its own coordinates.
Drag_Point :: struct {
	window:             ^Window,
	screen_x, screen_y: i32,
	x, y:               i32,
}

@(require_results)
drag_point :: proc(app: ^App, w: ^Window, x, y: f32) -> (point: Drag_Point, ok: bool) {
	sx, sy, screen_error := platform.window_to_screen(&app.platform, w.id, i32(x), i32(y))
	if screen_error != .None {return {}, false}
	id, tx, ty, hit_error := platform.window_at_point(&app.platform, sx, sy)
	if hit_error != .None {return {}, false}
	destination := window_find(app, id)
	// Controller-driven client events may be delivered to an inactive, occluded source.
	if app.options.inactive &&
	   destination == nil &&
	   x >= 0 &&
	   y >= 0 &&
	   x < f32(w.width) &&
	   y < f32(w.height) {
		destination, tx, ty = w, i32(x), i32(y)
	}
	if destination != nil && destination.phase == .Preparing {destination = nil}
	return {destination, sx, sy, tx, ty}, true
}

// Moves a prepared window so the pointer rests on its title bar, settled to the monitor it landed on.
@(require_results)
window_place_at_pointer :: proc(app: ^App, preview, source_window: ^Window, pointer: [2]f32) -> bool {
	x, y, screen_error := platform.window_to_screen(
		&app.platform,
		source_window.id,
		i32(pointer.x),
		i32(pointer.y),
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
	return true
}

pane_drag_thumbnail_sync :: proc(
	app: ^App,
	w: ^Window,
	a: ^Drag_Active,
	carry: ^Pane_Carry,
	shown: bool,
	x, y: i32,
) {
	region: layout.Rect
	for pane in w.panes {if pane.node == carry.node {region = pane.rect; break}}
	drag_thumbnail_sync(app, w, &a.thumbnail, region, shown, x, y)
}

// Moves the pane into the prepared window. Every step that can fail comes first, and the window shows before
// the pane leaves its tab, so a failure leaves the source as it was and the preview still prepared.
@(require_results)
pane_to_window :: proc(
	app: ^App,
	source_window: ^Window,
	source: ^Tab,
	node: layout.Node_Id,
	preview_id: input.Window_Id,
) -> bool {
	preview := window_find(app, preview_id)
	home, linked, found := pane_link_origin(app, source, node)
	if !found {return false}
	workspace := home.workspace
	if preview == nil ||
	   preview.phase != .Preparing ||
	   workspace == nil ||
	   !(source_window.workspace == workspace ||
			   window_link_workspace(source_window) == workspace.id) ||
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
	// The preview is still Preparing here, so the move leaves only the windows that were live.
	move := pane_move_begin(app, preview, home.tab, workspace)
	if !window_commit(app, preview) {
		delete(name)
		pane_move_enter(app, move)
		return false
	}
	was_linked := window_linked(source_window)
	// The node was checked to be a pane above, which is all a removal needs.
	removed := layout.remove(&home.tab.tree, home.node)
	assert(removed)
	destination.tree.nodes[destination.tree.root] = layout_pane
	destination.tree.next_pane_order = layout_pane.order
	preview.workspace.provisional = false
	preview.workspace.name = name
	workspace_pickers_refresh(app)
	pane_move_finish(app, move, destination)
	if was_linked {pane_link_refresh_source(app, source_window, pane.content)}
	_ = window_activate(app, preview)
	return true
}
