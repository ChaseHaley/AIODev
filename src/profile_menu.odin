package main

import "aio:input"
import "aio:commands"
import "aio:layout"
import "aio:render"
import "aio:settings"
import "aio:ui"
import "core:log"
import "aio:platform"

// Where a choice from the shared content list goes.
Profile_Menu_Mode :: union #no_nil {
	Profile_Menu_New_Tab,
	Profile_Menu_Swap_Pane,
	Profile_Menu_Split,
}

Profile_Menu_New_Tab :: struct {}

// Holds the target by content, so an open menu cannot act on a node another pane has reused.
Profile_Menu_Swap_Pane :: struct {
	pane: layout.Content,
}

Profile_Menu_Split :: struct {
	pane:      layout.Content,
	direction: layout.Direction,
}

Profile_Menu_Action :: enum {
	None,
	Profile,
	Markdown,
	Web,
}

// What a row does. A profile row keeps its own copy of the profile's id: a settings reload frees the
// profiles while the menu can still show.
Profile_Menu_Entry :: struct {
	action:    Profile_Menu_Action,
	id:        [settings.PROFILE_ID_MAX_LENGTH]u8,
	id_length: int,
}

// The same content list serves New tab, the pane badge and the split buttons. Whether it shows,
// and for which, is w.overlay.
Profile_Menu :: struct {
	using menu: ui.Menu,
	// Each row's payload keys its entry.
	entries:    [ui.MENU_MAX_ITEMS]Profile_Menu_Entry,
	count:      int,
	// The shortcut labels the rows show, as bound when the menu opened.
	shortcuts:  [PROFILE_ACTION_COUNT][commands.SHORTCUT_TEXT_CAP]u8,
}

// Every visible profile, two content choices and their separator.
#assert(settings.PROFILE_LIMIT + 3 <= ui.MENU_MAX_ITEMS)

// The New Tab with Profile N commands label their rows only in the New tab menu.
@(private)
PROFILE_ACTION_COUNT :: int(Action.Profile_9) - int(Action.Profile_1) + 1

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

// The label of the first shortcut that runs `action` now, kept in the menu's slot `slot`.
@(private)
profile_menu_shortcut :: proc(app: ^App, menu: ^Profile_Menu, slot: int, action: Action) -> string {
	return action_shortcut_text(app, action, menu.shortcuts[slot][:])
}

profile_menu_entry_id :: proc(entry: ^Profile_Menu_Entry) -> string {
	return string(entry.id[:entry.id_length])
}

// The entry row `row` stands for, or none for a row out of range.
profile_menu_entry :: proc(menu: ^Profile_Menu, row: int) -> (Profile_Menu_Entry, bool) {
	if row < 0 || row >= len(menu.items) {return {}, false}
	key := int(menu.items[row].payload)
	if key >= menu.count {return {}, false}
	return menu.entries[key], true
}

@(private)
profile_menu_push :: proc(
	menu: ^Profile_Menu,
	item: ui.Menu_Item,
	action: Profile_Menu_Action,
	profile_id := "",
) {
	entry := Profile_Menu_Entry{action = action}
	entry.id_length = copy(entry.id[:], profile_id)
	// Settings validate ids to fit; a longer one would launch the wrong profile.
	if entry.id_length < len(profile_id) {
		log.errorf("profile menu skipped profile %q: its id is too long", profile_id)
		return
	}
	row := item
	row.payload = u32(menu.count)
	added, err := ui.menu_add(&menu.menu, row)
	if err != nil {log.errorf("adding a profile menu row failed: %v", err)}
	if !added {return}
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
	target, swap := mode.(Profile_Menu_Swap_Pane)
	_, new_tab := mode.(Profile_Menu_New_Tab)
	current := ""
	if new_tab {current = app.settings.profiles.default_id}
	if swap {
		if entry := workspace_session_for_content(app, target.pane); entry != nil {current = entry.profile_id}
	}
	for i in 0..<count {
		profile := &app.settings.profiles.items[indices[i]]
		checked := profile.id == current
		shortcut := ""
		if action, bound := profile_action(i); new_tab && bound {
			shortcut = profile_menu_shortcut(app, menu, i, action)
		}
		profile_menu_push(
			menu,
			{
				label = profile.name,
				shortcut = shortcut,
				icon = settings.shell_badge(profile.command),
				checked = checked,
				enabled = true,
			},
			.Profile,
			profile.id,
		)
	}
	if count > 0 {profile_menu_push(menu, {separator = true}, .None)}
	profile_menu_push(menu, {label = "Markdown file…", glyph = .Markdown, enabled = true}, .Markdown)
	in_web := swap && target.pane.kind == .Web
	profile_menu_push(menu, {label = "Web pane", glyph = .Globe, checked = in_web, enabled = !in_web}, .Web)
	ui.menu_anchor(&menu.menu, x, y)
	ui.menu_select_edge(&menu.menu, false)
}

