package main

import "aio:input"
import "aio:render"
import "aio:ui"

// Horizontal tab-strip geometry and drawing. The strip shares the 40 DIP title bar with the
// workspace chip and the caption controls, so both the tab bar and the controls end read the same
// layout. Vertical mode uses the rail instead.
window_tab_bar :: proc(app: ^App, w: ^Window) -> ui.Tab_Bar {
	if w.workspace == nil {return {}}
	left := workspace_button_width(w) + status_pill_width(app, w)
	return ui.tab_bar_layout(
		left,
		max(0, f32(w.width) - window_caption_reserve(w) - left),
		w.scale,
		len(w.workspace.tabs),
		w.tab_incoming.count,
	)
}

tab_chevron_rect :: proc(app: ^App, w: ^Window) -> render.Rect {
	bar := window_tab_bar(app, w)
	button := window_tab_new_rect(app, w)
	return {button.x + button.width, 0, bar.button_width, bar.height}
}

tab_position :: proc(w: ^Window, index: int) -> f32 {
	return index >= 0 && index < len(w.tab_positions) ? w.tab_positions[index].value : f32(index)
}

window_tab_rect :: proc(app: ^App, w: ^Window, index: int) -> render.Rect {
	bar := window_tab_bar(app, w)
	if index < 0 || index >= bar.count {return {}}
	return {
		bar.x + tab_position(w, index) * bar.tab_width,
		0,
		bar.tab_width,
		bar.height,
	}
}

window_tab_new_rect :: proc(app: ^App, w: ^Window) -> render.Rect {
	return ui.tab_new_rect(window_tab_bar(app, w))
}

window_tab_close_rect :: proc(app: ^App, w: ^Window, index: int) -> render.Rect {
	return ui.tab_close_rect(window_tab_bar(app, w), index, tab_position(w, index), w.scale)
}

window_tab_hit :: proc(app: ^App, w: ^Window, bar: ui.Tab_Bar, x, y: f32) -> Tab_Chrome_Target {
	if x < bar.x || x >= bar.x + bar.width || y < 0 || y >= bar.height {return nil}
	for pass in 0 ..< 2 {
		for i := bar.count - 1; i >= 0; i -= 1 {
			foreground := tab_drag_active(w) && w.workspace.tabs[i].marked
			if foreground != (pass == 0) {continue}
			r := window_tab_rect(app, w, i)
			if x >= r.x && x < r.x + r.width {return Tab_Chrome_Tab{i}}
		}
	}
	if bar.count > 0 && render.rect_contains(ui.tab_new_rect(bar), x, y) {return Tab_Chrome_New{}}
	return nil
}

window_tab_close_hit :: proc(app: ^App, w: ^Window, bar: ui.Tab_Bar, x, y: f32) -> int {
	tab, ok := window_tab_hit(app, w, bar, x, y).(Tab_Chrome_Tab)
	if !ok {return -1}
	r := window_tab_close_rect(app, w, tab.index)
	if r.width > 0 && render.rect_contains(r, x, y) {return tab.index}
	return -1
}

strip_tab_interaction_hit :: proc(
	app: ^App,
	w: ^Window,
	x, y: f32,
	button: input.Mouse_Button,
) -> Tab_Interaction_Hit {
	bar := window_tab_bar(app, w)
	if y >= bar.height {return {}}
	chevron := tab_chevron_rect(app, w)
	if button == .Left && x >= chevron.x && x < chevron.x + chevron.width {
		anchor := [2]f32{x, chevron.y + chevron.height}
		return {target = Tab_Chrome_Profiles{}, inside = true, menu_anchor = anchor}
	}
	hit := Tab_Interaction_Hit{target = window_tab_hit(app, w, bar, x, y), inside = true}
	#partial switch _ in hit.target {
	case Tab_Chrome_New: hit.menu_anchor = {x, bar.height}
	case Tab_Chrome_Tab: hit.close = window_tab_close_hit(app, w, bar, x, y) >= 0
	}
	return hit
}

