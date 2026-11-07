package main

import "aio:input"
import "aio:layout"
import "aio:platform"
import "core:log"
import "core:math"
import "core:strings"

// The window side of a tear-off, shared by pane and tab drags (drag.odin's tear_off_* state picks
// when): the hidden preview window the drop lands in, the thumbnail that follows the pointer, where the
// pointer is among the app's windows, placing the preview and showing it as the drop commits.

@(private = "file")
DRAG_THUMBNAIL_WIDTH :: f32(300)
@(private = "file")
DRAG_THUMBNAIL_HEIGHT :: f32(190)
// The drop places the new window so the pointer rests on its title bar.
@(private = "file")
TEAR_OFF_GRAB_X :: f32(160)
@(private = "file")
TEAR_OFF_GRAB_Y :: f32(20)

// The hidden window a tear-off lands in, showing one tab that borrows `content` until the drop commits.
@(require_results)
window_preview_prepare :: proc(app: ^App, content: layout.Content, tab_name: string) -> ^Window {
	workspace := workspace_create_empty(app, true)
	if workspace == nil {return nil}
	success := false
	defer if !success {preview_workspace_discard(app, workspace)}
	tab, reserved := tab_record_reserve(workspace)
	if !reserved {return nil}
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

// Closes a preview the drop did not take, with its provisional workspace.
window_preview_discard :: proc(app: ^App, id: input.Window_Id) {
	preview := window_find(app, id)
	if preview == nil || preview.phase != .Preparing {return}
	workspace_id := preview.workspace.id
	window_close(app, preview)
	if workspace := workspace_find(app, workspace_id); workspace != nil && workspace.provisional {
		preview_workspace_discard(app, workspace)
	}
}

// Preview tabs borrow their source runtime; discarding one must never close its session.
@(private = "file")
preview_workspace_discard :: proc(app: ^App, workspace: ^Workspace) {
	for tab in workspace.tabs {tab_record_free(tab)}
	clear(&workspace.tabs)
	if !workspace_discard_empty(app, workspace) {
		log.error("discarding the pane preview workspace failed")
	}
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
	return window_sync_placement(app, preview)
}

// The step every tear-off commit takes before anything moves: the preview shows, so its window owns what
// arrives next. `name`, the one its workspace will take, is the caller's to keep on success; a failure
// frees it and leaves the preview prepared.
@(require_results)
tear_off_window_show :: proc(app: ^App, preview: ^Window, name: string) -> bool {
	if window_commit(app, preview) {return true}
	delete(name)
	return false
}

// A committed tear-off's workspace becomes an ordinary listed one, owning its suggested `name`.
window_preview_publish :: proc(preview: ^Window, name: string) {
	preview.workspace.provisional = false
	preview.workspace.name = name
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

// The native frame takes the accent as 8-bit RGB, which is the theme's own value before drawing
// converts it.
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
	if activation_suppressed(app) &&
	   destination == nil &&
	   x >= 0 &&
	   y >= 0 &&
	   x < f32(w.width) &&
	   y < f32(w.height) {
		destination, tx, ty = w, i32(x), i32(y)
	}
	// The preview is under the pointer while it follows the drag, but it is no drop target yet.
	if destination != nil && destination.phase == .Preparing {destination = nil}
	return {destination, sx, sy, tx, ty}, true
}
