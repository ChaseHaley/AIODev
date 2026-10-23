package main

import "aio:glyphs"
import "aio:layout"
import "aio:platform"
import "aio:settings"
import "aio:ui"

Profile_Menu_Mode :: enum {
	None,
	New_Tab,
	Swap_Pane,
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

// The same menu surface serves the tab-strip chevron and a pane's shell badge.
Profile_Menu :: struct {
	using menu: ui.Menu,
	mode:       Profile_Menu_Mode,
	entries:    [ui.MENU_MAX_ITEMS]Profile_Menu_Entry,
	count:      int,
	pane:       layout.Node_Id,
}

profile_menu_init :: proc(menu: ^Profile_Menu) {
	ui.menu_init(&menu.menu)
	menu.pane = layout.INVALID_NODE
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

profile_menu_open :: proc(
	app: ^App,
	w: ^Window,
	mode: Profile_Menu_Mode,
	x, y: f32,
	pane := layout.Node_Id(0),
) {
	w.tab_menu.open = false
	menu := &w.profile_menu
	ui.menu_clear(&menu.menu)
	menu.entries = {}
	menu.count = 0
	menu.mode = mode
	menu.pane = pane
	indices: [settings.PROFILE_LIMIT]int
	count := settings.profiles_in_order(
		&app.settings.profiles,
		indices[:],
		visible_only = true,
	)
	current := ""
	if mode == .Swap_Pane {
		if entry := focused_session(app, w); entry != nil {current = entry.profile_id}
	}
	for i in 0..<count {
		profile := &app.settings.profiles.items[indices[i]]
		checked := profile.id == current
		if mode == .New_Tab {checked = profile.id == app.settings.profiles.default_id}
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
	ui.menu_anchor(&menu.menu, x, y)
	menu.menu.open = true
	menu.menu.selected = -1
	ui.menu_step(&menu.menu, 1)
	w.dirty = true
}

profile_menu_open_new_tab :: proc(app: ^App, w: ^Window, x, y: f32) {
	profile_menu_open(app, w, .New_Tab, x, y)
}

profile_menu_open_pane :: proc(
	app: ^App,
	w: ^Window,
	pane: layout.Node_Id,
	x, y: f32,
) {
	profile_menu_open(app, w, .Swap_Pane, x, y, pane)
}

profile_menu_choose :: proc(app: ^App, w: ^Window) {
	menu := &w.profile_menu
	index := menu.menu.selected
	if index < 0 || index >= menu.count {return}
	entry := menu.entries[index]
	if entry.action == .None {return}
	menu.menu.open = false
	w.dirty = true
	switch entry.action {
	case .None:
	case .Profile:
		switch menu.mode {
		case .New_Tab:
			tab_new_profile(app, w, entry.visible_index)
		case .Swap_Pane:
			pane_shell_swap_request(app, w, menu.pane, entry.profile_id)
		case .None:
		}
	case .Settings:
		editor_open(app, w)
	case .Palette:
		palette_open(app, w)
	}
}

profile_menu_key :: proc(app: ^App, w: ^Window, e: platform.Key_Event) -> bool {
	if !w.profile_menu.open {return false}
	switch ui.menu_key(&w.profile_menu.menu, e) {
	case .None:
	case .Changed:
		w.dirty = true
	case .Chosen:
		profile_menu_choose(app, w)
	case .Closed:
		w.dirty = true
	}
	return true
}

profile_menu_hit :: proc(w: ^Window, x, y: f32) -> int {
	if !w.profile_menu.open {return -1}
	return ui.menu_hit(
		&w.profile_menu.menu,
		x,
		y,
		f32(w.width),
		f32(w.height),
		w.scale,
	)
}

profile_menu_button :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) -> bool {
	if !w.profile_menu.open {return false}
	if !e.pressed {
		if e.button in w.header_buttons {w.header_buttons -= {e.button}}
		return true
	}
	w.header_buttons += {e.button}
	if hit := profile_menu_hit(w, f32(e.x), f32(e.y)); hit >= 0 && e.button == .Left {
		item := w.profile_menu.menu.items[hit]
		if item.enabled && !item.separator {
			w.profile_menu.menu.selected = hit
			profile_menu_choose(app, w)
		}
	} else if hit < 0 {
		w.profile_menu.open = false
		w.dirty = true
	}
	return true
}

profile_menu_draw :: proc(app: ^App, w: ^Window) -> glyphs.Result {
	if !w.profile_menu.open {return .Ok}
	return ui.menu_draw(
		&w.profile_menu.menu,
		&w.list,
		&w.ui_text,
		app.theme,
		f32(w.width),
		f32(w.height),
		w.scale,
	)
}
