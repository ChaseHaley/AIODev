package main

import "cosmos:render"
import "aio:settings"
import "aio:views"
import "core:math"
import "cosmos:ui"

// Moving the Activity panel to the other side. Beside a docked rail it slides down out of the rail and in
// from the window's right edge, or the reverse, while the panes ease. With no docked rail, the panes and
// the panel turn as one band around the window, as if it were a cylinder: whatever passes one side comes
// in at the other, pixel for pixel, until the panel stands on its new side and the panes where it was.
// The band is everything right of the window's left margin, since the margin left of the panel on one
// side is the gap right of the panes on the other. The layout takes the new side at once, and the band is
// drawn turned back by what remains. Window embeds it; only this file writes it.
Panel_Wrap :: struct {
	// Eases from 1 to 0; the band draws `wrap_shift` times it to the right of the layout.
	wrap:         ui.Motion,
	wrap_shift:   f32,
	// The band's width, across which what leaves one side comes back in at the other.
	wrap_period:  f32,
	// A copy of what the band drew, which draws again a period away.
	wrap_scratch: render.Draw_List,
	// The side the window last laid the panel out on.
	panel_side:   settings.Status_Panel_Side,
}

panel_wrap_destroy :: proc(w: ^Window) {
	render.draw_list_destroy(&w.wrap_scratch)
}

panel_wrap_animate :: proc(w: ^Window, frame: ui.Frame_Time) -> bool {
	return ui.motion_update(&w.wrap, frame)
}

panel_wrap_animating :: proc(w: ^Window) -> bool {
	return ui.motion_active(w.wrap)
}

// Starts the panel toward the side the settings now give it, when it moved and the window has drawn it.
// Call it before the relayout that places the new side.
panel_side_apply :: proc(app: ^App, w: ^Window) {
	side := app.settings.status.panel_side
	defer w.panel_side = side
	if side == w.panel_side || !pane_motion_has_drawn(w) || !status_panel_visible(app, w) {return}
	motion := settings.motion_resolve(&app.settings, .Chrome)
	duration := settings.motion_duration(&app.settings, motion)
	if !app.animations || !motion.on || duration <= 0 {return}
	if rail_docked(w) {
		pane_motion_arm_chrome(w, {panel_leaves = true})
		return
	}
	width := status_panel_dock_width(app, w)
	if width <= 0 {return}
	top := window_title_height(w)
	margin := views.pane_area(f32(w.width), f32(w.height), top, f32(app.settings.pane.gap), w.scale).x
	// A turn still running continues from where it stands.
	shown := w.wrap_shift * w.wrap.value
	w.wrap_shift = shown + (side == .Right ? width : -width)
	w.wrap_period = f32(w.width) - margin
	w.wrap = {value = 1, target = 1}
	ui.motion_target_curve(&w.wrap, 0, duration, motion.curve, true)
}

// Turns what was drawn since `mark` around the band by what remains of the panel's move: drawn shifted
// along the band, and again a band's width the other way, each kept inside the band.
panel_wrap_draw :: proc(w: ^Window, mark: render.Draw_Mark) {
	if !panel_wrap_animating(w) || w.wrap_period <= 0 {return}
	offset := math.round(w.wrap_shift * w.wrap.value)
	if offset == 0 {return}
	top := window_title_height(w)
	band := render.Rect{f32(w.width) - w.wrap_period, top, w.wrap_period, max(0, f32(w.height) - top)}
	render.draw_list_reset(&w.wrap_scratch)
	copied := render.draw_list_copy(&w.wrap_scratch, &w.list, mark, render.draw_mark(&w.list)) == .None
	render.draw_translate(&w.list, mark, {offset, 0}, band)
	if !copied {return}
	again := render.draw_mark(&w.list)
	if render.append_list(&w.list, &w.wrap_scratch) != .None {return}
	render.draw_translate(&w.list, again, {offset - math.sign(offset) * w.wrap_period, 0}, band)
}
