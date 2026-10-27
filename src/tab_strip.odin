package main

import "aio:glyphs"
import "aio:render"
import "aio:settings"
import "aio:ui"
import "core:fmt"
import "core:os"

// Horizontal tab-strip geometry and drawing. The strip shares the 40 DIP title bar with the
// workspace chip and the caption controls, so both the tab bar and the controls end read the same
// layout. Vertical mode uses the rail instead.
window_tab_bar :: proc(app: ^App, w: ^Window) -> ui.Tab_Bar {
	if w.workspace == nil {return {}}
	left := workspace_button_width(w)
	bar := ui.tab_bar_layout(
		max(0, f32(w.width) - 218 * w.scale - left),
		w.scale,
		len(w.workspace.tabs),
	)
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

window_tab_hit :: proc(app: ^App, w: ^Window, bar: ui.Tab_Bar, x, y: f32) -> int {
	if x < bar.x || x >= bar.x + bar.width || y < 0 || y >= bar.height {return -1}
	for pass in 0 ..< 2 {
		for i := bar.count - 1; i >= 0; i -= 1 {
			foreground := w.tab_drag.active && w.workspace.tabs[i].marked
			if foreground != (pass == 0) {continue}
			r := window_tab_rect(app, w, i)
			if x >= r.x && x < r.x + r.width {return i}
		}
	}
	return ui.tab_bar_hit_test(bar, x, y) == bar.count ? bar.count : -1
}

window_tab_close_hit :: proc(app: ^App, w: ^Window, bar: ui.Tab_Bar, x, y: f32) -> int {
	index := window_tab_hit(app, w, bar, x, y)
	r := window_tab_close_rect(app, w, index)
	if r.width > 0 &&	   x >= r.x &&
	   x < r.x + r.width &&
	   y >= r.y &&
	   y < r.y + r.height {return index}
	return -1
}

// The rightmost point the title chrome claims before the native caption buttons start.
window_title_controls_end :: proc(app: ^App, w: ^Window) -> f32 {
	left := workspace_button_width(w)
	if !w.tabs_horizontal {
		toggle := tab_orientation_button_rect(w)
		return max(left, toggle.x + toggle.width)
	}
	bar := window_tab_bar(app, w)
	if bar.count == 0 {return max(left, bar.x + 2 * bar.button_width)}
	return max(left, bar.x + f32(bar.count) * bar.tab_width + 2 * bar.button_width)
}

toggle_tab_orientation :: proc(app: ^App) {
	next := app.settings.tabs.orientation == .Horizontal ? "vertical" : "horizontal"
	if app.settings_path != "" {
		data, read_error := os.read_entire_file(app.settings_path, context.temp_allocator)
		if read_error != nil {
			notify(app, .Error, "Could not read the settings file to switch tab orientation.")
			return
		}
		updated, message, edit_error := settings.edit_text(
			string(data),
			"tabs.orientation",
			next,
		)
		defer delete(updated)
		defer delete(message)
		if edit_error != nil || message != "" {
			notify(app, .Error, "Could not save the tab orientation.")
			return
		}
		if settings.save(app.settings_path, string(data), updated) != .None {
			notify(app, .Error, "Could not save the tab orientation.")
			return
		}
		reload_settings(app, false)
		for window in app.windows {
			if !window.editor.open {continue}
			// The shortcut wrote the file outside the open editor; reload its source so the next
			// inline save does not hit the conflict guard.
			settings_reveal_page(
				app,
				&window.editor,
				{search = .Preserve, reload = true},
			)
		}
	} else {
		app.settings.tabs.orientation = next == "horizontal" ? .Horizontal : .Vertical
		for window in app.windows {
			window_apply_settings(app, window)
			rail_reveal_active(app, window)
		}
	}
	label := next == "horizontal" ? "Horizontal" : "Vertical"
	notify(app, .Info, fmt.tprintf("%s tabs. Ctrl+Shift+L switches back.", label))
}

@(private)
tab_control :: proc(w: ^Window, index: int) -> ui.Control_Motion {
	if index < 0 || index >= len(w.tab_controls) {return {}}
	return w.tab_controls[index]
}

window_tab_strip_draw :: proc(app: ^App, w: ^Window) -> glyphs.Result {
	bar := window_tab_bar(app, w)
	if bar.count == 0 {return .Ok}
	for pass in 0 ..< (w.tab_drag.active ? 2 : 1) {
		foreground := pass == 1
		for tab, i in w.workspace.tabs {
			if (w.tab_drag.active && tab.marked) != foreground {continue}
			title := fmt.tprintf("Tab %d", i + 1)
			if tab.title != "" {title = tab.title}
			icon: string
			atlas := render.Rect{}
			if pane, terminal := workspace_focused_session_pane(app, w.workspace, i); terminal {
				if pane.session != nil {icon = pane.session.header.icon}
				result: glyphs.Result
				atlas, result = shell_icon_atlas(app)
				if result != .Ok {return result}
			}
			x := tab_position(w, i) * bar.tab_width
			if result := ui.tab_draw(
				&w.list,
				&w.ui_text,
				app.theme,
				bar,
				i,
				title,
				i == w.workspace.selected,
				w.scale,
				tab_control(w, i).hover.value,
				tab_control(w, i).press.value,
				0,
				x,
				tab.marked,
				icon,
				atlas,
				w.pointer,
			); result != .Ok {return result}
		}
	}
	if render.push_layer(&w.list, {0, 0, f32(w.width), bar.height}) == .None {
		x := bar.x + w.tab_underline.value * bar.tab_width + 10 * w.scale
		moving := w.tab_drag.active
		for position in w.tab_positions {moving ||= ui.motion_active(position)}
		if moving {x = bar.x + tab_position(w, w.workspace.selected) * bar.tab_width + 10 * w.scale}
		// The selected tab rises with its hover, so its underline rises with it.
		lift := ui.hover_lift_at(
			app.theme,
			tab_control(w, w.workspace.selected).hover.value,
			w.scale,
		)
		if render.push_rect(
			   &w.list,
			   {
				   rect = {
					   x,
					   30 * w.scale - lift,
					   max(0, bar.tab_width - 20 * w.scale),
					   2 * w.scale,
				   },
				   color = app.theme.accent,
				   radius = w.scale,
			   },
		   ) !=
		   .None {return .Ok}
	}
	if w.pane_drag.active && w.pane_drag.new_tab {return .Ok}
	if result := ui.tab_draw(
		&w.list,
		&w.ui_text,
		app.theme,
		bar,
		bar.count,
		"+",
		false,
		w.scale,
		tab_control(w, bar.count).hover.value,
		tab_control(w, bar.count).press.value,
		0,
		-1,
		false,
		"",
		{},
		w.pointer,
	); result != .Ok {return result}
	chevron := tab_chevron_rect(app, w)
	if render.push_layer(&w.list, chevron) != .None {return .Ok}
	control := tab_control(w, bar.count + 1)
	hover := control.hover.value
	lift := ui.hover_lift_at(app.theme, hover, w.scale)
	tile := render.Rect {
		chevron.x + 2 * w.scale,
		6 * w.scale - lift,
		chevron.width - 4 * w.scale,
		28 * w.scale,
	}
	if lift > 0 {
		if result := ui.hover_shadow_draw(&w.list, app.theme, tile, 6 * w.scale, hover, w.scale);
		   result != .None {return .Ok}
	}
	fill := app.theme.hover
	fill.a *= hover
	if render.push_rect(&w.list, {rect = tile, color = fill, radius = 6 * w.scale}) != .None {
		return .Ok
	}
	fill = app.theme.pressed
	fill.a *= control.press.value
	if render.push_rect(&w.list, {rect = tile, color = fill, radius = 6 * w.scale}) != .None {
		return .Ok
	}
	label := "▾"
	label_width := ui.text_width(&w.ui_text, label)
	if result := ui.draw_text(
		&w.ui_text,
		&w.list,
		label,
		chevron.x + (chevron.width - label_width) / 2,
		(bar.height - w.ui_text.line_height) / 2 + w.ui_text.ascent - lift,
		app.theme.muted,
	); result != .Ok {return result}
	if hover > 0 {
		if result := ui.hover_rim_draw(
			&w.list,
			app.theme,
			tile,
			6 * w.scale,
			hover,
			w.scale,
			w.pointer,
		); result != .None {return .Ok}
	}
	return .Ok
}
