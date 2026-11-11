package main

import "aio:platform"
import "aio:render"
import "aio:ui"

// Every animated part of a window, once. Each feature advances its own animation and says whether it
// still moves; window_motion_update and window_animating only compose them. A part added here must be
// named by both switches below, so nothing can animate without keeping the loop awake, or the reverse.
@(private = "file")
Window_Motion :: enum u8 {
	Workspace_Picker,
	Title_Controls,
	Rail,
	Tabs,
	Panes,
	Workspace_Overview,
	Pane_Drag,
	Settings_Profiles,
	Pane_Headers,
	Float_Header,
	Find,
	Cursor,
	Field_Carets,
	Confirmation,
}

// Advances one part to `frame`; true when the window must draw again.
@(private = "file")
window_motion_advance :: proc(app: ^App, w: ^Window, part: Window_Motion, frame: ui.Frame_Time) -> bool {
	switch part {
	case .Workspace_Picker:
		return workspace_picker_animate(app, w, frame)
	case .Title_Controls:
		return title_controls_animate(app, w, frame)
	case .Rail:
		return rail_slide_update(w, frame)
	case .Tabs:
		return tab_presentation_animate(app, w, frame)
	case .Panes:
		return pane_motion_animate(app, w, frame)
	case .Workspace_Overview:
		return workspace_overview_animate(app, w, frame)
	case .Pane_Drag:
		// It marks the window itself.
		pane_drag_animate(app, w, app.animations, frame)
	case .Settings_Profiles:
		return ui.editor_profiles_animate(&w.editor, app.animations, frame)
	case .Pane_Headers:
		return pane_header_controls_animate(app, w, frame)
	case .Float_Header:
		return floating_header_animate(app, w, frame)
	case .Find:
		return ui.find_is_open(&w.find) && ui.find_animate(&w.find, app.animations, frame)
	case .Cursor:
		return cursor_motion_animate(app, w, frame)
	case .Field_Carets:
		// Carets move as their fields draw; a window that cannot draw lets them land.
		if _, failed := w.surface.(Surface_Failed); failed || !window_drawable(w) {w.carets.moving = false}
		return w.carets.moving
	case .Confirmation:
		confirmation_advance(app, w, frame)
	}
	return false
}

@(private = "file")
window_motion_running :: proc(w: ^Window, part: Window_Motion) -> bool {
	switch part {
	case .Workspace_Picker:
		return workspace_picker_animating(w)
	case .Title_Controls:
		return title_controls_animating(w)
	case .Rail:
		return rail_sliding(w)
	case .Tabs:
		return tab_presentation_animating(w)
	case .Panes:
		return pane_motion_animating(w)
	case .Workspace_Overview:
		return workspace_overview_animating(w)
	case .Pane_Drag:
		return pane_drag_animating(w)
	case .Settings_Profiles:
		return ui.editor_profiles_animating(&w.editor)
	case .Pane_Headers:
		return pane_header_controls_animating(w)
	case .Float_Header:
		return floating_header_animating(w)
	case .Find:
		return ui.find_is_open(&w.find) && ui.find_animating(&w.find)
	case .Cursor:
		return cursor_motion_animating(w)
	case .Field_Carets:
		return w.carets.moving
	case .Confirmation:
		return confirmation_active(w)
	}
	return false
}

// When the window's next frame will be on screen. Motion is sampled there, by the frame itself and by
// any event handler that settles a motion early, so both see the same instant. A window that cannot
// present has no next frame; its motion runs on the assumed refresh so it still settles.
window_frame_time :: proc(app: ^App, w: ^Window) -> ui.Frame_Time {
	now := clock_now(&app.clock)
	surface := window_surface(w)
	if surface == nil || !window_drawable(w) {return render.frame_time_at(now)}
	return render.frame_predict(surface, now)
}

// Advances everything that moves in w to `frame`, the palette and the notices too when w draws them;
// true, and w marked dirty, when w must draw again.
window_motion_update :: proc(app: ^App, w: ^Window, frame: ui.Frame_Time) -> bool {
	changed := false
	if palette_owner_id(app) == w.id {changed = palette_animate(app, frame) || changed}
	if app.notice_window == w.id && ui.notices_animate(&app.notices, app.animations, frame) {
		mark_all_dirty(app)
		changed = true
	}
	for part in Window_Motion {
		if window_motion_advance(app, w, part, frame) {changed = true}
	}
	if changed {w.dirty, w.frame_moved = true, true}
	return changed
}

// Something w draws is still moving, so w wants every frame the display offers.
window_animating :: proc(app: ^App, w: ^Window) -> bool {
	if palette_owner_id(app) == w.id && palette_animating(app) {return true}
	if app.notice_window == w.id && ui.notices_animating(&app.notices) {return true}
	for part in Window_Motion {
		if window_motion_running(w, part) {return true}
	}
	return false
}

// Notices with no window to draw them still finish their motion, on the assumed refresh.
@(private)
notices_unshown :: proc(app: ^App) -> bool {
	return window_find(app, app.notice_window) == nil
}

// Something moves anywhere: housekeeping that would hold the main thread waits for it, and the harness
// reports it as ui.animating.
motion_active :: proc(app: ^App) -> bool {
	if notices_unshown(app) && ui.notices_animating(&app.notices) {return true}
	for w in app.windows {
		if window_animating(app, w) {return true}
	}
	return false
}

// Advances every window's motion to its next frame without drawing it, once per loop iteration: events
// retarget motion without drawing, and windows that cannot present still finish theirs and release what
// they hold. A window that then draws samples the same instant again, so this changes nothing it shows.
update_motion :: proc(app: ^App) {
	frame := render.frame_time_at(clock_now(&app.clock))
	if notices_unshown(app) && ui.notices_animate(&app.notices, app.animations, frame) {
		mark_all_dirty(app)
	}
	for w in app.windows {_ = window_motion_update(app, w, window_frame_time(app, w))}
}

refresh_animations :: proc(app: ^App) {
	enabled := platform.client_animations_enabled()
	if app.animations == enabled {return}
	app.animations = enabled
	// Without animations every notice snaps to the end of its motion at once.
	if !enabled {_ = ui.notices_animate(&app.notices, false, render.frame_time_at(clock_now(&app.clock)))}
	mark_all_dirty(app)
}