profile_menu_open_new_tab :: proc(app: ^App, w: ^Window, x, y: f32) {
	profile_menu_open(app, w, Profile_Menu_New_Tab{}, x, y)
}

// Opens the content menu for a shown pane, below the start of its header.
profile_menu_open_pane :: proc(app: ^App, w: ^Window, pane: layout.Pane_Rect) {
	x, y := pane.rect.x + 8 * w.scale, pane.rect.y + ui.HEADER_HEIGHT * w.scale
	profile_menu_open(app, w, Profile_Menu_Swap_Pane{pane.content}, x, y)
}

profile_menu_choose :: proc(app: ^App, w: ^Window) {
	shown, ok := w.overlay.(Overlay_Profile_Menu)
	if !ok {return}
	menu := &w.profile_menu
	entry, listed := profile_menu_entry(menu, ui.menu_selected(&menu.menu))
	if !listed || entry.action == .None || !menu.items[ui.menu_selected(&menu.menu)].enabled {return}
	overlay_close(app, w)
	switch entry.action {
	case .None:
	case .Profile:
		if _, new_tab := shown.mode.(Profile_Menu_New_Tab); new_tab {
			tab_new_profile_id(app, w, profile_menu_entry_id(&entry))
			rail_overlay_dismiss(app, w)
		} else {
			pane_content_menu_choose(app, w, shown.mode, .Terminal, profile_menu_entry_id(&entry))
		}
	case .Markdown:
		markdown_open_picker(app, w, shown.mode)
	case .Web:
		pane_content_menu_choose(app, w, shown.mode, .Web, "")
	}
}

profile_menu_key :: proc(app: ^App, w: ^Window, e: input.Key_Event) -> bool {
	if !profile_menu_shown(w) {return false}
	switch ui.menu_key(&w.profile_menu.menu, e) {
	case .None, .Submenu:
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

profile_menu_button :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) {
	if !profile_menu_shown(w) {return}
	if !e.pressed {
		w.dirty = true
		return
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
}

profile_menu_draw :: proc(app: ^App, w: ^Window) -> render.Build_Status {
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

when AIO_CONTROL {
	profile_menu_state_report :: proc(r: ^State_Report, w: ^Window) {
		shown := profile_menu_shown(w)
		state_value(r, "profile_menu.open", shown)
		state_value(r, "profile_menu.count", w.profile_menu.count)
		if shown {
			for item, i in w.profile_menu.items {
				state_text(r, state_key("profile_menu.row.%d.label", i + 1), item.label)
			}
		}
	}
}

// Profile menu pointer surface

@(private)
profile_menu_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {return profile_menu_shown(w)}

@(private)
profile_menu_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: input.Mouse_Move_Event) {
	if owner != .Profile_Menu {return}
	x, y := f32(e.x), f32(e.y)
	shape := platform.Cursor_Shape.Arrow
	if hit := profile_menu_hit(w, x, y); hit >= 0 {
		if hit != ui.menu_selected(&w.profile_menu.menu) {
			ui.menu_select(&w.profile_menu.menu, hit)
			w.dirty = true
		}
		item := w.profile_menu.menu.items[hit]
		if item.enabled && !item.separator {shape = .Hand}
	}
	pointer_set(app, w, shape)
}
