package main

import "core:log"
import "core:math"
import "core:strings"
import "aio:layout"
import "aio:platform"
import "aio:render"
import "aio:ui"

pane_source_workspace :: proc(app: ^App, source: ^Tab) -> ^Workspace {
	for workspace in app.workspaces {
		for tab in workspace.tabs { if tab == source { return workspace } }
	}
	return nil
}

@(private)
pane_window_source_allows :: proc(workspace: ^Workspace) -> bool {
	if workspace == nil { return false }
	count := 0
	for tab in workspace.tabs {
		for node in tab.tree.nodes {
			if _, pane := node.(layout.Pane); !pane { continue }
			count += 1
			if count > 1 { return true }
		}
	}
	return false
}

// Preview tabs borrow their source runtime; discarding one must never close its session.
@(private)
pane_preview_workspace_discard :: proc(app: ^App, workspace: ^Workspace) {
	for tab in workspace.tabs {
		layout.destroy(&tab.tree)
		delete(tab.title)
		delete(tab.name)
		free(tab)
	}
	clear(&workspace.tabs)
	if !workspace_discard_empty(app, workspace) { log.error("discarding the pane preview workspace failed") }
}

pane_window_preview_discard :: proc(app: ^App, id: platform.Window_Id) {
	preview := window_find(app, id)
	if preview == nil || !preview.preparing { return }
	workspace_id := preview.workspace.id
	window_close(app, preview)
	if workspace := workspace_find(app, workspace_id); workspace != nil && workspace.provisional {
		pane_preview_workspace_discard(app, workspace)
	}
}

@(require_results)
pane_window_preview_hide :: proc(app: ^App, id: platform.Window_Id) -> bool {
	w := window_find(app, id)
	if w == nil || !w.preparing { return false }
	if !w.preview_visible { return true }
	if platform.window_hide(&app.platform, id) != .None { return false }
	w.preview_visible, w.dirty = false, false
	return true
}

@(require_results)
pane_window_preview_position :: proc(app: ^App, w: ^Window, x, y: i32) -> bool {
	offset := i32(math.round(16*w.scale))
	if platform.window_set_position(&app.platform, w.id, x+offset, y+offset) != .None { return false }
	dpi := platform.window_dpi(&app.platform, w.id)
	if dpi != 0 && f32(dpi)/96 != w.scale { window_set_dpi(app, w, dpi) }
	width, height, err := platform.window_client_size(&app.platform, w.id)
	if err != .None { return false }
	if width != w.width || height != w.height { window_resize(app, w, width, height) }
	return true
}

@(require_results)
pane_window_preview_create :: proc(app: ^App, source: ^Tab, node: layout.Node_Id, x, y: i32) -> ^Window {
	if !pane_window_source_allows(pane_source_workspace(app, source)) { return nil }
	if int(node) >= len(source.tree.nodes) { return nil }
	pane, ok := source.tree.nodes[node].(layout.Pane)
	if !ok || pane.content.kind != .Terminal { return nil }
	workspace := workspace_create_empty(app, true)
	if workspace == nil { return nil }
	success := false
	defer if !success { pane_preview_workspace_discard(app, workspace) }
	tab, err := new(Tab)
	if err != nil { return nil }
	if reserve(&workspace.tabs, 1) != nil { free(tab); return nil }
	if layout.init(&tab.tree, pane.content) != nil { layout.destroy(&tab.tree); free(tab); return nil }
	workspace.next_tab_id += 1
	tab.id = workspace.next_tab_id
	append(&workspace.tabs, tab)
	if node == source.tree.root && source.name != "" {
		name, name_error := strings.clone(source.name)
		if name_error != nil { return nil }
		tab.name = name
	}
	tab_update_title(app, tab)
	preview := window_prepare(app, workspace)
	if preview == nil { return nil }
	defer if !success { window_close(app, preview) }
	if !pane_window_preview_position(app, preview, x, y) { return nil }
	area := window_content_area(app, preview)
	panes := [?]layout.Pane_Rect{{content = pane.content, rect = area}}
	if !pane_minimum_allows(app, preview, panes[:], nil, false) { return nil }
	if !window_show_prepared(app, preview) { return nil }
	workspace_pickers_refresh(app)
	success = true
	return preview
}

