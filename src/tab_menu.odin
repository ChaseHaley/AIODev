package main

import "aio:glyphs"
import "aio:platform"
import "aio:render"
import "aio:ui"
import "core:fmt"

Tab_Menu :: struct {
	open: bool,
	actions: [16]Action,
	separators: [16]bool,
	count, selected, scroll: int,
	position: [2]f32,
}

tab_menu_open :: proc(app: ^App, w: ^Window, index: int, x, y: f32) {
	if index < 0 || index >= len(w.workspace.tabs) {return}
	if !w.workspace.tabs[index].marked {tab_select(app, w, index)} else {tab_select(app, w, index, true)}
	if !gesture_cancel(app, w) {return}
	w.tab_menu = {
		open     = true,
		position = {x, y},
	}
	menu := &w.tab_menu
	count := 0
	for tab in w.workspace.tabs {if tab.marked {count += 1}}
	if count == 1 {
		menu.actions[0], menu.actions[1] = .Rename_Tab, .Duplicate_Tab
		menu.separators[2] = true
		menu.count = 3
	}
	if count == 1 {
		menu.actions[menu.count] = .Close_Right_Tabs
		menu.count += 1
	}
	for action in ([?]Action{.Close_Other_Tabs, .Close_Tab}) {
		menu.actions[menu.count] = action
		menu.count += 1
	}
	menu.separators[menu.count] = true
	menu.actions[menu.count + 1] = .Tab_Settings
	menu.count += 2
	menu.selected = -1
	tab_menu_step(w, 1)
	w.dirty = true
}

tab_menu_label :: proc(w: ^Window, index: int) -> string {
	if w.tab_menu.separators[index] { return "" }
	#partial switch w.tab_menu.actions[index] {
	case .Rename_Tab: return "Rename"
	case .Duplicate_Tab: return "Duplicate"
	case .Close_Right_Tabs: return "Close to the Right"
	case .Close_Other_Tabs: return "Close Others"
	case .Close_Tab:
		count := 0
		for tab in w.workspace.tabs { if tab.marked { count += 1 } }
		return count > 1 ? fmt.tprintf("Close %d Selected Tabs", count) : "Close"
	}
	@(static, rodata) actions := ACTIONS
	return actions[w.tab_menu.actions[index]].title
}

tab_menu_enabled :: proc(w: ^Window, index: int) -> bool {
	if index < 0 || index >= w.tab_menu.count || w.tab_menu.separators[index] { return false }
	#partial switch w.tab_menu.actions[index] {
	case .Duplicate_Tab: return !settings_active(w)
	case .Close_Right_Tabs: return w.workspace.selected + 1 < len(w.workspace.tabs)
	case .Close_Other_Tabs:
		for tab in w.workspace.tabs { if !tab.marked { return true } }
		return false
	case .Close_Tab: return len(w.workspace.tabs) > 0
	}
	return true
}

tab_menu_step :: proc(w: ^Window, step: int, wrap := true) {
	menu := &w.tab_menu
	if menu.count == 0 || step == 0 { return }
	direction := step > 0 ? 1 : -1
	index := menu.selected
	for _ in 0..<menu.count {
		index += direction
		if !wrap && (index < 0 || index >= menu.count) { return }
		index = (index + menu.count) % menu.count
		if tab_menu_enabled(w, index) { menu.selected = index; return }
	}
}

tab_menu_row_height :: proc(w: ^Window, index: int) -> f32 {
	return (w.tab_menu.separators[index] ? 10 : 30) * w.scale
}

tab_menu_rect :: proc(w: ^Window) -> (render.Rect, int) {
	s := w.scale
	rows := 0
	height := 8 * s
	for i in w.tab_menu.scroll..<w.tab_menu.count {
		next := tab_menu_row_height(w, i)
		if rows > 0 && height + next > f32(w.height) - 16 * s { break }
		height += next
		rows += 1
	}
	width := min(300 * s, f32(w.width) - 16 * s)
	return {clamp(w.tab_menu.position.x, 8 * s, max(8 * s, f32(w.width) - width - 8 * s)),
		clamp(w.tab_menu.position.y, 8 * s, max(8 * s, f32(w.height) - height - 8 * s)), width, height}, rows
}

