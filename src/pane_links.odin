package main

import "aio:glyphs"
import "aio:layout"
import "aio:platform"
import "aio:ui"
import "core:log"

// A linked window shows one pane of a tab on its own, so panes that belong together can span monitors and
// still switch with their tab (D-077). The pane stays in its tab's tree, marked linked, which keeps every
// walk, close, move and saved layout correct without knowing about windows. The window displays a private
// one-pane workspace that no list reaches, and pane_links_sync shows it only while its tab is on screen.

// Where a linked pane lives.
Pane_Link_Home :: struct {
	workspace: ^Workspace,
	tab:       ^Tab,
	node:      layout.Node_Id,
}

// What a command does when a linked window runs it.
Pane_Link_Route :: enum u8 {
	// Acts on the window's own pane, or on no pane at all.
	Local,
	// Tabs, workspaces and overlays belong to the window showing the tab.
	Host,
	// Would change the pane's place in a tree this window does not own.
	Refuse,
}

@(private)
pane_link_route :: proc(action: Action) -> Pane_Link_Route {
	#partial switch action {
	case .Show_Build_Info,
	     .Command_Palette,
	     .Palette_Tabs,
	     .Palette_Workspaces,
	     .Palette_Settings,
	     .Palette_Commands,
	     .Copy,
	     .Paste,
	     .Select_All,
	     .Find,
	     .Clear_Scrollback,
	     .Scroll_Page_Up,
	     .Scroll_Page_Down,
	     .Scroll_Partial_Up,
	     .Scroll_Partial_Down,
	     .Font_Size_Increase,
	     .Font_Size_Decrease,
	     .Font_Size_Reset,
	     .Open_Settings,
	     .Reload_Settings,
	     .Rename_Pane,
	     .Restart_Shell,
	     .Quit,
	     .Close_Pane,
	     .Keep_Pane_Open,
	     .Zoom_Pane,
	     .Fill_Window_Pane,
	     .Fullscreen_Pane,
	     .Linked_Window,
	     .Focus_Left,
	     .Focus_Right,
	     .Focus_Up,
	     .Focus_Down,
	     .Focus_Previous,
	     .Focus_Next,
	     .Resize_Left,
	     .Resize_Right,
	     .Resize_Up,
	     .Resize_Down,
	     .Resize_Left_Large,
	     .Resize_Right_Large,
	     .Resize_Up_Large,
	     .Resize_Down_Large,
	     .Balance_Panes,
	     .Swap_Left,
	     .Swap_Right,
	     .Swap_Up,
	     .Swap_Down,
	     .Swap_Previous,
	     .Swap_Next:
		return .Local
	case .Split,
	     .Split_Left,
	     .Split_Right,
	     .Split_Up,
	     .Split_Down,
	     .Change_Pane_Shell,
	     .Move_Pane_Workspace,
	     .Move_Pane_New_Workspace:
		return .Refuse
	}
	return .Host
}

@(private)
pane_link_content :: proc(w: ^Window) -> layout.Content {
	pane, _ := w.tree.nodes[w.tree.root].(layout.Pane)
	return pane.content
}

// Finds a linked pane by what it shows, which stays true as its tab moves between workspaces.
@(require_results)
pane_link_home :: proc(app: ^App, content: layout.Content) -> (Pane_Link_Home, bool) {
	for workspace in app.workspaces {
		for tab in workspace.tabs {
			for node, i in tab.tree.nodes {
				pane := node.(layout.Pane) or_continue
				if pane.linked && pane.content == content {
					return {workspace, tab, layout.Node_Id(i)}, true
				}
			}
		}
	}
	return {}, false
}

pane_link_window_of :: proc(app: ^App, content: layout.Content) -> ^Window {
	for w in app.windows {
		if w.linked && pane_link_content(w) == content {return w}
	}
	return nil
}

// The first window that shows a workspace of its own, which is what callers mean by the app's window.
window_primary :: proc(app: ^App) -> ^Window {
	for w in app.windows {
		if !w.linked {return w}
	}
	return nil
}

// The window showing the pane's tab, or the app's window when nothing shows it.
@(private)
pane_link_host :: proc(app: ^App, w: ^Window) -> ^Window {
	if workspace := workspace_find(app, w.link_workspace); workspace != nil {
		if host := window_for_workspace(app, workspace); host != nil {return host}
	}
	return window_primary(app)
}

// The window a tab, workspace or settings choice made here should act in, brought forward.
pane_link_acting_window :: proc(app: ^App, w: ^Window) -> ^Window {
	if !w.linked {return w}
	host := pane_link_host(app, w)
	if host == nil {return w}
	_ = window_activate(app, host)
	return host
}

@(private, require_results)
pane_link_window_create :: proc(app: ^App, content: layout.Content, workspace: ^Workspace) -> ^Window {
	view, allocation_error := new(Workspace)
	if allocation_error != nil {return nil}
	tab, record_error := tab_record_reserve(view)
	if record_error != .None {workspace_destroy(view); return nil}
	if layout.init(&tab.tree, content) != nil {
		tab_record_free(tab)
		workspace_destroy(view)
		return nil
	}
	tab_record_commit(app, view, tab)
	w := window_prepare(app, view)
	if w == nil {workspace_destroy(view); return nil}
	w.preparing, w.linked = false, true
	w.link_workspace = workspace.id
	window_apply_settings(app, w)
	window_update_title(app, w)
	return w
}

