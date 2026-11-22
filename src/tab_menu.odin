package main

import "cosmos:input"
import "aio:commands"
import "aio:layout"
import "cosmos:render"
import "aio:ui"
import "core:fmt"
import "core:log"
import "core:time"

// A tab group submenu is as wide as its longest row needs, at most this.
TAB_SUBMENU_WIDTH :: f32(220)

// The rows of the tab menu, each keyed by the Action it runs. Which tab it shows for is w.overlay. The same
// rows serve a group's chip, as the group menu.
Tab_Menu :: struct {
	using menu:  ui.Menu,
	// The Close row's text while it covers a marked group; see tab_menu_sync.
	close_label: [32]u8,
	// The groups to add to, or the colours to give a group, beside the row that leads there. Rows carry a
	// group id (0 for a new group) or a colour index.
	submenu:     Menu_Submenu,
}

tab_menu_init :: proc(menu: ^Tab_Menu) {
	ui.menu_init(&menu.menu)
	ui.menu_init(&menu.submenu.menu)
}

tab_menu_destroy :: proc(menu: ^Tab_Menu) {
	ui.menu_destroy(&menu.menu)
	ui.menu_destroy(&menu.submenu.menu)
}

tab_menu_shown :: proc(w: ^Window) -> bool {
	_, shown := w.overlay.(Overlay_Tab_Menu)
	return shown
}

// The index of the tab the open menu acts on, or -1. A group menu acts on its group's first tab.
tab_menu_target :: proc(w: ^Window) -> int {
	menu, shown := w.overlay.(Overlay_Tab_Menu)
	if !shown {return -1}
	if menu.group != 0 {
		first, _ := tab_group_span(w.workspace, menu.group)
		return first
	}
	return tab_index_by_id(w.workspace, menu.tab)
}

// The group the open menu is for, or nil for a tab's menu.
tab_menu_group :: proc(w: ^Window) -> ^Tab_Group {
	menu, shown := w.overlay.(Overlay_Tab_Menu)
	if !shown {return nil}
	return tab_group_find(w.workspace, menu.group)
}

// How many tabs the menu's actions cover: the marked group when the target is in it, else the target alone.
tab_menu_scope :: proc(w: ^Window) -> int {
	target := tab_menu_target(w)
	if target < 0 || !w.workspace.tabs[target].marked {return 1}
	count := 0
	for tab in w.workspace.tabs {if tab.marked {count += 1}}
	return count
}

// Whether tab `index` draws as marked. While the menu is open on an unmarked tab, only that tab does. A
// group held by its chip marks its tabs only to carry them; the group's outline shows it is held instead.
tab_marked_shown :: proc(w: ^Window, index: int) -> bool {
	tab := w.workspace.tabs[index]
	if held := tab_group_held(w); held != 0 && tab.group == held {return false}
	target := tab_menu_target(w)
	if target >= 0 && tab_menu_group(w) == nil && !w.workspace.tabs[target].marked {return index == target}
	return tab.marked
}

tab_menu_open :: proc(app: ^App, w: ^Window, index: int, x, y: f32) {
	if index < 0 || index >= len(w.workspace.tabs) {return}
	if !gesture_cancel(app, w) {return}
	overlay_open(app, w, Overlay_Tab_Menu{tab = w.workspace.tabs[index].id})
	menu := &w.tab_menu
	ui.menu_clear(&menu.menu)
	ui.menu_anchor(&menu.menu, x, y)
	// A nil row is a separator. Several marked tabs drop the rows that name one tab.
	several := tab_menu_scope(w) > 1
	head := [?]Maybe(Action){.Rename_Tab, .Duplicate_Tab, nil}
	grouped := false
	for tab in tab_group_scope(w.workspace, index) {grouped ||= tab.group != 0}
	groups := [?]Maybe(Action){.Add_Tab_To_Group, .Remove_Tab_From_Group, nil}
	if !grouped {groups[1] = nil}
	single := [?]Maybe(Action){.Move_Tab_Workspace, .Move_Tab_New_Workspace, .Close_Right_Tabs}
	every := [?]Maybe(Action){.Close_Other_Tabs, .Close_Tab, nil, .Tab_Settings}
	if !several && !tab_menu_add_rows(app, w, head[:]) {return}
	if !tab_menu_add_rows(app, w, groups[:grouped ? 3 : 2]) {return}
	if !several && !tab_menu_add_rows(app, w, single[:]) {return}
	if !tab_menu_add_rows(app, w, every[:]) {return}
	tab_menu_show(w)
}

