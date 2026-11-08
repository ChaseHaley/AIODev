package main

import "aio:platform"
import "aio:ui"
import "core:time"

// Every animated part of a window, once. Each feature advances its own animation and says whether it
// still moves; update_motion and motion_active only compose them. A part added here must be named by
// both switches below, so nothing can animate without keeping the loop awake, or the reverse.
@(private = "file")
Window_Motion :: enum u8 {
	Workspace_Picker,
	Title_Controls,
	Rail,
	Tabs,
	Pane_Drag,
	Settings_Profiles,
	Pane_Headers,
	Float_Header,
	Find,
	Confirmation,
}

// Advances one part to `now`; true when the window must draw again.
@(private = "file")
window_motion_advance :: proc(app: ^App, w: ^Window, part: Window_Motion, now: time.Tick) -> bool {
	switch part {
	case .Workspace_Picker:
		return workspace_picker_animate(app, w, now)
	case .Title_Controls:
		return title_controls_animate(app, w, now)
	case .Rail:
		return rail_slide_update(w, now)
	case .Tabs:
		return tab_presentation_animate(app, w, now)
	case .Pane_Drag:
		// It marks the window itself.
		pane_drag_animate(app, w, app.animations, now)
	case .Settings_Profiles:
		return ui.editor_profiles_animate(&w.editor, app.animations, now)
	case .Pane_Headers:
		return pane_header_controls_animate(app, w, now)
	case .Float_Header:
		return floating_header_animate(app, w, now)
	case .Find:
		return ui.find_is_open(&w.find) && ui.find_animate(&w.find, app.animations, now)
	case .Confirmation:
		confirmation_advance(app, w, now)
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
	case .Confirmation:
		return confirmation_active(w)
	}
	return false
}

motion_active :: proc(app: ^App) -> bool {
	if palette_animating(app) || ui.notices_animating(&app.notices) {return true}
	for w in app.windows {
		for part in Window_Motion {
			if window_motion_running(w, part) {return true}
		}
	}
	return false
}

update_motion :: proc(app: ^App) {
	now := time.tick_now()
	palette_animate(app, now)
	if ui.notices_animate(&app.notices, app.animations, now) {mark_all_dirty(app)}
	for w in app.windows {
		for part in Window_Motion {
			if window_motion_advance(app, w, part, now) {w.dirty = true}
		}
	}
}

refresh_animations :: proc(app: ^App) {
	enabled := platform.client_animations_enabled()
	if app.animations == enabled {return}
	app.animations = enabled
	// Without animations every notice snaps to the end of its motion at once.
	if !enabled {_ = ui.notices_animate(&app.notices, false, time.tick_now())}
	mark_all_dirty(app)
}
