package main

import "aio:commands"
import "aio:font"
import "aio:layout"
import "aio:settings"
import "aio:ui"

// A tab's second identity: the focused pane's terminal title, which can differ from a user name.
@(require_results)
palette_tab_detail :: proc(app: ^App, tab: ^Tab) -> string {
	if tab == nil || tab.tree.root == layout.INVALID_NODE {return ""}
	content, is_pane := layout.focused_content(&tab.tree)
	if !is_pane {return ""}
	if entry := workspace_session_for_content(app, content); entry != nil {
		return pane_header_title(&entry.header)
	}
	return content_title(app, content)
}

@(private)
palette_tab_key :: proc(workspace: ^Workspace, tab: ^Tab) -> u64 {
	return u64(workspace.id) << 32 | u64(tab.id)
}

@(private)
palette_tab_count :: proc(user: rawptr) -> int {
	app := cast(^App)user
	count := 0
	for workspace in app.workspaces {
		if workspace.provisional {continue}
		count += len(workspace.tabs)
	}
	return count
}

@(private)
palette_tab_at :: proc(user: rawptr, index: int) -> ui.Palette_Item {
	app := cast(^App)user
	remaining := index
	for workspace in app.workspaces {
		if workspace.provisional {continue}
		if remaining < len(workspace.tabs) {
			tab := workspace.tabs[remaining]
			return {
				label  = tab.title,
				detail = palette_tab_detail(app, tab),
				owner  = workspace.name,
				id     = palette_tab_key(workspace, tab),
			}
		}
		remaining -= len(workspace.tabs)
	}
	return {}
}

@(private)
palette_workspace_count :: proc(user: rawptr) -> int {
	app := cast(^App)user
	count := 0
	for workspace in app.workspaces {
		if !workspace.provisional {count += 1}
	}
	return count
}

@(private)
palette_workspace_at :: proc(user: rawptr, index: int) -> ui.Palette_Item {
	app := cast(^App)user
	remaining := index
	for workspace in app.workspaces {
		if workspace.provisional {continue}
		if remaining == 0 {
			detail := ""
			if tab := selected_tab(workspace); tab != nil {
				detail = palette_tab_detail(app, tab)
			}
			return {label = workspace.name, detail = detail, id = u64(workspace.id)}
		}
		remaining -= 1
	}
	return {}
}

// The palette resolves display labels from the same static or live choices its control offers.
@(private)
palette_setting_value :: proc(user: rawptr, key: string) -> (value, label: string) {
	app := cast(^App)user
	entry := settings.schema_find(key)
	if entry == nil {return}
	value = settings.value_text(&app.settings, entry^)
	choices, labels := entry.names, entry.labels
	// Font choices carry no labels, so a value's label never needs the installed families.
	if entry.live_choices != .None {
		choices, labels, _ = setting_live_choices(&app.settings, nil, entry.live_choices)
	}
	for name, i in labels {
		if i < len(choices) && choices[i] == value {label = name; break}
	}
	return
}

@(private)
palette_setting_choices :: proc(user: rawptr, key: string) -> (choices, labels: []string) {
	app := cast(^App)user
	entry := settings.schema_find(key)
	if entry == nil {return}
	if entry.live_choices == .None {return entry.names, entry.labels}
	fonts: []font.Family_Info
	if entry.live_choices == .Shell_Fonts || entry.live_choices == .Interface_Fonts {
		fonts, _ = font.installed_families(app.fonts)
	}
	choices, labels, _ = setting_live_choices(&app.settings, fonts, entry.live_choices)
	return
}

// The palette asks for the window that opened it, so it lists what that window can run now.
@(private)
palette_command_available :: proc(user: rawptr, id: commands.Command_Id) -> bool {
	app := cast(^App)user
	w := palette_owner_window(app)
	return w == nil || action_available(app, w, Action(id))
}

palette_set_sources :: proc(app: ^App) {
	ui.palette_set_sources(
		&app.palette,
		{user = app, count = palette_tab_count, item = palette_tab_at},
		{user = app, count = palette_workspace_count, item = palette_workspace_at},
	)
	ui.palette_set_values(
		&app.palette,
		{user = app, value = palette_setting_value, choices = palette_setting_choices},
	)
	ui.palette_set_availability(&app.palette, {user = app, available = palette_command_available})
}

// Selecting a tab follows its workspace's exclusive window ownership (D-051): an owned workspace
// reuses and focuses its window, an unowned one is adopted by the requesting window first.
palette_activate_tab :: proc(app: ^App, w: ^Window, key: u64) -> bool {
	workspace := workspace_find(app, u32(key >> 32))
	if workspace == nil {return false}
	tab_index := tab_index_by_id(workspace, u32(key))
	if tab_index < 0 {return false}
	owner := window_for_workspace(app, workspace)
	if owner == nil {
		if !workspace_select(app, w, workspace) {return false}
		owner = window_for_workspace(app, workspace)
	}
	if owner == nil {return false}
	tab_select(app, owner, tab_index)
	if owner != w {return window_activate(app, owner)}
	return true
}

palette_activate_workspace :: proc(app: ^App, w: ^Window, id: u32) -> bool {
	workspace := workspace_find(app, id)
	if workspace == nil {return false}
	return workspace_select(app, w, workspace)
}
