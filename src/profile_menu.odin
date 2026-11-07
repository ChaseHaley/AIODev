package main

import "aio:glyphs"
import "aio:input"
import "aio:layout"
import "aio:settings"
import "aio:ui"

// What choosing a profile does.
Profile_Menu_Mode :: union #no_nil {
	Profile_Menu_New_Tab,
	Profile_Menu_Swap_Pane,
}

Profile_Menu_New_Tab :: struct {}

// The pane whose shell a profile replaces, held by its content rather than its node: the pane can close,
// or its tab give way to another, while the menu is open, and a node id would then name another pane.
Profile_Menu_Swap_Pane :: struct {
	pane: layout.Content,
}

Profile_Menu_Action :: enum {
	None,
	Profile,
	Settings,
	Palette,
}

Profile_Menu_Entry :: struct {
	action:        Profile_Menu_Action,
	visible_index: int,
	profile_id:    string,
}

// The same menu surface serves the tab rail's new-tab button and a pane's shell badge. Whether it shows,
// and for which, is w.overlay.
Profile_Menu :: struct {
	using menu: ui.Menu,
	entries:    [ui.MENU_MAX_ITEMS]Profile_Menu_Entry,
	count:      int,
}

profile_menu_init :: proc(menu: ^Profile_Menu) {
	ui.menu_init(&menu.menu)
}

profile_menu_shown :: proc(w: ^Window) -> bool {
	_, shown := w.overlay.(Overlay_Profile_Menu)
	return shown
}

profile_menu_destroy :: proc(menu: ^Profile_Menu) {
	ui.menu_destroy(&menu.menu)
}

@(private)
profile_shortcut_label :: proc(index: int) -> string {
	@(static, rodata)
	labels := [9]string {
		"Ctrl+Shift+1",
		"Ctrl+Shift+2",
		"Ctrl+Shift+3",
		"Ctrl+Shift+4",
		"Ctrl+Shift+5",
		"Ctrl+Shift+6",
		"Ctrl+Shift+7",
		"Ctrl+Shift+8",
		"Ctrl+Shift+9",
	}
	return index >= 0 && index < len(labels) ? labels[index] : ""
}

@(private)
profile_badge :: proc(profile: ^settings.Profile) -> string {
	return settings.shell_icon(settings.shell_executable(profile.command), "")
}

@(private)
profile_menu_push :: proc(
	menu: ^Profile_Menu,
	item: ui.Menu_Item,
	entry: Profile_Menu_Entry,
) {
	_ = ui.menu_add(&menu.menu, item)
	menu.entries[menu.count] = entry
	menu.count += 1
}

profile_menu_open :: proc(app: ^App, w: ^Window, mode: Profile_Menu_Mode, x, y: f32) {
	overlay_open(app, w, Overlay_Profile_Menu{mode})
	menu := &w.profile_menu
	ui.menu_clear(&menu.menu)
	menu.entries = {}
	menu.count = 0
	indices: [settings.PROFILE_LIMIT]int
	count := settings.profiles_in_order(
		&app.settings.profiles,
		indices[:],
		visible_only = true,
	)
	_, swap := mode.(Profile_Menu_Swap_Pane)
	current := ""
	if swap {
		if entry := focused_session(app, w); entry != nil {current = entry.profile_id}
	}
	for i in 0..<count {
		profile := &app.settings.profiles.items[indices[i]]
		checked := profile.id == current
		if !swap {checked = profile.id == app.settings.profiles.default_id}
		profile_menu_push(
			menu,
			{
				label = profile.name,
				shortcut = profile_shortcut_label(i),
				icon = profile_badge(profile),
				checked = checked,
				enabled = true,
			},
			{action = .Profile, visible_index = i, profile_id = profile.id},
		)
	}
	if swap {
		profile_menu_push(menu, {separator = true}, {})
		profile_menu_push(
			menu,
			{label = "Settings", shortcut = "Ctrl+,", enabled = true},
			{action = .Settings},
		)
		profile_menu_push(
			menu,
			{label = "Command Palette", shortcut = "Ctrl+Shift+P", enabled = true},
			{action = .Palette},
		)
	}
	ui.menu_anchor(&menu.menu, x, y)
	ui.menu_select_edge(&menu.menu, false)
}

