package main

import "aio:glyphs"
import "aio:platform"
import "aio:render"
import "aio:ui"
import "core:time"

@(private) TOOLTIP_DELAY :: 700 * time.Millisecond

@(private)
tooltip_label :: proc(app: ^App, w: ^Window, owner: Pointer_Target, x, y: f32) -> string {
	#partial switch owner {
	case .Caption:
		switch ui.caption_hit(f32(w.width), x, y, w.scale) {
		case 0: return "Minimize"
		case 1: return w.maximized ? "Restore" : "Maximize"
		case 2: return "Close window"
		case:
		}
	case .Tab_Orientation:
		return w.tabs_horizontal ? "Show vertical tabs" : "Show horizontal tabs"
	case .Title_Action:
		#partial switch title_action_hit(w, x, y) {
		case .Settings: return "Settings"
		case .Palette: return "Command palette"
		case:
		}
	case .Workspace_Button: return "Workspaces"
	case .Status_Pill: return "Activity"
	case .Status_Panel:
		if rect_contains(status_panel_side_rect(app, w), x, y) {return "Move activity panel"}
	case .Settings_Page:
		if w.editor.hover_reset >= 0 {return "Reset setting"}
	case .Palette:
		if app.palette.reset_hover >= 0 && !app.palette.mode_menu && app.palette.edit.kind == .None {
			return "Reset setting"
		}
	case .Pane_Header:
		_, action, _ := pane_header_hit(w, x, y)
		#partial switch action {
		case .Split_Right: return "Split right"
		case .Split_Down: return "Split down"
		case .Zoom: return w.tree.zoomed ? "Restore pane" : "Fullscreen pane"
		case .Close: return "Close pane"
		case:
		}
	case .Find:
		#partial switch w.find.hover {
		case .Case_Toggle: return "Match case"
		case .Regex_Toggle: return "Use regular expression"
		case .Older: return "Previous match"
		case .Newer: return "Next match"
		case .Close: return "Close find"
		case:
		}
	case .Tabs:
		if w.tabs_horizontal {
			bar := window_tab_bar(app, w)
			if window_tab_close_hit(app, w, bar, x, y) >= 0 {return "Close tab"}
			if x >= tab_chevron_rect(app, w).x {return "Choose profile"}
			if window_tab_hit(app, w, bar, x, y) == bar.count {return "New tab"}
		} else {
			if layout, ok := rail_current_layout(w); ok {
				if row := rail_tab_hit(w, layout, x, y); row >= 0 {
					close := rail_tab_close_rect(w, layout, row)
					if rect_contains(close, x, y) {return "Close tab"}
				}
				if ui.rail_footer_hit(layout, x, y) {
					return ui.rail_profile_hit(layout, x, y) ? "Choose profile" : "New tab"
				}
			}
		}
	case:
	}
	return ""
}

tooltip_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: platform.Mouse_Move_Event) {
	label := e.buttons == {} ? tooltip_label(app, w, owner, f32(e.x), f32(e.y)) : ""
	if label == w.tooltip {return}
	w.tooltip = label
	w.tooltip_visible = false
	w.tooltip_deadline = label == "" ? {} : time.tick_add(time.tick_now(), TOOLTIP_DELAY)
	w.dirty = true
}

tooltip_tick :: proc(w: ^Window) {
	if w.tooltip_deadline == {} || time.tick_diff(time.tick_now(), w.tooltip_deadline) > 0 {return}
	w.tooltip_deadline = {}
	w.tooltip_visible = true
	w.dirty = true
}

tooltip_draw :: proc(app: ^App, w: ^Window) -> glyphs.Result {
	if !w.tooltip_visible || w.tooltip == "" {return .Ok}
	owner := pointer_target(app, w, w.pointer.x, w.pointer.y)
	if tooltip_label(app, w, owner, w.pointer.x, w.pointer.y) != w.tooltip {return .Ok}
	s := w.scale
	width := ui.text_width(&w.ui_text, w.tooltip) + 16 * s
	height := 26 * s
	x := clamp(w.pointer.x + 12 * s, 4 * s, max(4 * s, f32(w.width) - width - 4 * s))
	y := clamp(w.pointer.y + 18 * s, 4 * s, max(4 * s, f32(w.height) - height - 4 * s))
	if render.push_layer(&w.list, {0, 0, f32(w.width), f32(w.height)}) != .None {return .Ok}
	if ui.panel_draw(&w.list, {rect = {x, y, width, height}, radius = 5 * s,
	   scale = s, shadow_y = 2, softness = 8, border = .Stroked}, app.theme) != .None {return .Ok}
	return ui.draw_text(&w.ui_text, &w.list, w.tooltip, x + 8 * s,
		y + (height + w.ui_text.ascent) / 2 - 2 * s, app.theme.text)
}
