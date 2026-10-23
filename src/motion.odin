package main

import "aio:platform"
import "aio:ui"
import "core:time"

motion_active :: proc(app: ^App) -> bool {
	if app.palette_window != 0 && ui.presence_active(app.palette.presence) {return true}
	if ui.notices_animating(&app.notices) {return true}
	for w in app.windows {
		if workspace_picker_active(&w.workspace_picker) && ui.motion_active(w.workspace_picker.rename_motion) { return true }
		if ui.motion_active(w.tab_underline) || ui.presence_active(w.pending_close.confirm.presence) { return true }
		for control in w.tab_controls { if ui.control_active(control) { return true } }
		for position in w.tab_positions { if ui.motion_active(position) { return true } }
		if pane_drag_animating(w) { return true }
		if w.header_height > 0 || w.split_overlay {
			for pane in w.views {for control in pane.header_controls {if ui.control_active(control) {return true}}}
		}
	}
	return false
}

update_motion :: proc(app: ^App) {
	now := time.tick_now()
	p := &app.palette
	palette_changed, palette_settled := ui.presence_advance(&p.presence, app.animations, now)
	if owner := window_find(app, app.palette_window); owner != nil {
		if palette_changed {owner.dirty = true}
		if palette_settled {palette_release(app, owner)}
	}
	notices_changed := ui.notices_animate(&app.notices, now)
	if notices_changed {mark_all_dirty(app)}
	for w in app.windows {
		p := &w.workspace_picker
		if p.mode == .Rename {
			ui.motion_target(&p.rename_motion, 1, 140*time.Millisecond, .Decelerate, app.animations, now)
			if ui.motion_update(&p.rename_motion, now) { w.dirty = true }
		}
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
		c := &w.pending_close.confirm
		confirm_changed, _ := ui.presence_advance(&c.presence, app.animations, now)
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