profile_menu_open_new_tab :: proc(app: ^App, w: ^Window, x, y: f32) {
	profile_menu_open(app, w, Profile_Menu_New_Tab{}, x, y)
}

// `pane` is a node of w's current tree.
profile_menu_open_pane :: proc(
	app: ^App,
	w: ^Window,
	pane: layout.Node_Id,
	x, y: f32,
) {
	node, is_pane := w.tree.nodes[pane].(layout.Pane)
	if !is_pane {return}
	profile_menu_open(app, w, Profile_Menu_Swap_Pane{node.content}, x, y)
}

profile_menu_choose :: proc(app: ^App, w: ^Window) {
	shown, ok := w.overlay.(Overlay_Profile_Menu)
	if !ok {return}
	menu := &w.profile_menu
	index := ui.menu_selected(&menu.menu)
	if index < 0 || index >= menu.count {return}
	entry := menu.entries[index]
	if entry.action == .None {return}
	overlay_close(app, w)
	switch entry.action {
	case .None:
	case .Profile:
		switch mode in shown.mode {
		case Profile_Menu_New_Tab:
			tab_new_profile(app, w, entry.visible_index)
			rail_overlay_dismiss(app, w)
		case Profile_Menu_Swap_Pane:
			// A pane that closed or left the window's tree since the menu opened is not swapped.
			if node := layout.find_content(w.tree, mode.pane); node != layout.INVALID_NODE {
				pane_shell_swap_request(app, w, node, entry.profile_id)
			}
		}
	case .Settings:
		editor_open(app, pane_link_acting_window(app, w))
	case .Palette:
		palette_open(app, w)
	}
}

profile_menu_key :: proc(app: ^App, w: ^Window, e: input.Key_Event) -> bool {
	if !profile_menu_shown(w) {return false}
	switch ui.menu_key(&w.profile_menu.menu, e) {
	case .None:
	case .Changed:
		ui.menu_reveal(&w.profile_menu.menu, f32(w.width), f32(w.height), w.scale)
		w.dirty = true
	case .Chosen:
		profile_menu_choose(app, w)
	case .Closed:
		overlay_close(app, w)
	}
	return true
}

profile_menu_wheel :: proc(w: ^Window, rows: int) {
	ui.menu_wheel(&w.profile_menu.menu, rows)
	ui.menu_reveal(&w.profile_menu.menu, f32(w.width), f32(w.height), w.scale)
	w.dirty = true
}

profile_menu_hit :: proc(w: ^Window, x, y: f32) -> int {
	if !profile_menu_shown(w) {return -1}
	return ui.menu_hit(
		&w.profile_menu.menu,
		x,
		y,
		f32(w.width),
		f32(w.height),
		w.scale,
	)
}

profile_menu_button :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) -> bool {
	if !profile_menu_shown(w) {return false}
	if !e.pressed {
		w.dirty = true
		return true
	}
	gesture_swallow(w, e.button, .Profile_Menu)
	if hit := profile_menu_hit(w, f32(e.x), f32(e.y)); hit >= 0 && e.button == .Left {
		item := w.profile_menu.menu.items[hit]
		if item.enabled && !item.separator {
			ui.menu_select(&w.profile_menu.menu, hit)
			profile_menu_choose(app, w)
		}
	} else if hit < 0 {
		overlay_close(app, w)
	}
	return true
}

profile_menu_draw :: proc(app: ^App, w: ^Window) -> glyphs.Result {
	return ui.menu_draw(
		&w.profile_menu.menu,
		&w.list,
		&w.ui_text,
		app.theme,
		f32(w.width),
		f32(w.height),
		w.scale,
		w.pointer,
	)
}
