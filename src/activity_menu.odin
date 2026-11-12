package main

import "aio:input"
import "aio:render"
import "aio:settings"
import "aio:ui"
import "core:log"

// The Activity header's two menus (WORK-406, WORK-412). Show picks what names each row and which
// terms follow the name; Group by picks how reports group and sort. Both save the same settings the
// Settings page shows, so every window, the panel and the inbox follow them. Show stays open while
// terms are toggled; Group by closes on a choice.

Activity_Menu_Kind :: enum u8 {
	Show,
	Group,
}

// What a row of either menu sets: the payload holds the section above the value.
@(private = "file")
Activity_Menu_Section :: enum u32 {
	Heading,
	Name,
	Term,
	Group,
}

@(private = "file")
ACTIVITY_MENU_WIDTH :: f32(240)

@(private = "file")
activity_menu_payload :: proc(section: Activity_Menu_Section, value: int) -> u32 {
	return u32(section) << 8 | u32(value)
}

// The term a row name repeats, which Also show greys out while it names the rows.
@(private = "file", rodata)
ACTIVITY_NAME_TERM := [settings.Status_Row_Name]settings.Status_Row_Term {
	.Pane    = .Pane,
	.Program = .Program,
	.Tab     = .Tab,
	.Folder  = .Folder,
}

activity_menu_shown :: proc(w: ^Window, kind: Maybe(Activity_Menu_Kind) = nil) -> bool {
	menu, shown := w.overlay.(Overlay_Activity_Menu)
	want, filtered := kind.?
	return shown && (!filtered || menu.kind == want)
}

// Opens the menu under its header button; the same button closes it again.
activity_menu_toggle :: proc(app: ^App, w: ^Window, kind: Activity_Menu_Kind, button: render.Rect) {
	if activity_menu_shown(w, kind) {
		overlay_close(app, w)
		return
	}
	if !gesture_cancel(app, w) {return}
	overlay_open(app, w, Overlay_Activity_Menu{kind})
	menu := &w.activity_menu
	menu.width = ACTIVITY_MENU_WIDTH
	ui.menu_anchor(menu, button.x + button.width - ACTIVITY_MENU_WIDTH * w.scale, button.y + button.height)
	if !activity_menu_build(app, w, kind) {return}
	ui.menu_select_edge(menu, false)
}

// Rebuilds the rows from the settings, keeping the selection, so a toggle shows its new state.
@(private = "file")
activity_menu_build :: proc(app: ^App, w: ^Window, kind: Activity_Menu_Kind) -> bool {
	menu := &w.activity_menu
	selected := ui.menu_selected(menu)
	ui.menu_clear(menu)
	s := &app.settings.status
	add :: proc(menu: ^ui.Menu, item: ui.Menu_Item) -> bool {
		added, err := ui.menu_add(menu, item)
		if !added {log.errorf("adding an Activity menu row failed: %v", err)}
		return added
	}
	heading :: proc(menu: ^ui.Menu, label: string) -> bool {
		return add(menu, {label = label, payload = activity_menu_payload(.Heading, 0)})
	}
	ok := true
	switch kind {
	case .Show:
		@(static, rodata)
		names := settings.STATUS_ROW_NAME_LABEL
		ok &&= heading(menu, "Name rows by")
		for name in settings.Status_Row_Name {
			item := ui.Menu_Item {
				label   = names[name],
				checked = s.row_name == name,
				enabled = true,
				payload = activity_menu_payload(.Name, int(name)),
			}
			ok &&= add(menu, item)
		}
		ok &&= add(menu, {separator = true})
		@(static, rodata)
		terms := settings.STATUS_ROW_TERM_LABEL
		ok &&= heading(menu, "Also show")
		for t in settings.Status_Row_Term {
			item := ui.Menu_Item {
				label   = terms[t],
				checked = t in s.row_terms,
				enabled = t != ACTIVITY_NAME_TERM[s.row_name],
				payload = activity_menu_payload(.Term, int(t)),
			}
			ok &&= add(menu, item)
		}
	case .Group:
		@(static, rodata)
		groups := settings.STATUS_GROUP_LABEL
		ok &&= heading(menu, "Group by")
		for group in settings.Status_Group {
			item := ui.Menu_Item {
				label   = groups[group],
				checked = s.group_by == group,
				enabled = true,
				payload = activity_menu_payload(.Group, int(group)),
			}
			ok &&= add(menu, item)
		}
	}
	if !ok {
		overlay_close(app, w)
		return false
	}
	ui.menu_select(menu, selected)
	return true
}