@(require_results)
pane_to_window :: proc(app: ^App, source_window: ^Window, source: ^Tab,
	node: layout.Node_Id, preview_id: platform.Window_Id) -> bool {
	preview := window_find(app, preview_id)
	workspace := pane_source_workspace(app, source)
	if preview == nil || !preview.preparing || !pane_window_source_allows(workspace) ||
	   int(node) >= len(source.tree.nodes) {
		return false
	}
	pane, valid := source.tree.nodes[node].(layout.Pane)
	destination := selected_tab(preview.workspace)
	if !valid || destination == nil ||
	   destination.tree.nodes[destination.tree.root].(layout.Pane).content != pane.content { return false }
	area := window_content_area(app, preview)
	panes := [?]layout.Pane_Rect{{content = pane.content, rect = area}}
	if !pane_minimum_allows(app, preview, panes[:], nil, true) { return false }
	name, number := workspace_default_name(app)
	if number == 0 { return false }
	focus_leave(app, source_window)
	if !layout.remove(&source.tree, node) {
		delete(name)
		focus_enter(app, source_window)
		return false
	}
	destination.tree.nodes[destination.tree.root] = pane
	destination.tree.next_pane_order = pane.order
	preview.preparing = false
	preview.workspace.provisional = false
	preview.workspace.name = name
	app.next_workspace_number = number
	workspace_pickers_refresh(app)
	window_relayout(app, preview)
	focus_enter(app, preview)
	if source.tree.root == layout.INVALID_NODE {
		for tab, index in workspace.tabs {
			if tab == source { workspace_close_tab(app, workspace, index); break }
		}
	} else {
		tab_update_title(app, source)
		window_relayout(app, source_window)
		focus_enter(app, source_window)
	}
	_ = window_activate(app, preview)
	return true
}

pane_window_preview_render :: proc(app: ^App, w: ^Window) {
	if err := render.frame_wait(w.surface, FRAME_WAIT_MS); err == .Wait_Failed {
		log.error("waiting for the pane preview failed")
	}
	render.draw_list_reset(&w.list)
	width, height := f32(w.width), f32(w.height)
	if render.push_layer(&w.list, {0, 0, width, height}) != .None { return }
	if render.push_rect(&w.list, {rect = {0, 0, width, height}, color = app.theme.window}) != .None { return }
	area := window_content_area(app, w)
	if render.push_rect(&w.list, {rect = {area.x, area.y, area.width, area.height},
		color = app.theme.pane, radius = f32(app.settings.pane.corner_radius)*w.scale,
		stroke = 2*w.scale}) != .None { return }
	strong := ui.text_styled(&w.ui_text, .Strong)
	label := "+ New window"
	_ = ui.draw_text(&strong, &w.list, label, 24*w.scale,
		40*w.scale+strong.ascent, app.theme.accent, max(1, width-48*w.scale))
	_ = ui.draw_text(&w.ui_text, &w.list, "Release to move this running pane. Esc cancels.",
		24*w.scale, 76*w.scale+w.ui_text.ascent, app.theme.text, max(1, width-48*w.scale))
	if tab := selected_tab(w.workspace); tab != nil {
		_ = ui.draw_text(&w.ui_text, &w.list, tab.title, 24*w.scale,
			108*w.scale+w.ui_text.ascent, app.theme.muted, max(1, width-48*w.scale))
	}
	if err := render.frame_render(app.device, w.surface, &w.list, app.theme.window); err != .None {
		if err == .Device_Lost { recover_device(app) } else { log.errorf("drawing the pane preview failed: %v", err) }
	}
	w.dirty = false
}
