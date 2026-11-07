package main

import "aio:layout"
import "aio:platform"
import "aio:ui"
import "core:time"

motion_active :: proc(app: ^App) -> bool {
	if palette_owner_id(app) != 0 && ui.presence_active(app.palette.presence) {return true}
	if ui.notices_animating(&app.notices) {return true}
	for w in app.windows {
		if workspace_picker_active(&w.workspace_picker) {
			if workspace_order_animating(&w.workspace_picker) {return true}
			if ui.motion_active(w.workspace_picker.rename_motion) ||
			   ui.control_active(w.workspace_picker.menu_motion) {
				return true
			}
		}
		if rail_sliding(w) ||
		   ui.motion_active(w.tab_underline) ||
		   ui.motion_active(w.tab_incoming.ghost) ||
		   confirmation_active(w) { return true }
		if ui.control_active(w.workspace_motion) || ui.control_active(w.float_header_motion) { return true }
		for control in w.float_header_controls { if ui.control_active(control) { return true } }
		if ui.find_is_open(&w.find) && ui.find_animating(&w.find) { return true }
		for control in w.tab_controls { if ui.control_active(control) { return true } }
		if ui.control_active(w.new_tab_control) || ui.control_active(w.profiles_control) { return true }
		for position in w.tab_positions { if ui.motion_active(position) { return true } }
		if pane_drag_animating(w) { return true }
		if ui.editor_profiles_animating(&w.editor) { return true }
		if w.header_height > 0 || w.split_overlay || window_floats_shown(w) {
			for pane in w.views {for control in pane.header_controls {if ui.control_active(control) {return true}}}
		}
	}
	return false
}

update_motion :: proc(app: ^App) {
	now := time.tick_now()
	p := &app.palette
	palette_changed, palette_settled := ui.presence_advance(&p.presence, app.animations, now)
	if owner := palette_owner_window(app); owner != nil {
		if palette_changed {owner.dirty = true}
		if palette_settled {palette_release(app, owner)}
	}
	notices_changed := ui.notices_animate(&app.notices, now)
	if notices_changed {mark_all_dirty(app)}
	for w in app.windows {
		p := &w.workspace_picker
		if workspace_order_animate(w, app.animations, now) {w.dirty = true}
		if ui.control_update(&w.workspace_motion, w.workspace_hovered, false, app.animations, now) {
			w.dirty = true
		}
		if workspace_row_rename_animate(w, app.animations, now) { w.dirty = true }
		hovered := p.menu_hover != 0 && workspace_row_index(w, p.menu_hover) >= 0
		if ui.control_update(&p.menu_motion, hovered, false, app.animations, now) { w.dirty = true }
		rail_changed := rail_slide_update(w, now)
		tabs_changed := false
		// D-069: dragged tabs follow the pointer (tab_drag_follow_pointer); the others, and every tab once
		// dropped, settle into their slots, opening the gap another window's drag asks for.
		following := tab_drag_active(w)
		for &position, i in w.tab_positions {
			if i >= len(w.workspace.tabs) {continue}
			if !following || !w.workspace.tabs[i].marked {
				gap := i >= w.tab_incoming.slot ? w.tab_incoming.count : 0
				ui.motion_target(
					&position,
					f32(i + gap),
					TAB_REORDER_DURATION,
					.Decelerate,
					app.animations,
					now,
				)
			}
			tabs_changed = ui.motion_update(&position, now) || tabs_changed
		}
		tabs_changed = ui.motion_update(&w.tab_incoming.ghost, now) || tabs_changed
		ui.motion_target(
			&w.tab_underline,
			f32(w.workspace.selected),
			140 * time.Millisecond,
			.Decelerate,
			app.animations,
			now,
		)
		for &control, i in w.tab_controls {
			tabs_changed = strip_control_update(app, w, &control, Tab_Chrome_Tab{i}, now) || tabs_changed
		}
		tabs_changed = strip_control_update(app, w, &w.new_tab_control, Tab_Chrome_New{}, now) || tabs_changed
		tabs_changed =
			strip_control_update(app, w, &w.profiles_control, Tab_Chrome_Profiles{}, now) || tabs_changed
		tabs_changed = ui.motion_update(&w.tab_underline, now) || tabs_changed
		pane_drag_animate(app, w, app.animations, now)
		if ui.editor_profiles_animate(&w.editor, app.animations, now) {w.dirty = true}
		controls_changed := false
		if w.header_height > 0 || w.split_overlay || window_floats_shown(w) {
			for &pane in w.views {
				for &control, button in pane.header_controls {
					controls_changed =
						ui.control_update(
							&control,
							pane.header_hover == button,
							ui.armed_is(pane.header_armed, button),
							app.animations,
							now,
						) ||
						controls_changed
				}
			}
		}
		// The float header under the pointer, or the one moving its float, takes the animation; a header
		// the pointer left keeps it while it fades.
		header := layout.INVALID_NODE
		spot, spotted := w.float_header_hover.?
		if spotted {header = spot.root}
		held, moving := floating_header_held(w)
		if moving {
			tree := window_tree(w)
			header = layout.float_root(tree, layout.find_content(tree, held))
		}
		if header != layout.INVALID_NODE {w.float_header_shown = header}
		active := header != layout.INVALID_NODE
		changed := ui.control_update(&w.float_header_motion, active, moving, app.animations, now)
		for &control, i in w.float_header_controls {
			action := FLOAT_HEADER_BUTTONS[i].action
			over := spotted && spot.action == action
			pressed := floating_button_pressed(w, action)
			changed = ui.control_update(&control, over, pressed, app.animations, now) || changed
		}
		if changed {w.dirty = true}
		if ui.find_is_open(&w.find) && ui.find_animate(&w.find, app.animations, now) {w.dirty = true}
		confirmation_advance(app, w, now)
		if rail_changed || tabs_changed || controls_changed {w.dirty = true}
	}
}

// A strip control hovers while the pointer is over it, and draws a held strip press while it hovers.
@(private = "file")
strip_control_update :: proc(
	app: ^App,
	w: ^Window,
	control: ^ui.Control_Motion,
	target: Tab_Chrome_Target,
	now: time.Tick,
) -> bool {
	hovered := w.tabs_horizontal && w.tab_hover == target
	return ui.control_update(control, hovered, hovered && gesture_tab_pressed(w) != nil, app.animations, now)
}

refresh_animations :: proc(app: ^App) {
	enabled := platform.client_animations_enabled()
	if app.animations == enabled {return}
	app.animations = enabled
	ui.notices_set_animations(&app.notices, enabled)
	mark_all_dirty(app)
}