pane_link_toggle :: proc(app: ^App, w: ^Window) {
	if w.linked {pane_link_return(app, w); return}
	tab := selected_tab(w.workspace)
	if tab == nil {return}
	node := w.tree.focus
	pane, is_pane := tab.tree.nodes[node].(layout.Pane)
	if !is_pane {return}
	if pane.content.kind != .Terminal {
		notify(app, .Info, "Only a terminal pane can have a linked window.")
		return
	}
	focus_leave(app, w)
	defer focus_enter(app, w)
	if !layout.set_linked(w.tree, node, true) {
		notify(app, .Info, "A tab must keep one pane in this window.")
		return
	}
	linked := pane_link_window_create(app, pane.content, w.workspace)
	if linked == nil {
		if !layout.set_linked(w.tree, node, false) {log.error("returning the unlinked pane failed")}
		notify(app, .Error, "Could not open a linked window. The pane was preserved.")
		return
	}
	window_relayout(app, w)
	linked.link_activate = true
	layout_state_touch(app)
}

// Closing a linked window keeps the pane: it goes back to its slot in the tab.
pane_link_return :: proc(app: ^App, w: ^Window) {
	home, found := pane_link_home(app, pane_link_content(w))
	if !found {pane_link_end(app, w); return}
	focused := w.focused
	host := window_for_workspace(app, home.workspace)
	if !layout.set_linked(&home.tab.tree, home.node, false) {return}
	window_close(app, w)
	layout_state_touch(app)
	if host == nil || selected_tab(home.workspace) != home.tab {return}
	window_relayout(app, host)
	if focused {
		pane_focus(app, host, home.node)
		_ = window_activate(app, host)
	}
}

// The pane is gone. Focus moves first, so Windows does not hand it to another application.
@(private)
pane_link_end :: proc(app: ^App, w: ^Window) {
	if w.focused {
		if host := pane_link_host(app, w); host != nil {_ = window_activate(app, host)}
	}
	window_close(app, w)
}

@(private)
pane_link_show :: proc(app: ^App, w: ^Window, host: ^Window) {
	if platform.window_show_raised(&app.platform, w.id) != .None {
		log.error("showing a linked window failed")
		return
	}
	w.link_shown, w.dirty = true, true
	if w.link_maximize && !app.options.inactive {
		platform.window_maximize(&app.platform, w.id)
		if !w.link_activate && host != nil {_ = window_activate(app, host)}
	}
	w.link_maximize = false
}

@(private)
pane_link_hide :: proc(app: ^App, w: ^Window, host: ^Window) {
	// Activating restores a minimized window, which would undo the minimize that caused this hide.
	if w.focused && host != nil && host.width > 0 {_ = window_activate(app, host)}
	window_overlays_cancel(app, w)
	tooltip_cancel(w)
	if platform.window_hide(&app.platform, w.id) != .None {
		log.error("hiding a linked window failed")
		return
	}
	w.link_shown = false
	// A hidden window draws no frames, so nothing would ever stop these from waking the loop.
	w.blinking, w.status_spinning = false, false
}

// Once per tick, after every event, so any path that changes what is on screen is covered: a linked window
// is shown exactly while its tab is selected in a workspace a window displays and has room to show.
pane_links_sync :: proc(app: ^App) {
	for i := len(app.windows) - 1; i >= 0; i -= 1 {
		if i >= len(app.windows) {continue}
		w := app.windows[i]
		if !w.linked {continue}
		home, found := pane_link_home(app, pane_link_content(w))
		if !found {pane_link_end(app, w); continue}
		w.link_workspace = home.workspace.id
		host := window_for_workspace(app, home.workspace)
		shown :=
			host != nil &&
			!host.preparing &&
			host.width > 0 &&
			host.height > 0 &&
			selected_tab(home.workspace) == home.tab
		if shown && !w.link_shown {
			pane_link_show(app, w, host)
		} else if !shown && w.link_shown {
			pane_link_hide(app, w, pane_link_host(app, w))
		}
		if w.link_activate && w.link_shown {_ = window_activate(app, w)}
		w.link_activate = false
	}
}

pane_link_title_draw :: proc(app: ^App, w: ^Window) -> glyphs.Result {
	tab := selected_tab(w.workspace)
	if tab == nil {return .Ok}
	inset := ui.SPACE_3 * w.scale
	bar := ui.TITLE_BAR_HEIGHT * w.scale
	return ui.draw_text(
		&w.ui_text,
		&w.list,
		tab.title,
		inset,
		(bar - w.ui_text.line_height) / 2 + w.ui_text.ascent,
		app.theme.text,
		max(1, f32(w.width) - ui.CAPTION_WIDTH * w.scale - 2 * inset),
	)
}

// Brings back a linked pane from saved layout, hidden until pane_links_sync decides otherwise. A window
// that cannot open leaves the pane in its tab, which loses nothing.
pane_link_restore :: proc(
	app: ^App,
	workspace: ^Workspace,
	tab: ^Tab,
	node: layout.Node_Id,
	saved_window: []platform.Window_Placement,
) {
	pane := tab.tree.nodes[node].(layout.Pane)
	w := pane_link_window_create(app, pane.content, workspace)
	if w == nil {
		if !layout.set_linked(&tab.tree, node, false) {log.error("returning a saved linked pane failed")}
		return
	}
	if len(saved_window) == 0 {return}
	placement := saved_window[0]
	if placement.right <= placement.left || placement.bottom <= placement.top {return}
	if platform.window_set_placement(&app.platform, w.id, placement) != .None {
		log.error("restoring a linked window's placement failed")
		return
	}
	w.link_maximize = placement.maximized
	if dpi := platform.window_dpi(&app.platform, w.id); dpi != 0 && f32(dpi) / 96 != w.scale {
		window_set_dpi(app, w, dpi)
	}
	width, height, size_error := platform.window_client_size(&app.platform, w.id)
	if size_error == .None && (width != w.width || height != w.height) {window_resize(app, w, width, height)}
}
