package main

import "aio:input"
import "aio:commands"
import "aio:layout"
import "aio:render"
import "aio:ui"
import "core:fmt"

// The rows of the tab menu and the dock edge menu; which one shows, and for what, is w.overlay.
Tab_Menu :: struct {
	actions: [16]Action,
	separators: [16]bool,
	count, selected: int,
	// The first row shown as of the last selection change; see tab_menu_first.
	scroll: int,
	position: [2]f32,
}

// The tab menu or the dock edge menu shows.
tab_menu_shown :: proc(w: ^Window) -> bool {
	#partial switch _ in w.overlay {
	case Overlay_Tab_Menu, Overlay_Divider_Menu: return true
	}
	return false
}

// The index of the tab the open menu acts on, or -1.
tab_menu_target :: proc(w: ^Window) -> int {
	menu, shown := w.overlay.(Overlay_Tab_Menu)
	if !shown {return -1}
	return tab_index_by_id(w.workspace, menu.tab)
}

// How many tabs the menu's actions cover: the marked group when the target is in it, else the target alone.
tab_menu_scope :: proc(w: ^Window) -> int {
	target := tab_menu_target(w)
	if target < 0 || !w.workspace.tabs[target].marked {return 1}
	count := 0
	for tab in w.workspace.tabs {if tab.marked {count += 1}}
	return count
}

// Whether tab `index` draws as marked. While the menu is open on an unmarked tab, only that tab does.
tab_marked_shown :: proc(w: ^Window, index: int) -> bool {
	target := tab_menu_target(w)
	if target >= 0 && !w.workspace.tabs[target].marked {return index == target}
	return w.workspace.tabs[index].marked
}

tab_menu_open :: proc(app: ^App, w: ^Window, index: int, x, y: f32) {
	if index < 0 || index >= len(w.workspace.tabs) {return}
	if !gesture_cancel(app, w) {return}
	overlay_open(app, w, Overlay_Tab_Menu{tab = w.workspace.tabs[index].id})
	w.tab_menu = {position = {x, y}}
	menu := &w.tab_menu
	count := tab_menu_scope(w)
	if count == 1 {
		menu.actions[0], menu.actions[1] = .Rename_Tab, .Duplicate_Tab
		menu.separators[2] = true
		menu.count = 3
	}
	if count == 1 {
		menu.actions[menu.count] = .Move_Tab_Workspace
		menu.actions[menu.count + 1] = .Move_Tab_New_Workspace
		menu.count += 2
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
}

tab_menu_label :: proc(w: ^Window, index: int) -> string {
	if _, divider := w.overlay.(Overlay_Divider_Menu); divider {return "Set as Default Size"}
	if w.tab_menu.separators[index] { return "" }
	#partial switch w.tab_menu.actions[index] {
	case .Rename_Tab: return "Rename"
	case .Duplicate_Tab: return "Duplicate"
	case .Close_Right_Tabs: return "Close to the Right"
	case .Close_Other_Tabs: return "Close Others"
	case .Close_Tab:
		count := tab_menu_scope(w)
		return count > 1 ? fmt.tprintf("Close %d Selected Tabs", count) : "Close"
	}
	@(static, rodata) actions := ACTIONS
	return actions[w.tab_menu.actions[index]].title
}

tab_menu_enabled :: proc(w: ^Window, index: int) -> bool {
	if index < 0 || index >= w.tab_menu.count || w.tab_menu.separators[index] { return false }
	if _, divider := w.overlay.(Overlay_Divider_Menu); divider {return true}
	// Tab rows need their target, which may have closed while the menu was open.
	target := tab_menu_target(w)
	#partial switch w.tab_menu.actions[index] {
	case .Rename_Tab, .Move_Tab_Workspace, .Move_Tab_New_Workspace, .Close_Tab: return target >= 0
	case .Duplicate_Tab:
		if target < 0 {return false}
		tree := &w.workspace.tabs[target].tree
		if tree.focus == layout.INVALID_NODE {return false}
		pane, ok := tree.nodes[tree.focus].(layout.Pane)
		return ok && pane_owns_session(pane.content.kind)
	case .Close_Right_Tabs: return target >= 0 && target + 1 < len(w.workspace.tabs)
	case .Close_Other_Tabs: return target >= 0 && tab_menu_scope(w) < len(w.workspace.tabs)
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
		if tab_menu_enabled(w, index) {
			menu.selected = index
			menu.scroll = tab_menu_first(w)
			return
		}
	}
}

tab_menu_row_height :: proc(w: ^Window, index: int) -> f32 {
	return (w.tab_menu.separators[index] ? ui.MENU_SEPARATOR_HEIGHT : ui.MENU_ROW_HEIGHT) * w.scale
}

// The surface height and how many rows fit when the list starts at row `first`.
@(private = "file")
tab_menu_extent :: proc(w: ^Window, first: int) -> (height: f32, rows: int) {
	s := w.scale
	height = 2 * ui.OVERLAY_PADDING * s
	for i in first..<w.tab_menu.count {
		next := tab_menu_row_height(w, i)
		if rows > 0 && height + next > f32(w.height) - 16 * s { break }
		height += next
		rows += 1
	}
	return
}

