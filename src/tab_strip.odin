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
	// Tabs share their width with any that a drag would add, without counting as tabs yet.
	bar := ui.tab_bar_layout(
		max(0, f32(w.width) - window_caption_reserve(w) - left),
		w.scale,
		len(w.workspace.tabs) + w.tab_incoming.count,
	)
	bar.count -= min(bar.count, w.tab_incoming.count)
	bar.x = left
	bar.height = ui.TITLE_BAR_HEIGHT * w.scale
	return bar
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
	bar := window_tab_bar(app, w)
	return {
		bar.x + f32(bar.count) * bar.tab_width,
		0,
		bar.button_width,
		bar.height,
	}
}

window_tab_close_rect :: proc(app: ^App, w: ^Window, index: int) -> render.Rect {
	bar := window_tab_bar(app, w)
	if index < 0 || index >= bar.count {return {}}
	r := ui.tab_close_rect(bar, index, w.scale)
	r.x += (tab_position(w, index) - f32(index)) * bar.tab_width
	return r
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
	if ui.tab_bar_hit_test(bar, x, y) == bar.count {return Tab_Chrome_New{}}
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
			title := tab_display_title(tab, i + 1)
			icon: string
			atlas := render.Rect{}
			if pane, terminal := workspace_focused_session_pane(app, w.workspace, i); terminal {
				result: render.Build_Status
				icon, atlas, result = pane_icon(app, pane.session, ui.ICON_BUTTON * w.scale)
				if result != .Ok {return result}
			}
			x := tab_position(w, i) * bar.tab_width
			status := status_tab_mark(app, w, w.workspace, i)
			if result := ui.tab_draw(
				&w.list,
				&w.ui_text,
				app.theme,
				bar,
				i,
				title,
				i == w.workspace.selected,
				w.scale,
				tab_control(w, Tab_Chrome_Tab{i}).hover.value,
				tab_control(w, Tab_Chrome_Tab{i}).press.value,
				0,
				x,
				tab_marked_shown(w, i),
				icon,
				atlas,
				w.pointer,
				status,
				status_phase(app, w, status),
				app.settings.status.enabled && app.settings.status.tab_indicators,
				tab_content_icon(tab),
			); result != .Ok {return result}
		}
	}
	if render.push_layer(&w.list, {0, 0, f32(w.width), bar.height}) == .None {
		x := bar.x + w.tab_underline.value * bar.tab_width + 10 * w.scale
		moving := dragging
		for position in w.tab_positions {moving ||= ui.motion_active(position)}
		if moving {x = bar.x + tab_position(w, w.workspace.selected) * bar.tab_width + 10 * w.scale}
		// The selected tab rises with its hover, so its underline rises with it.
		lift := ui.hover_lift_at(
			app.theme,
			tab_control(w, Tab_Chrome_Tab{w.workspace.selected}).hover.value,
			w.scale,
		)
		underline := render.Rect{x, 30 * w.scale - lift, max(0, bar.tab_width - 20 * w.scale), 2 * w.scale}
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
	if _, new_tab := drag_destination(w).(Drop_New_Tab); new_tab || w.tab_incoming.count > 0 {return .Ok}
	if result := ui.tab_draw(
		&w.list,
		&w.ui_text,
		app.theme,
		bar,
		bar.count,
		"",
		false,
		w.scale,
		tab_control(w, Tab_Chrome_New{}).hover.value,
		tab_control(w, Tab_Chrome_New{}).press.value,
		0,
		-1,
		false,
		"",
		{},
		w.pointer,
	); result != .Ok {return result}
	chevron := tab_chevron_rect(app, w)
	if render.push_layer(&w.list, chevron) != .None {return .Ok}
	control := tab_control(w, Tab_Chrome_Profiles{})
	hover := control.hover.value
	tile := render.Rect{chevron.x + 2 * w.scale, 6 * w.scale, chevron.width - 4 * w.scale, 28 * w.scale}
	_ = ui.icon_button_draw(
		&w.list,
		app.theme,
		tile,
		.Chevron_Down,
		hover,
		control.press.value,
		w.scale,
		w.pointer,
		ui.ICON_INDICATOR,
	)
	return .Ok
}