// Opens group `id`'s menu at a point, as a right click on its chip does.
tab_group_menu_open :: proc(app: ^App, w: ^Window, id: u32, x, y: f32) {
	first, _ := tab_group_span(w.workspace, id)
	if first < 0 || !gesture_cancel(app, w) {return}
	overlay_open(app, w, Overlay_Tab_Menu{tab = w.workspace.tabs[first].id, group = id})
	menu := &w.tab_menu
	ui.menu_clear(&menu.menu)
	ui.menu_anchor(&menu.menu, x, y)
	rows := [?]Maybe(Action) {
		.Rename_Tab_Group,
		.Tab_Group_Color,
		nil,
		.Fold_Tab_Group,
		.New_Tab_In_Group,
		.Move_Tab_Group_Workspace,
		nil,
		.Ungroup_Tabs,
		.Close_Tab_Group,
	}
	if !tab_menu_add_rows(app, w, rows[:]) {return}
	tab_menu_show(w)
}

@(private = "file")
tab_menu_show :: proc(w: ^Window) {
	submenu_reset(&w.tab_menu.submenu)
	tab_menu_sync(w)
	ui.menu_select(&w.tab_menu.menu, -1)
	ui.menu_step(&w.tab_menu.menu, 1)
	tab_menu_reveal(w)
}

// A row the menu cannot hold closes it rather than offer part of the list.
@(private = "file")
tab_menu_add_rows :: proc(app: ^App, w: ^Window, rows: []Maybe(Action)) -> bool {
	for row in rows {
		item := ui.Menu_Item{separator = true}
		if action, named := row.?; named {
			item = {label = tab_menu_action_label(action), payload = u32(action)}
			item.submenu = action == .Add_Tab_To_Group || action == .Tab_Group_Color
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
	case .Rename_Tab: return "Rename…"
	case .Duplicate_Tab: return "Duplicate"
	case .Close_Right_Tabs: return "Close to the right"
	case .Close_Other_Tabs: return "Close others"
	case .Close_Tab: return "Close"
	case .Add_Tab_To_Group: return "Add to group"
	case .Remove_Tab_From_Group: return "Remove from group"
	case .Rename_Tab_Group: return "Rename group…"
	case .Tab_Group_Color: return "Color"
	case .Fold_Tab_Group: return "Fold"
	case .New_Tab_In_Group: return "New tab in group"
	case .Move_Tab_Group_Workspace: return "Move group to workspace…"
	case .Ungroup_Tabs: return "Ungroup"
	case .Close_Tab_Group: return "Close group"
	}
	@(static, rodata) actions := ACTIONS
	return actions[action].title
}

// The rows act on a tab that can close or change while the menu shows, so every reader of the rows
// brings their enabled state, the Close row's count and the fold row's wording up to date first.
tab_menu_sync :: proc(w: ^Window) {
	menu := &w.tab_menu
	for &item, i in menu.items {
		if item.separator {continue}
		item.enabled = tab_menu_enabled(w, i)
		#partial switch Action(item.payload) {
		case .Close_Tab:
			count := tab_menu_scope(w)
			item.label = count > 1 ? fmt.bprintf(menu.close_label[:], "Close %d selected tabs", count) : "Close"
		case .Fold_Tab_Group:
			if group := tab_menu_group(w); group != nil {item.label = group.folded ? "Unfold" : "Fold"}
		}
	}
}

