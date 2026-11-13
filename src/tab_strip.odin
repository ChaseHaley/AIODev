package main

import "aio:input"
import "aio:render"
import "aio:settings"
import "aio:ui"

// settings is used only when AIO_CONTROL is set.
_ :: settings

// Horizontal tab-strip geometry and drawing. The strip shares the 40 DIP title bar with the
// workspace chip and the caption controls, so both the tab bar and the controls end read the same
// layout. Vertical mode uses the rail instead.
window_tab_bar :: proc(app: ^App, w: ^Window) -> ui.Tab_Bar {
	if w.workspace == nil {return {}}
	left := workspace_button_width(app, w)
	layout := tab_layout(app, w, true)
	return ui.tab_bar_layout(
		left,
		max(0, f32(w.width) - window_caption_reserve(w) - left),
		w.scale,
		len(w.workspace.tabs),
		w.tab_incoming.count,
		layout.slots,
		layout.chips * w.scale,
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

// Where tab `index` draws in the strip, following its motion.
tab_strip_x :: proc(w: ^Window, bar: ui.Tab_Bar, index: int) -> f32 {
	offset := index >= 0 && index < len(w.tab_offsets) ? w.tab_offsets[index].value : 0
	return bar.x + tab_position(w, index) * bar.tab_width + offset * w.scale
}

window_tab_rect :: proc(app: ^App, w: ^Window, index: int) -> render.Rect {
	return tab_strip_rect(w, window_tab_bar(app, w), index)
}

// Tab `index`'s rect in `bar`, so a caller holding the bar does not lay the strip out again.
tab_strip_rect :: proc(w: ^Window, bar: ui.Tab_Bar, index: int) -> render.Rect {
	if index < 0 || index >= bar.count {return {}}
	return {tab_strip_x(w, bar, index), 0, bar.tab_width, bar.height}
}

window_tab_new_rect :: proc(app: ^App, w: ^Window) -> render.Rect {
	return ui.tab_new_rect(window_tab_bar(app, w))
}

window_tab_close_rect :: proc(app: ^App, w: ^Window, index: int) -> render.Rect {
	return tab_strip_close_rect(w, window_tab_bar(app, w), index)
}

@(private = "file")
tab_strip_close_rect :: proc(w: ^Window, bar: ui.Tab_Bar, index: int) -> render.Rect {
	if index < 0 || index >= bar.count {return {}}
	return ui.tab_close_rect(bar, tab_strip_x(w, bar, index), w.scale)
}

window_tab_hit :: proc(app: ^App, w: ^Window, bar: ui.Tab_Bar, x, y: f32) -> Tab_Chrome_Target {
	if x < bar.x || x >= bar.x + bar.width || y < 0 || y >= bar.height {return nil}
	for pass in 0 ..< 2 {
		for i := bar.count - 1; i >= 0; i -= 1 {
			foreground := tab_drag_active(w) && w.workspace.tabs[i].marked
			if foreground != (pass == 0) || !tab_shown(w.workspace, i) {continue}
			r := tab_strip_rect(w, bar, i)
			if x >= r.x && x < r.x + r.width {return tab_chrome_tab(w, i)}
		}
	}
	for run in tab_layout(app, w, true).runs {
		chip := tab_chip_strip_rect(w, bar, run)
		if render.rect_contains(chip, x, y) {return Tab_Chrome_Group{run.group.id}}
	}
	if bar.count > 0 && render.rect_contains(ui.tab_new_rect(bar), x, y) {return Tab_Chrome_New{}}
	return nil
}

window_tab_close_hit :: proc(app: ^App, w: ^Window, bar: ui.Tab_Bar, x, y: f32) -> int {
	tab, ok := window_tab_hit(app, w, bar, x, y).(Tab_Chrome_Tab)
	if !ok {return -1}
	index := tab_index_by_id(w.workspace, tab.id)
	r := window_tab_close_rect(app, w, index)
	if r.width > 0 && render.rect_contains(r, x, y) {return index}
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
	case Tab_Chrome_Group: hit.menu_anchor = {x, bar.height}
	}
	return hit
}

// The rightmost point the title chrome claims before the native caption buttons start.
window_title_controls_end :: proc(app: ^App, w: ^Window) -> f32 {
	if window_linked(w) {return 0}
	left := workspace_button_width(app, w)
	if !w.tabs_horizontal {
		toggle := tab_orientation_button_rect(w)
		return max(left, toggle.x + toggle.width)
	}
	bar := window_tab_bar(app, w)
	return max(left, bar.end + 2 * bar.button_width)
}

@(private)
tab_control :: proc(w: ^Window, target: Tab_Chrome_Target) -> ui.Control_Motion {
	switch t in target {
	case Tab_Chrome_Tab:
		if entry := tab_control_find(&w.presentation, t.id); entry != nil {return entry.control}
	case Tab_Chrome_New: return w.new_tab_control
	case Tab_Chrome_Profiles: return w.profiles_control
	case Tab_Chrome_Group:
	}
	return {}
}

// The hover and press motion tab `index` of the window's workspace draws with in the strip.
tab_motion :: proc(w: ^Window, index: int) -> ui.Control_Motion {
	if index < 0 || index >= len(w.workspace.tabs) {return {}}
	return tab_control(w, tab_chrome_tab(w, index))
}

window_tab_strip_draw :: proc(app: ^App, w: ^Window) -> render.Build_Status {
	bar := window_tab_bar(app, w)
	if bar.count == 0 {return .Ok}
	dragging := tab_drag_active(w)
	runs := tab_layout(app, w, true).runs
	if render.push_layer(&w.list, {bar.x, 0, bar.width, bar.height}) == .None {
		for run in runs {
			if run.carried {continue}
			result := tab_chip_draw(app, w, run, tab_chip_strip_rect(w, bar, run))
			if result != .Ok {return result}
		}
	}
	// Tabs pulled out of a group ending the strip ride over the New Tab and profile buttons, which give way.
	pulled := false
	for tab, i in w.workspace.tabs {
		pulled ||= dragging && tab.marked && tab_strip_x(w, bar, i) + bar.tab_width > bar.end + w.scale
	}
	for pass in 0 ..< (dragging ? 2 : 1) {
		foreground := pass == 1
		if pulled && foreground {
			_ = render.push_layer(&w.list, {bar.x, 0, bar.end + 2 * bar.button_width - bar.x, bar.height})
		}
		for tab, i in w.workspace.tabs {
			if (dragging && tab.marked) != foreground {continue}
			clip, sliding := tab_fold_clip(app, w, i)
			if !tab_shown(w.workspace, i) && !sliding {continue}
			if sliding && render.push_layer(&w.list, clip) != .None {continue}
			tile, built := tab_tile(app, w, i)
			if built != .Ok {return built}
			control := tab_motion(w, i)
			if result := ui.tab_draw(
				&w.list,
				&w.ui_text,
				app.theme,
				bar,
				tab_strip_x(w, bar, i),
				tile,
				control.hover.value,
				control.press.value,
				w.scale,
				w.pointer,
			); result != .Ok {return result}
			if sliding {_ = render.push_layer(&w.list, {bar.x, 0, bar.width, bar.height})}
		}
	}
	// A dragged group's chip rides in front of its tabs.
	if dragging && render.push_layer(&w.list, {bar.x, 0, bar.width, bar.height}) == .None {
		for run in runs {
			if !run.carried {continue}
			result := tab_chip_draw(app, w, run, tab_chip_strip_rect(w, bar, run))
			if result != .Ok {return result}
		}
	}
	if render.push_layer(&w.list, {0, 0, f32(w.width), bar.height}) == .None {
		x := bar.x + w.tab_underline.value * bar.tab_width + w.tab_underline_offset.value * w.scale
		moving := dragging
		for motion in w.tab_positions {moving ||= ui.motion_active(motion)}
		if moving {x = tab_strip_x(w, bar, w.workspace.selected)}
		// The selected tab rises with its hover, so its underline rises with it.
		lift := ui.hover_lift_at(
			app.theme,
			tab_motion(w, w.workspace.selected).hover.value,
			w.scale,
		)
		underline := ui.tab_underline_rect(bar, x, lift, w.scale)
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
	if (placed && drop.place == .New_Tab) || w.tab_incoming.count > 0 || pulled {return .Ok}
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
		@(static, rodata)
		names := settings.TABS_ORIENTATION_NAME
		orientation: settings.Tabs_Orientation = w.tabs_horizontal ? .Horizontal : .Vertical
		state_text(r, "tabs.orientation", names[orientation])
		// How far the tabs have gone over to the strip while the orientation changes: 0 rail, 1 strip.
		state_valuef(r, "tabs.flip", "%g", w.flip.value)
		state_valuef(r, "tabs.width", "%g", bar.tab_width)
		state_valuef(r, "tabs.x", "%g", bar.x)
		state_valuef(r, "tabs.height", "%g", bar.height)
		state_rect(r, "tabs.new_tab", window_tab_new_rect(app, w))
		state_rect(r, "tabs.chevron", tab_chevron_rect(app, w))
	}
}
