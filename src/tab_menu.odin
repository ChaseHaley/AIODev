package main

import "aio:input"
import "aio:commands"
import "aio:layout"
import "aio:render"
import "aio:ui"
import "core:fmt"
import "core:log"

// The rows of the tab menu, each keyed by the Action it runs. Which tab it shows for is w.overlay.
Tab_Menu :: struct {
	using menu:  ui.Menu,
	// The Close row's text while it covers a marked group; see tab_menu_sync.
	close_label: [32]u8,
}

tab_menu_init :: proc(menu: ^Tab_Menu) {
	ui.menu_init(&menu.menu)
}

tab_menu_destroy :: proc(menu: ^Tab_Menu) {
	ui.menu_destroy(&menu.menu)
}

tab_menu_shown :: proc(w: ^Window) -> bool {
	_, shown := w.overlay.(Overlay_Tab_Menu)
	return shown
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
	menu := &w.tab_menu
	ui.menu_clear(&menu.menu)
	ui.menu_anchor(&menu.menu, x, y)
	// A nil row is a separator.
	single := [?]Maybe(Action) {
		.Rename_Tab,
		.Duplicate_Tab,
		nil,
		.Move_Tab_Workspace,
		.Move_Tab_New_Workspace,
		.Close_Right_Tabs,
	}
	group := [?]Maybe(Action){.Close_Other_Tabs, .Close_Tab, nil, .Tab_Settings}
	if tab_menu_scope(w) == 1 && !tab_menu_add_rows(app, w, single[:]) {return}
	if !tab_menu_add_rows(app, w, group[:]) {return}
	tab_menu_sync(w)
	ui.menu_select(&menu.menu, -1)
	ui.menu_step(&menu.menu, 1)
	tab_menu_reveal(w)
}

// A row the menu cannot hold closes it rather than offer part of the list.
@(private = "file")
tab_menu_add_rows :: proc(app: ^App, w: ^Window, rows: []Maybe(Action)) -> bool {
	for row in rows {
		item := ui.Menu_Item{separator = true}
		if action, named := row.?; named {
			item = {label = tab_menu_action_label(action), payload = u32(action)}
		}
		if added, err := ui.menu_add(&w.tab_menu.menu, item); !added {
			log.errorf("adding a tab menu row failed: %v", err)
			overlay_close(app, w)
			return false
		}
	}
	return true
}

@(private = "file")
tab_menu_action_label :: proc(action: Action) -> string {
	#partial switch action {
	case .Rename_Tab: return "Rename"
	case .Duplicate_Tab: return "Duplicate"
	case .Close_Right_Tabs: return "Close to the Right"
	case .Close_Other_Tabs: return "Close Others"
	case .Close_Tab: return "Close"
	}
	@(static, rodata) actions := ACTIONS
	return actions[action].title
}

// The rows act on a tab that can close or change while the menu shows, so every reader of the rows
// brings their enabled state and the Close row's count up to date first.
tab_menu_sync :: proc(w: ^Window) {
	menu := &w.tab_menu
	for &item, i in menu.items {
		if item.separator {continue}
		item.enabled = tab_menu_enabled(w, i)
		if Action(item.payload) != .Close_Tab {continue}
		count := tab_menu_scope(w)
		item.label = count > 1 ? fmt.bprintf(menu.close_label[:], "Close %d Selected Tabs", count) : "Close"
	}
}

// Whether row `index` runs now; tab rows need their target, which can close while the menu shows.
tab_menu_enabled :: proc(w: ^Window, index: int) -> bool {
	if index < 0 || index >= len(w.tab_menu.items) || w.tab_menu.items[index].separator {return false}
	target := tab_menu_target(w)
	#partial switch Action(w.tab_menu.items[index].payload) {
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

@(private = "file")
tab_menu_reveal :: proc(w: ^Window) {
	ui.menu_reveal(&w.tab_menu.menu, f32(w.width), f32(w.height), w.scale)
}

tab_menu_hit :: proc(w: ^Window, x, y: f32) -> int {
	return ui.menu_hit(&w.tab_menu.menu, x, y, f32(w.width), f32(w.height), w.scale)
}

tab_menu_choose :: proc(app: ^App, w: ^Window) {
	index := ui.menu_selected(&w.tab_menu.menu)
	// tab_menu_enabled refuses tab rows without a target, so the command acts on a live tab.
	if !tab_menu_shown(w) || !tab_menu_enabled(w, index) {return}
	action := Action(w.tab_menu.items[index].payload)
	target := tab_menu_target(w)
	overlay_close(app, w)
	invocation := commands.invocation(commands.Command_Id(action), focus = true)
	_ = command_execute(app, Window_Context{w, target}, invocation)
}

tab_menu_key :: proc(app: ^App, w: ^Window, e: input.Key_Event) {
	if !e.pressed {return}
	w.dirty = true
	tab_menu_sync(w)
	switch ui.menu_key(&w.tab_menu.menu, e) {
	case .None:
	case .Changed: tab_menu_reveal(w)
	case .Chosen: tab_menu_choose(app, w)
	case .Closed: overlay_close(app, w)
	}
}

tab_menu_wheel :: proc(w: ^Window, rows: int) {
	tab_menu_sync(w)
	ui.menu_wheel(&w.tab_menu.menu, rows)
	tab_menu_reveal(w)
	w.dirty = true
}

tab_menu_draw :: proc(app: ^App, w: ^Window) -> render.Build_Status {
	tab_menu_sync(w)
	width, height := f32(w.width), f32(w.height)
	return ui.menu_draw(&w.tab_menu.menu, &w.list, &w.ui_text, app.theme, width, height, w.scale, w.pointer)
}