// Whether row `index` runs now; tab rows need their target, which can close while the menu shows.
tab_menu_enabled :: proc(w: ^Window, index: int) -> bool {
	if index < 0 || index >= len(w.tab_menu.items) || w.tab_menu.items[index].separator {return false}
	target := tab_menu_target(w)
	#partial switch Action(w.tab_menu.items[index].payload) {
	case .Rename_Tab, .Move_Tab_Workspace, .Move_Tab_New_Workspace, .Close_Tab, .Add_Tab_To_Group,
	     .Remove_Tab_From_Group:
		return target >= 0
	case .Rename_Tab_Group, .Tab_Group_Color, .Fold_Tab_Group, .New_Tab_In_Group, .Move_Tab_Group_Workspace,
	     .Ungroup_Tabs, .Close_Tab_Group:
		return tab_menu_group(w) != nil
	case .Duplicate_Tab:
		if target < 0 {return false}
		content, ok := layout.focused_content(&w.workspace.tabs[target].tree)
		return ok && pane_owns_session(content.kind)
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
	if w.tab_menu.items[index].submenu {
		tab_submenu_open(app, w, index, true)
		return
	}
	action := Action(w.tab_menu.items[index].payload)
	target := tab_menu_target(w)
	overlay_close(app, w)
	invocation := commands.invocation(commands.Command_Id(action), focus = true)
	_ = command_execute(app, Window_Context{window = w, tab = target, origin = .Menu}, invocation)
}

// Fills the submenu of row `row`: the groups to add the tabs to, after New Group, or a group's colours.
@(private = "file")
tab_submenu_open :: proc(app: ^App, w: ^Window, row: int, select_first: bool) {
	menu := &w.tab_menu
	sub := &menu.submenu
	if row < 0 || row >= len(menu.items) || !menu.items[row].submenu || !tab_menu_enabled(w, row) {
		submenu_close(w, sub)
		return
	}
	if current, open := sub.row.?; open && current == row && !select_first {return}
	ui.menu_clear(&sub.menu)
	add :: proc(sub: ^Menu_Submenu, item: ui.Menu_Item) {_, _ = ui.menu_add(&sub.menu, item)}
	if Action(menu.items[row].payload) == .Tab_Group_Color {
		group := tab_menu_group(w)
		if group == nil {return}
		@(static, rodata) colors := WORKSPACE_ICON_COLORS
		for color, i in colors[1:] {
			swatch := workspace_icon_tint(i + 1, app.theme.text)
			// A colour another group of this name has is taken (WORK-460).
			free := !tab_group_taken(w.workspace, group.name, i + 1, group.id)
			add(sub, {label = color.name, swatch = swatch, checked = group.color == i + 1, enabled = free,
				payload = u32(i + 1)})
		}
	} else {
		add(sub, {label = "New group", glyph = .Add, enabled = true, payload = 0})
		scope := tab_group_scope(w.workspace, tab_menu_target(w))
		divided := false
		for tab in w.workspace.tabs {
			group := tab_group_find(w.workspace, tab.group)
			if group == nil {continue}
			// A group lists once, at its first tab, unless every tab the menu covers is already in it.
			first, _ := tab_group_span(w.workspace, group.id)
			if w.workspace.tabs[first] != tab {continue}
			inside := true
			for covered in scope {inside &&= covered.group == group.id}
			if inside {continue}
			if !divided {add(sub, {separator = true}); divided = true}
			label := group.name != "" ? group.name : "Unnamed group"
			add(sub, {label = label, swatch = tab_group_color(app, group), enabled = true, payload = group.id})
		}
	}
	submenu_place(w, sub, &menu.menu, row, TAB_SUBMENU_WIDTH, select_first)
}

// Runs submenu row `index`: adds the tabs to a group, new or not, or gives the group a colour.
@(private = "file")
tab_submenu_choose :: proc(app: ^App, w: ^Window, index: int) {
	sub := &w.tab_menu.submenu
	row, open := sub.row.?
	if !open || index < 0 || index >= len(sub.items) || sub.items[index].separator {return}
	payload := sub.items[index].payload
	action := Action(w.tab_menu.items[row].payload)
	target := tab_menu_target(w)
	group := tab_menu_group(w)
	overlay_close(app, w)
	if target < 0 {return}
	switch {
	case action == .Tab_Group_Color && group != nil:
		_ = tab_group_color_set(app, w, group.id, int(payload))
	case action == .Add_Tab_To_Group && payload == 0:
		created := tab_group_create(app, w, target)
		if created == nil {notify(app, .Error, "Could not make the group."); return}
		tab_group_name_begin(app, w, created.id, true)
	case action == .Add_Tab_To_Group:
		tab_group_add(app, w, target, payload)
	}
}

