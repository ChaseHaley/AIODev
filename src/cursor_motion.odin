package main

import "aio:term_view"
import "aio:ui"
import "core:time"

// Presets and tuning reach every terminal through the same style, including cached split panes.
// Windows' motion preference overrides the preset without changing the user's saved choice.
cursor_effects :: proc(app: ^App) -> term_view.Cursor_Effects {
	c := app.settings.cursor
	preset := term_view.Cursor_Preset.Off
	if app.animations {
		switch c.animation {
		case .Off:    preset = .Off
		case .Smooth: preset = .Smooth
		case .Smear:  preset = .Smear
		case .Trail:  preset = .Trail
		}
	}
	return {
		preset = preset,
		duration = time.Duration(c.animation_duration) * time.Millisecond,
		strength = f32(c.animation_strength) / 100,
		movement = c.animation_movement,
	}
}

// Only a shown pane with the keyboard keeps cursor motion alive. Clearing the view on loss of
// focus also prevents output accumulated while hidden from flying across the pane when it returns.
cursor_motion_animate :: proc(app: ^App, w: ^Window, frame: ui.Frame_Time) -> bool {
	changed := false
	enabled := app.animations && app.settings.cursor.animation != .Off &&
	           window_drawable(w) && cursor_visible(w)
	for &view in w.views {
		if view.content.kind != .Terminal {continue}
		focused := false
		if enabled {
			for pane in w.panes {
				if pane.content == view.content {
					focused = pane_has_keyboard(app, w, pane)
					break
				}
			}
		}
		moved := false
		if focused {
			moved = term_view.cursor_animate(&view.view, frame, true)
		} else {
			moved = term_view.cursor_animating(&view.view)
			term_view.cursor_reset(&view.view)
		}
		if moved {view.valid = false; changed = true}
	}
	return changed
}

cursor_motion_animating :: proc(w: ^Window) -> bool {
	if !window_drawable(w) {return false}
	for &view in w.views {
		if view.content.kind == .Terminal && term_view.cursor_animating(&view.view) {return true}
	}
	return false
}