activity_menu_choose :: proc(app: ^App, w: ^Window) {
	current, shown := w.overlay.(Overlay_Activity_Menu)
	index := ui.menu_selected(&w.activity_menu)
	if !shown || index < 0 {return}
	item := w.activity_menu.items[index]
	if !item.enabled || item.separator {return}
	s := &app.settings.status
	value := int(item.payload & 0xff)
	switch Activity_Menu_Section(item.payload >> 8) {
	case .Heading:
		return
	case .Name:
		@(static, rodata)
		names := settings.STATUS_ROW_NAME_NAME
		name := settings.Status_Row_Name(value)
		settings_save_value(app, "status.row_name", names[name], "Could not save the Activity row name.")
	case .Term:
		terms := s.row_terms ~ {settings.Status_Row_Term(value)}
		text := settings.set_text(settings.STATUS_ROW_TERM_NAMES, transmute(u32)terms)
		settings_save_value(app, "status.row_terms", text, "Could not save the Activity row details.")
	case .Group:
		overlay_close(app, w)
		@(static, rodata)
		groups := settings.STATUS_GROUP_NAME
		group := settings.Status_Group(value)
		settings_save_value(app, "status.group_by", groups[group], "Could not save the Activity grouping.")
		return
	}
	if activity_menu_shown(w, current.kind) {_ = activity_menu_build(app, w, current.kind)}
}

activity_menu_key :: proc(app: ^App, w: ^Window, e: input.Key_Event) {
	if !e.pressed {return}
	w.dirty = true
	switch ui.menu_key(&w.activity_menu, e) {
	case .None, .Submenu:
	case .Changed: ui.menu_reveal(&w.activity_menu, f32(w.width), f32(w.height), w.scale)
	case .Chosen: activity_menu_choose(app, w)
	case .Closed: overlay_close(app, w)
	}
}

activity_menu_wheel :: proc(w: ^Window, rows: int) {
	ui.menu_wheel(&w.activity_menu, rows)
	ui.menu_reveal(&w.activity_menu, f32(w.width), f32(w.height), w.scale)
	w.dirty = true
}

activity_menu_hit :: proc(w: ^Window, x, y: f32) -> int {
	return ui.menu_hit(&w.activity_menu, x, y, f32(w.width), f32(w.height), w.scale)
}

activity_menu_draw :: proc(app: ^App, w: ^Window) -> render.Build_Status {
	width, height := f32(w.width), f32(w.height)
	return ui.menu_draw(&w.activity_menu, &w.list, &w.ui_text, app.theme, width, height, w.scale, w.pointer)
}

when AIO_CONTROL {
	// The open Activity menu's verification keys.
	activity_menu_state_report :: proc(r: ^State_Report, w: ^Window) {
		current, shown := w.overlay.(Overlay_Activity_Menu)
		@(static, rodata)
		kinds := [Activity_Menu_Kind]string {
			.Show  = "show",
			.Group = "group",
		}
		state_text(r, "activity.menu", shown ? kinds[current.kind] : "")
		if !shown {return}
		menu := &w.activity_menu
		state_value(r, "activity.menu.count", len(menu.items))
		for item, i in menu.items {
			rect := ui.menu_row_rect(menu, i, f32(w.width), f32(w.height), w.scale)
			state_text(r, state_key("activity.menu.row.%d.label", i + 1), item.label)
			state_value(r, state_key("activity.menu.row.%d.checked", i + 1), item.checked)
			state_value(r, state_key("activity.menu.row.%d.enabled", i + 1), item.enabled && !item.separator)
			state_rect(r, state_key("activity.menu.row.%d.rect", i + 1), rect)
		}
	}
}

// Activity menu pointer surface

@(private)
activity_menu_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {return activity_menu_shown(w)}

@(private)
activity_menu_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: input.Mouse_Move_Event) {
	if owner != .Activity_Menu {return}
	hit := activity_menu_hit(w, f32(e.x), f32(e.y))
	enabled := hit >= 0 && w.activity_menu.items[hit].enabled
	if enabled && hit != ui.menu_selected(&w.activity_menu) {
		ui.menu_select(&w.activity_menu, hit)
		w.dirty = true
	}
	pointer_set(app, w, enabled ? .Hand : .Arrow)
}

// A left press on a row chooses it. A press on the button that opened the menu closes it, as does any
// other press outside it.
@(private)
activity_menu_button :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) {
	if !e.pressed {return}
	gesture_swallow(w, e.button, .Activity_Menu)
	hit := activity_menu_hit(w, f32(e.x), f32(e.y))
	if hit < 0 || e.button != .Left {
		overlay_close(app, w)
		return
	}
	if w.activity_menu.items[hit].enabled {
		ui.menu_select(&w.activity_menu, hit)
		activity_menu_choose(app, w)
	}
}