tab_submenu_tick :: proc(app: ^App, w: ^Window, now: time.Tick) {
	if !tab_menu_shown(w) {return}
	if submenu_tick(app, w, &w.tab_menu.submenu, &w.tab_menu.menu, tab_submenu_open, now) {
		tab_menu_hover_at(app, w, w.pointer.x, w.pointer.y)
	}
}

tab_submenu_deadline :: proc(w: ^Window) -> (time.Tick, bool) {
	if !tab_menu_shown(w) {return {}, false}
	return submenu_deadline(&w.tab_menu.submenu)
}

tab_submenu_shown :: proc(w: ^Window) -> bool {
	return tab_menu_shown(w) && submenu_shown(&w.tab_menu.submenu)
}

tab_menu_key :: proc(app: ^App, w: ^Window, e: input.Key_Event) {
	if !e.pressed {return}
	w.dirty = true
	tab_menu_sync(w)
	switch submenu_key(w, &w.tab_menu.submenu, e) {
	case .Pass:
	case .Taken: return
	case .Chosen:
		tab_submenu_choose(app, w, ui.menu_selected(&w.tab_menu.submenu.menu))
		return
	}
	switch ui.menu_key(&w.tab_menu.menu, e) {
	case .None:
	case .Submenu: tab_submenu_open(app, w, ui.menu_selected(&w.tab_menu.menu), true)
	case .Changed:
		submenu_close(w, &w.tab_menu.submenu)
		tab_menu_reveal(w)
	case .Chosen: tab_menu_choose(app, w)
	case .Closed: overlay_close(app, w)
	}
}

// Opens tab `index`'s menu at that tab, as the keyboard does: below it on the strip, or below the start
// of its row on the rail.
tab_menu_open_at :: proc(app: ^App, w: ^Window, index: int) {
	if w.workspace == nil || index < 0 || index >= len(w.workspace.tabs) {return}
	if w.tabs_horizontal {
		r := window_tab_rect(app, w, index)
		tab_menu_open(app, w, index, r.x, r.height)
	} else {
		row := rail_row_rect_for_tab(w, index)
		if row.height <= 0 {
			row = {16, ui.TITLE_BAR_HEIGHT * w.scale, 1, 1}
		}
		tab_menu_open(app, w, index, row.x + 16 * w.scale, row.y + row.height)
	}
}

// A key bound to tab.context_menu (Menu and Shift+F10 by default, the native context-menu keys) opens the
// selected tab's menu before settings fields, the find bar and the focused pane see the key. A linked
// window shows no tabs, so the key goes on to its pane.
tab_menu_key_open :: proc(app: ^App, w: ^Window, e: input.Key_Event) -> bool {
	if !e.pressed || window_linked(w) {return false}
	if action, found := shortcut_action(app, e); !found || action != .Tab_Context_Menu {return false}
	tab_menu_open_at(app, w, w.workspace.selected)
	key_suppress(w, e)
	return true
}

tab_menu_wheel :: proc(w: ^Window, rows: int) {
	tab_menu_sync(w)
	submenu_close(w, &w.tab_menu.submenu)
	ui.menu_wheel(&w.tab_menu.menu, rows)
	tab_menu_reveal(w)
	w.dirty = true
}

tab_menu_draw :: proc(app: ^App, w: ^Window) -> render.Build_Status {
	tab_menu_sync(w)
	width, height := f32(w.width), f32(w.height)
	menu := ui.menu_draw(&w.tab_menu.menu, &w.list, &w.ui_text, app.theme, width, height, w.scale, w.pointer)
	if menu != .Ok || !tab_submenu_shown(w) {return menu}
	sub := &w.tab_menu.submenu.menu
	return ui.menu_draw(sub, &w.list, &w.ui_text, app.theme, width, height, w.scale, w.pointer)
}

