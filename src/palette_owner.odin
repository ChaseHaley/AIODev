package main

import "aio:commands"
import "aio:font"
import "aio:layout"
import "aio:settings"
import "aio:platform"
import "aio:ui"

// Presence owns the palette's Open/Closing phase; the app owns only its window. This view is the one
// mapping between them, so keeping a window through a closing fade needs no second hand-synced phase.
Palette_Owner_State :: union {
	Palette_Open,
	Palette_Closing,
}

Palette_Open :: struct {window: platform.Window_Id}
Palette_Closing :: struct {window: platform.Window_Id}

palette_owner_state :: proc(app: ^App) -> Palette_Owner_State {
	owner, owned := app.palette_owner.?
	if !owned {return nil}
	if ui.presence_is_open(app.palette.presence) {return Palette_Open{owner}}
	return Palette_Closing{owner}
}

// Zero means unowned at the external window-id boundary, not in the stored owner.
palette_owner_id :: proc(app: ^App) -> platform.Window_Id {
	switch state in palette_owner_state(app) {
	case nil: return 0
	case Palette_Open: return state.window
	case Palette_Closing: return state.window
	}
	return 0
}

@(private = "file")
palette_owned_by :: proc(app: ^App, w: ^Window) -> bool {
	return w != nil && w.id != 0 && palette_owner_id(app) == w.id
}

palette_owner_window :: proc(app: ^App) -> ^Window {
	return window_find(app, palette_owner_id(app))
}

palette_active :: proc(app: ^App, w: ^Window) -> bool {
	state, open := palette_owner_state(app).(Palette_Open)
	return open && w != nil && state.window == w.id
}

// Open or Closing in w: the palette draws in w.
palette_visible :: proc(app: ^App, w: ^Window) -> bool {
	return palette_owned_by(app, w) && ui.presence_visible(app.palette.presence)
}

// Open to Closing: the palette fades out in w, which keeps it until the fade settles.
palette_close :: proc(app: ^App, w: ^Window) {
	if !palette_owned_by(app, w) {return}
	ui.palette_close(&app.palette)
	w.dirty = true
}

// Unowned at once, without a fade.
palette_release :: proc(app: ^App, w: ^Window) {
	if !palette_owned_by(app, w) {return}
	palette_close(app, w)
	ui.presence_reset(&app.palette.presence)
	app.palette_owner = nil
}

palette_open :: proc(app: ^App, w: ^Window) {
	palette_open_mode(app, w, .All)
}

// Opens the palette in w, taking it from any other window. Cancelling w's gesture can remove w, so the
// palette leaves its previous window only once w is known to remain.
palette_open_mode :: proc(app: ^App, w: ^Window, mode: ui.Palette_Mode) {
	if w == nil || w.id == 0 {return}
	if !gesture_cancel(app, w) {return}
	if previous := palette_owner_window(app); previous != nil && previous != w {
		palette_release(app, previous)
	}
	window_overlays_cancel(app, w)
	app.palette.unavailable = nil
	if !copy_selection_available(app, w) {app.palette.unavailable = commands.Command_Id(Action.Copy)}
	app.palette_owner = w.id
	app.palette.leader = app.leader
	ui.palette_open_mode(&app.palette, &app.registry, mode)
	ui.palette_layout(&app.palette, f32(w.width), f32(w.height), w.scale)
	w.dirty = true
}

// A tab's second identity: the focused pane's terminal title, which can differ from a user name.
@(require_results)
palette_tab_detail :: proc(app: ^App, tab: ^Tab) -> string {
	if tab == nil || tab.tree.root == layout.INVALID_NODE || tab.tree.focus == layout.INVALID_NODE {
		return ""
	}
	pane, is_pane := tab.tree.nodes[tab.tree.focus].(layout.Pane)
	if !is_pane {return ""}
	if entry := workspace_session_for_content(app, pane.content); entry != nil {
		return pane_header_title(&entry.header)
	}
	return content_title(app, pane.content)
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

palette_set_sources :: proc(app: ^App) {
	ui.palette_set_sources(
		&app.palette,
		{user = app, count = palette_tab_count, item = palette_tab_at},
		{user = app, count = palette_workspace_count, item = palette_workspace_at},
	)
}

// Selecting a tab follows its workspace's exclusive window ownership (D-051): an owned workspace
// reuses and focuses its window, an unowned one is adopted by the requesting window first.
palette_activate_tab :: proc(app: ^App, w: ^Window, key: u64) -> bool {
	workspace := workspace_find(app, u32(key >> 32))
	if workspace == nil {return false}
	tab_id := u32(key)
	tab_index := -1
	for tab, index in workspace.tabs {
		if tab.id == tab_id {
			tab_index = index
			break
		}
	}
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


@(private)
palette_setting_value :: proc(user: rawptr, key: string) -> (value, label: string) {
	app := cast(^App)user
	entry := settings.schema_find(key)
	if entry == nil {return}
	value = settings.value_text(&app.settings, entry^)
	if key == "theme.name" {label = settings.theme_display_name(&app.settings, value)}
	return
}

@(private)
palette_setting_choices :: proc(user: rawptr, key: string) -> (choices, labels: []string) {
	app := cast(^App)user
	fonts, _ := font.installed_families(app.fonts)
	choices, labels, _ = setting_live_choices(&app.settings, fonts, key)
	return
}