// The rightmost point the title chrome claims before the native caption buttons start.
window_title_controls_end :: proc(app: ^App, w: ^Window) -> f32 {
	if window_linked(w) {return 0}
	left := workspace_button_width(w) + status_pill_width(app, w)
	if !w.tabs_horizontal {
		toggle := tab_orientation_button_rect(w)
		return max(left, toggle.x + toggle.width)
	}
	bar := window_tab_bar(app, w)
	if bar.count == 0 {return max(left, bar.x + 2 * bar.button_width)}
	return max(left, bar.x + f32(bar.count) * bar.tab_width + 2 * bar.button_width)
}

@(private)
tab_control :: proc(w: ^Window, target: Tab_Chrome_Target) -> ui.Control_Motion {
	switch t in target {
	case Tab_Chrome_Tab:
		if t.index >= 0 && t.index < len(w.tab_controls) {return w.tab_controls[t.index]}
	case Tab_Chrome_New: return w.new_tab_control
	case Tab_Chrome_Profiles: return w.profiles_control
	}
	return {}
}

window_tab_strip_draw :: proc(app: ^App, w: ^Window) -> render.Build_Status {
	bar := window_tab_bar(app, w)
	if bar.count == 0 {return .Ok}
	dragging := tab_drag_active(w)
	for pass in 0 ..< (dragging ? 2 : 1) {
		foreground := pass == 1
		for tab, i in w.workspace.tabs {
			if (dragging && tab.marked) != foreground {continue}
			tile, built := tab_tile(app, w, i)
			if built != .Ok {return built}
			control := tab_control(w, Tab_Chrome_Tab{i})
			if result := ui.tab_draw(
				&w.list,
				&w.ui_text,
				app.theme,
				bar,
				i,
				tab_position(w, i),
				tile,
				control.hover.value,
				control.press.value,
				w.scale,
				w.pointer,
			); result != .Ok {return result}
		}
	}
	if render.push_layer(&w.list, {0, 0, f32(w.width), bar.height}) == .None {
		position := w.tab_underline.value
		moving := dragging
		for motion in w.tab_positions {moving ||= ui.motion_active(motion)}
		if moving {position = tab_position(w, w.workspace.selected)}
		// The selected tab rises with its hover, so its underline rises with it.
		lift := ui.hover_lift_at(
			app.theme,
			tab_control(w, Tab_Chrome_Tab{w.workspace.selected}).hover.value,
			w.scale,
		)
		underline := ui.tab_underline_rect(bar, position, lift, w.scale)
		if render.push_rect(
			   &w.list,
			   {
				   rect = underline,
				   color = app.theme.tab_indicator,
				   radius = ui.pill_radius(underline),
			   },
		   ) !=
		   .None {return .Ok}
	}
	drop, placed := pane_drag_destination(w).(Pane_Drop)
	if (placed && drop.place == .New_Tab) || w.tab_incoming.count > 0 {return .Ok}
	new_tab := tab_control(w, Tab_Chrome_New{})
	if result := ui.tab_new_draw(
		&w.list,
		app.theme,
		bar,
		new_tab.hover.value,
		new_tab.press.value,
		w.scale,
		w.pointer,
	); result != .Ok {return result}
	chevron := tab_chevron_rect(app, w)
	if render.push_layer(&w.list, chevron) != .None {return .Ok}
	control := tab_control(w, Tab_Chrome_Profiles{})
	_ = ui.icon_button_draw(
		&w.list,
		app.theme,
		ui.tab_tile_rect(bar, chevron.x, chevron.width, 0, w.scale),
		.Chevron_Down,
		control.hover.value,
		control.press.value,
		w.scale,
		w.pointer,
		ui.ICON_INDICATOR,
	)
	return .Ok
}

when AIO_CONTROL {
	tab_strip_state_report :: proc(r: ^State_Report, app: ^App, w: ^Window) {
		bar := window_tab_bar(app, w)
		state_text(r, "tabs.orientation", w.tabs_horizontal ? "horizontal" : "vertical")
		state_valuef(r, "tabs.width", "%g", bar.tab_width)
		state_valuef(r, "tabs.x", "%g", bar.x)
		state_valuef(r, "tabs.height", "%g", bar.height)
		state_rect(r, "tabs.new_tab", window_tab_new_rect(app, w))
		state_rect(r, "tabs.chevron", tab_chevron_rect(app, w))
	}
}