when AIO_CONTROL {
	// The tab menu's verification keys. The dock edge menu reports under them while it shows, as it
	// did when it shared this surface. Like every reader of the rows, the report syncs them first.
	tab_menu_state_report :: proc(r: ^State_Report, w: ^Window) {
		divider := dock_divider_menu_shown(w)
		menu := &w.tab_menu.menu
		if divider {menu = &w.divider_menu} else {tab_menu_sync(w)}
		action: Action
		if index := ui.menu_selected(&w.tab_menu.menu); index >= 0 && !w.tab_menu.items[index].separator {
			action = Action(w.tab_menu.items[index].payload)
		}
		state_value(r, "tab_menu.open", tab_menu_shown(w) || divider)
		state_value(r, "tab_menu.group", tab_menu_group(w) != nil)
		state_value(r, "tab_menu.count", len(menu.items))
		state_value(r, "tab_menu.action", action)
		for item, i in menu.items {
			enabled := divider ? item.enabled && !item.separator : tab_menu_enabled(w, i)
			rect := ui.menu_row_rect(menu, i, f32(w.width), f32(w.height), w.scale)
			state_text(r, state_key("tab_menu.row.%d.label", i + 1), item.label)
			state_value(r, state_key("tab_menu.row.%d.separator", i + 1), item.separator)
			state_value(r, state_key("tab_menu.row.%d.enabled", i + 1), enabled)
			state_rect(r, state_key("tab_menu.row.%d.rect", i + 1), rect)
		}
		sub := &w.tab_menu.submenu.menu
		shown := !divider && tab_submenu_shown(w)
		state_value(r, "tab_menu.submenu.open", shown)
		state_value(r, "tab_menu.submenu.count", shown ? len(sub.items) : 0)
		if !shown {return}
		for item, i in sub.items {
			rect := ui.menu_row_rect(sub, i, f32(w.width), f32(w.height), w.scale)
			state_text(r, state_key("tab_menu.submenu.row.%d.label", i + 1), item.label)
			state_value(r, state_key("tab_menu.submenu.row.%d.separator", i + 1), item.separator)
			state_value(r, state_key("tab_menu.submenu.row.%d.checked", i + 1), item.checked)
			state_rect(r, state_key("tab_menu.submenu.row.%d.rect", i + 1), rect)
		}
	}
}

// Tab menu pointer surface

@(private)
tab_menu_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {return tab_menu_shown(w)}

@(private)
tab_menu_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: input.Mouse_Move_Event) {
	if owner != .Tab_Menu {return}
	tab_menu_hover_at(app, w, f32(e.x), f32(e.y))
}

@(private = "file")
tab_menu_hover_at :: proc(app: ^App, w: ^Window, x, y: f32) {
	if submenu_hover(app, w, &w.tab_menu.submenu, &w.tab_menu.menu, tab_submenu_open, x, y) {
		over := ui.menu_hit(&w.tab_menu.submenu.menu, x, y, f32(w.width), f32(w.height), w.scale) >= 0
		pointer_set(app, w, over ? .Hand : .Arrow)
		return
	}
	hit := tab_menu_hit(w, x, y)
	enabled := tab_menu_enabled(w, hit)
	if enabled && hit != ui.menu_selected(&w.tab_menu.menu) {
		ui.menu_select(&w.tab_menu.menu, hit)
		w.dirty = true
	}
	pointer_set(app, w, enabled ? .Hand : .Arrow)
}

@(private)
tab_menu_button :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) {
	if !e.pressed {return}
	gesture_swallow(w, e.button, .Tab_Menu)
	x, y := f32(e.x), f32(e.y)
	if tab_submenu_shown(w) {
		sub := &w.tab_menu.submenu.menu
		if hit := ui.menu_hit(sub, x, y, f32(w.width), f32(w.height), w.scale); hit >= 0 {
			if e.button == .Left && sub.items[hit].enabled && !sub.items[hit].separator {
				tab_submenu_choose(app, w, hit)
			}
			return
		}
	}
	if hit := tab_menu_hit(w, x, y); hit >= 0 && e.button == .Left {
		if tab_menu_enabled(w, hit) {
			ui.menu_select(&w.tab_menu.menu, hit)
			tab_menu_choose(app, w)
		}
	} else {overlay_close(app, w)}
}