// The first row shown: the stored scroll, moved only as far as showing the selection needs, so a
// window that shrank still shows it without drawing having to change the menu.
tab_menu_first :: proc(w: ^Window) -> int {
	menu := &w.tab_menu
	first := clamp(menu.scroll, 0, max(0, menu.selected))
	for first < menu.selected {
		_, rows := tab_menu_extent(w, first)
		if first + rows > menu.selected { break }
		first += 1
	}
	return first
}

tab_menu_rect :: proc(w: ^Window) -> (render.Rect, int) {
	s := w.scale
	height, rows := tab_menu_extent(w, tab_menu_first(w))
	width := min(ui.MENU_WIDTH * s, f32(w.width) - 16 * s)
	return {clamp(w.tab_menu.position.x, 8 * s, max(8 * s, f32(w.width) - width - 8 * s)),
		clamp(w.tab_menu.position.y, 8 * s, max(8 * s, f32(w.height) - height - 8 * s)), width, height}, rows
}

tab_menu_row_rect :: proc(w: ^Window, index: int) -> render.Rect {
	r, _ := tab_menu_rect(w)
	pad := ui.OVERLAY_PADDING * w.scale
	y := r.y + pad
	for i in tab_menu_first(w)..<index { y += tab_menu_row_height(w, i) }
	return {r.x + pad, y, r.width - 2 * pad, tab_menu_row_height(w, index)}
}

tab_menu_hit :: proc(w: ^Window, x, y: f32) -> int {
	r, rows := tab_menu_rect(w)
	if x < r.x || x >= r.x + r.width || y < r.y + 4 * w.scale || y >= r.y + r.height - 4 * w.scale { return -1 }
	first := tab_menu_first(w)
	for i in first..<first + rows {
		row := tab_menu_row_rect(w, i)
		if y >= row.y && y < row.y + row.height { return i }
	}
	return -1
}

tab_menu_choose :: proc(app: ^App, w: ^Window) {
	if !tab_menu_enabled(w, w.tab_menu.selected) { return }
	if divider, ok := w.overlay.(Overlay_Divider_Menu); ok {
		overlay_close(app, w)
		dock_divider_save_default(app, w, divider.node)
		return
	}
	action := w.tab_menu.actions[w.tab_menu.selected]
	target := tab_menu_target(w)
	overlay_close(app, w)
	// tab_menu_enabled refused tab rows without a target, so the command acts on a live tab.
	invocation := commands.invocation(commands.Command_Id(action), focus = true)
	_ = command_execute(app, Window_Context{w, target}, invocation)
}

tab_menu_key :: proc(app: ^App, w: ^Window, e: input.Key_Event) {
	if !e.pressed {return}
	w.dirty = true
	if step := ui.list_step(e); step != 0 {
		tab_menu_step(w, step)
		return
	}
	#partial switch e.key {
	case .Escape, .Context_Menu: overlay_close(app, w)
	case .Home: tab_menu_select_edge(w, false)
	case .End: tab_menu_select_edge(w, true)
	case .Enter, .Numpad_Enter, .Space: tab_menu_choose(app, w)
	}
}

// Selects the first enabled row, or the last one from the end. A menu without one keeps its selection.
@(private = "file")
tab_menu_select_edge :: proc(w: ^Window, last: bool) {
	menu := &w.tab_menu
	previous := menu.selected
	menu.selected = last ? menu.count : -1
	tab_menu_step(w, last ? -1 : 1)
	if menu.selected < 0 || menu.selected >= menu.count {menu.selected = previous}
}

// Draws the rows around the selection; it reads the menu and changes nothing in it.
tab_menu_draw :: proc(app: ^App, w: ^Window) -> render.Build_Status {
	s := w.scale
	menu := &w.tab_menu
	r, rows := tab_menu_rect(w)
	first := tab_menu_first(w)
	if render.push_layer(&w.list, {0, 0, f32(w.width), f32(w.height)}) != .None { return .Ok }
	frame := ui.popover_panel(r, s)
	if ui.panel_draw(&w.list, frame, app.theme) != .None { return .Ok }
	if render.push_layer(&w.list, r, ui.RADIUS_OVERLAY * s) != .None { return .Ok }
	for visible in 0..<rows {
		i := first + visible
		if i >= menu.count { break }
		row := tab_menu_row_rect(w, i)
		if menu.separators[i] {
			inset := ui.CONTROL_INSET * s
			if render.push_rect(&w.list, {rect = {row.x + inset, row.y + 4 * s, row.width - 2 * inset, s},
				color = app.theme.border}) != .None { return .Ok }
			continue
		}
		enabled := tab_menu_enabled(w, i)
		if i == menu.selected && enabled {
			selection := render.Rect_Instance{rect = row, color = app.theme.selection, radius = ui.RADIUS_CONTROL * s}
			if render.push_rect(&w.list, selection) != .None {
				return .Ok
			}
		}
		inset := ui.CONTROL_INSET * s
		if result := ui.draw_text(&w.ui_text, &w.list, tab_menu_label(w, i), row.x + inset,
			row.y + (row.height - w.ui_text.line_height) / 2 + w.ui_text.ascent,
			enabled ? app.theme.text : app.theme.muted, max(1, row.width - 2 * inset)); result != .Ok { return result }
		if i == menu.selected && enabled && render.rect_contains(row, w.pointer.x, w.pointer.y) {
			if ui.hover_rim_draw(&w.list, app.theme, row, ui.RADIUS_CONTROL * s, 1, s, w.pointer) != .None {
				return .Ok
			}
		}
	}
	return .Ok
}
