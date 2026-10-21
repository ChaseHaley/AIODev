package main

import "aio:glyphs"
import "aio:platform"
import "aio:render"
import "aio:ui"
import "core:fmt"

Tab_Menu :: struct {
	open:                    bool,
	actions:                 [16]Action,
	count, selected, scroll: int,
	position:                [2]f32,
}

tab_menu_open :: proc(app: ^App, w: ^Window, index: int, x, y: f32) {
	if index < 0 || index >= len(w.workspace.tabs) {return}
	if !w.workspace.tabs[index].marked {tab_select(app, w, index)} else {tab_select(app, w, index, true)}
	arrange_cancel(app, w)
	leader_cancel(w)
	pane_header_cancel(w)
	w.tab_menu = {
		open     = true,
		position = {x, y},
	}
	menu := &w.tab_menu
	count := 0
	for tab in w.workspace.tabs {if tab.marked {count += 1}}
	if count == 1 && !settings_active(w) {
		for action in ([?]Action{.Rename_Tab, .Duplicate_Tab, .Split_Right, .Split_Down, .Move_Tab_Left, .Move_Tab_Right, .Find, .Close_Right_Tabs}) {
			menu.actions[menu.count] = action
			menu.count += 1
		}
	}
	for action in ([?]Action{.Move_Tab_Start, .Move_Tab_End, .Close_Other_Tabs, .Close_Tab, .Tab_Settings}) {
		menu.actions[menu.count] = action
		menu.count += 1
	}
	w.dirty = true
}

tab_menu_rect :: proc(w: ^Window) -> (render.Rect, int) {
	s := w.scale
	rows := min(w.tab_menu.count, max(1, int((f32(w.height) - 24 * s) / (30 * s))))
	width, height := min(300 * s, f32(w.width) - 16 * s), f32(rows) * 30 * s + 8 * s
	return {
			clamp(w.tab_menu.position.x, 8 * s, max(8 * s, f32(w.width) - width - 8 * s)),
			clamp(w.tab_menu.position.y, 8 * s, max(8 * s, f32(w.height) - height - 8 * s)),
			width,
			height,
		},
		rows
}

tab_menu_hit :: proc(w: ^Window, x, y: f32) -> int {
	r, rows := tab_menu_rect(w)
	if x < r.x ||
	   x >= r.x + r.width ||
	   y < r.y + 4 * w.scale ||
	   y >= r.y + r.height - 4 * w.scale {return -1}
	return min(
		w.tab_menu.count - 1,
		w.tab_menu.scroll + clamp(int((y - r.y - 4 * w.scale) / (30 * w.scale)), 0, rows - 1),
	)
}

tab_menu_choose :: proc(app: ^App, w: ^Window) {
	action := w.tab_menu.actions[w.tab_menu.selected]
	w.tab_menu.open = false
	run_action(app, w, action)
}

tab_menu_key :: proc(app: ^App, w: ^Window, e: platform.Key_Event) {
	if !e.pressed {return}
	menu := &w.tab_menu
	w.dirty = true
	if step := ui.list_step(e); step != 0 {
		menu.selected = (menu.selected + menu.count + step) % menu.count
		return
	}
	#partial switch e.key {
	case .Escape, .Context_Menu:
		menu.open = false
	case .Home:
		menu.selected = 0
	case .End:
		menu.selected = menu.count - 1
	case .Enter, .Numpad_Enter, .Space:
		tab_menu_choose(app, w)
	}
}

tab_menu_draw :: proc(app: ^App, w: ^Window) -> glyphs.Result {
	r, rows := tab_menu_rect(w)
	s := w.scale
	menu := &w.tab_menu
	menu.scroll = clamp(menu.scroll, max(0, menu.selected - rows + 1), menu.selected)
	if render.push_layer(&w.list, {0, 0, f32(w.width), f32(w.height)}) != .None {return .Ok}
	if render.push_rect(
		   &w.list,
		   {
			   rect = {r.x, r.y + 5 * s, r.width, r.height},
			   color = app.theme.shadow,
			   radius = 8 * s,
			   softness = 16 * s,
		   },
	   ) !=
	   .None {return .Ok}
	if render.push_rect(&w.list, {rect = r, color = app.theme.surface, radius = 8 * s}) !=
	   .None {return .Ok}
	if render.push_rect(
		   &w.list,
		   {rect = r, color = app.theme.border, radius = 8 * s, stroke = s},
	   ) !=
	   .None {
		return .Ok
	}
	if render.push_layer(&w.list, r, 8 * s) != .None {return .Ok}
	@(static, rodata)
	actions := ACTIONS
	for visible in 0 ..< rows {
		i := menu.scroll + visible
		if i >= menu.count {break}
		row := render.Rect {
			r.x + 4 * s,
			r.y + 4 * s + f32(visible) * 30 * s,
			r.width - 8 * s,
			30 * s,
		}
		if i == menu.selected {
			if render.push_rect(
				   &w.list,
				   {rect = row, color = app.theme.selection, radius = 4 * s},
			   ) !=
			   .None {
				return .Ok
			}
		}
		label := actions[menu.actions[i]].title
		if menu.actions[i] == .Close_Tab {
			count := 0
			for tab in w.workspace.tabs {if tab.marked {count += 1}}
			label = count > 1 ? fmt.tprintf("Close %d Selected Tabs", count) : "Close Tab"
		}
		if result := ui.draw_text(
			&w.ui_text,
			&w.list,
			label,
			row.x + 10 * s,
			row.y + (row.height - w.ui_text.line_height) / 2 + w.ui_text.ascent,
			app.theme.text,
			max(1, row.width - 20 * s),
		); result != .Ok {return result}
	}
	return .Ok
}