tab_menu_row_rect :: proc(w: ^Window, index: int) -> render.Rect {
	r, _ := tab_menu_rect(w)
	y := r.y + 4 * w.scale
	for i in w.tab_menu.scroll..<index { y += tab_menu_row_height(w, i) }
	return {r.x + 4 * w.scale, y, r.width - 8 * w.scale, tab_menu_row_height(w, index)}
}

tab_menu_hit :: proc(w: ^Window, x, y: f32) -> int {
	r, rows := tab_menu_rect(w)
	if x < r.x || x >= r.x + r.width || y < r.y + 4 * w.scale || y >= r.y + r.height - 4 * w.scale { return -1 }
	for i in w.tab_menu.scroll..<w.tab_menu.scroll + rows {
		row := tab_menu_row_rect(w, i)
		if y >= row.y && y < row.y + row.height { return i }
	}
	return -1
}

tab_menu_choose :: proc(app: ^App, w: ^Window) {
	if !tab_menu_enabled(w, w.tab_menu.selected) { return }
	action := w.tab_menu.actions[w.tab_menu.selected]
	w.tab_menu.open = false
	run_action(app, w, action)
}

tab_menu_key :: proc(app: ^App, w: ^Window, e: platform.Key_Event) {
	if !e.pressed {return}
	menu := &w.tab_menu
	w.dirty = true
	if step := ui.list_step(e); step != 0 {
		tab_menu_step(w, step)
		return
	}
	#partial switch e.key {
	case .Escape, .Context_Menu: menu.open = false
	case .Home: menu.selected = -1; tab_menu_step(w, 1)
	case .End: menu.selected = menu.count; tab_menu_step(w, -1)
	case .Enter, .Numpad_Enter, .Space: tab_menu_choose(app, w)
	}
}

tab_menu_draw :: proc(app: ^App, w: ^Window) -> glyphs.Result {
	s := w.scale
	menu := &w.tab_menu
	menu.scroll = clamp(menu.scroll, 0, max(0, menu.selected))
	r, rows := tab_menu_rect(w)
	for menu.scroll + rows <= menu.selected {
		menu.scroll += 1
		r, rows = tab_menu_rect(w)
	}
	if render.push_layer(&w.list, {0, 0, f32(w.width), f32(w.height)}) != .None { return .Ok }
	frame := ui.Panel {
		rect     = r,
		radius   = 8 * s,
		scale    = s,
		shadow_y = 5,
		softness = 16,
		border   = .Stroked,
	}
	if ui.panel_draw(&w.list, frame, app.theme) != .None { return .Ok }
	if render.push_layer(&w.list, r, 8 * s) != .None { return .Ok }
	for visible in 0..<rows {
		i := menu.scroll + visible
		if i >= menu.count { break }
		row := tab_menu_row_rect(w, i)
		if menu.separators[i] {
			if render.push_rect(&w.list, {rect = {row.x + 10 * s, row.y + 4 * s, row.width - 20 * s, s},
				color = app.theme.border}) != .None { return .Ok }
			continue
		}
		enabled := tab_menu_enabled(w, i)
		if i == menu.selected && enabled {
			if render.push_rect(&w.list, {rect = row, color = app.theme.selection, radius = 4 * s}) != .None {
				return .Ok
			}
		}
		if result := ui.draw_text(&w.ui_text, &w.list, tab_menu_label(w, i), row.x + 10 * s,
			row.y + (row.height - w.ui_text.line_height) / 2 + w.ui_text.ascent,
			enabled ? app.theme.text : app.theme.muted, max(1, row.width - 20 * s)); result != .Ok { return result }
	}
	return .Ok
}
