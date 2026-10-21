package main

import "aio:platform"
import "aio:ui"
import "core:time"

motion_active :: proc(app: ^App) -> bool {
	if app.palette_window != 0 && ui.motion_active(app.palette.motion) {return true}
	if ui.notices_animating(&app.notices) {return true}
	for w in app.windows {
		if ui.motion_active(w.tab_underline) ||
		   ui.motion_active(w.close_confirm.motion) {return true}
		for control in w.tab_controls {if ui.control_active(control) {return true}}
		for position in w.tab_positions {if ui.motion_active(position) {return true}}
		if pane_drag_animating(w) {return true}
		if w.header_height > 0 || w.split_overlay {
			for pane in w.views {for control in pane.header_controls {if ui.control_active(control) {return true}}}
		}
	}
	return false
}

update_motion :: proc(app: ^App) {
	now := time.tick_now()
	p := &app.palette
	ui.motion_target(
		&p.motion,
		p.open ? 1 : 0,
		(p.open ? 120 : 90) * time.Millisecond,
		p.open ? .Decelerate : .Accelerate,
		app.animations,
		now,
	)
	palette_changed := ui.motion_update(&p.motion, now)
	if owner := window_find(app, app.palette_window); owner != nil {
		if palette_changed {owner.dirty = true}
		if !p.open && p.motion.value == 0 {palette_release(app, owner)}
	}
	notices_changed := ui.notices_animate(&app.notices, now)
	if notices_changed {mark_all_dirty(app)}
	for w in app.windows {
		positions_changed := false
		for &position, i in w.tab_positions {
			if !w.tab_drag.active || !w.workspace.tabs[i].marked {
				ui.motion_target(
					&position,
					f32(i),
					140 * time.Millisecond,
					.Decelerate,
					app.animations,
					now,
				)
			}
			positions_changed = ui.motion_update(&position, now) || positions_changed
		}
		ui.motion_target(
			&w.tab_underline,
			f32(w.workspace.selected),
			140 * time.Millisecond,
			.Decelerate,
			app.animations,
			now,
		)
		controls_changed := false
		for &control, i in w.tab_controls {
			controls_changed =
				ui.control_update(
					&control,
					w.tab_hover == i,
					w.tab_pressed && w.tab_hover == i,
					app.animations,
					now,
				) ||
				controls_changed
		}
		pane_drag_animate(app, w, app.animations, now)
		if w.header_height > 0 || w.split_overlay {
			for &pane in w.views {
				for &control, i in pane.header_controls {
					controls_changed =
						ui.control_update(
							&control,
							pane.header_hover == ui.Header_Action(i + 1),
							pane.header_pressed == ui.Header_Action(i + 1),
							app.animations,
							now,
						) ||
						controls_changed
				}
			}
		}
		c := &w.close_confirm
		ui.motion_target(
			&c.motion,
			c.open ? 1 : 0,
			(c.open ? 120 : 90) * time.Millisecond,
			c.open ? .Decelerate : .Accelerate,
			app.animations,
			now,
		)
		confirm_changed := ui.motion_update(&c.motion, now)
		underline_changed := ui.motion_update(&w.tab_underline, now)
		if underline_changed ||
		   controls_changed ||
		   positions_changed ||
		   confirm_changed {w.dirty = true}
	}
}

refresh_animations :: proc(app: ^App) {
	enabled := platform.client_animations_enabled()
	if app.animations == enabled {return}
	app.animations = enabled
	ui.notices_set_animations(&app.notices, enabled)
	mark_all_dirty(app)
}
