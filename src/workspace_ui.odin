package main

import "core:fmt"
import "core:strings"
import "aio:glyphs"
import "aio:layout"
import "aio:platform"
import "aio:render"
import "aio:settings"
import "aio:term"
import "aio:ui"

Workspace_Row :: struct {
	id: u32,
	status: string,
}

Workspace_Picker :: struct {
	open: bool,
	query: ui.Text_Field,
	rows: [dynamic]Workspace_Row,
	selected, scroll: int,
}

@(require_results)
workspace_create_empty :: proc(app: ^App) -> ^Workspace {
	if app.next_workspace_id == max(u32) { return nil }
	workspace, err := new(Workspace)
	if err != nil { return nil }
	name, name_error := strings.clone(fmt.tprintf("Workspace %d", app.next_workspace_id+1))
	if name_error != nil { free(workspace); return nil }
	workspace.name, workspace.id = name, app.next_workspace_id+1
	if _, append_error := append(&app.workspaces, workspace); append_error != nil {
		workspace_destroy(workspace)
		return nil
	}
	app.next_workspace_id = workspace.id
	workspace_pickers_refresh(app)
	return workspace
}

@(require_results)
workspace_discard_empty :: proc(app: ^App, workspace: ^Workspace) -> bool {
	if workspace == nil || len(workspace.tabs) != 0 || window_for_workspace(app, workspace) != nil {
		return false
	}
	for current, i in app.workspaces {
		if current != workspace { continue }
		ordered_remove(&app.workspaces, i)
		workspace_destroy(workspace)
		workspace_pickers_refresh(app)
		return true
	}
	return false
}

workspace_find :: proc(app: ^App, id: u32) -> ^Workspace {
	for workspace in app.workspaces { if workspace.id == id { return workspace } }
	return nil
}

@(require_results)
workspace_rename :: proc(app: ^App, workspace: ^Workspace, value: string) -> bool {
	if workspace == nil || workspace_find(app, workspace.id) != workspace { return false }
	clean := settings.display_title(strings.trim_space(value), context.temp_allocator)
	if clean == "" { return false }
	name, err := strings.clone(clean)
	if err != nil { return false }
	delete(workspace.name)
	workspace.name = name
	for w in app.windows { window_relayout(app, w) }
	workspace_pickers_refresh(app)
	return true
}

@(require_results)
workspace_select :: proc(app: ^App, w: ^Window, workspace: ^Workspace) -> bool {
	if workspace == nil || workspace_find(app, workspace.id) != workspace { return false }
	if owner := window_for_workspace(app, workspace); owner != nil {
		if owner == w { return true }
		return window_activate(app, owner)
	}
	if len(workspace.tabs) == 0 && !tab_create(app, workspace) { return false }
	// Load before changing ownership so an unreadable settings file leaves the old view intact.
	prepared: Window
	if settings_tab_index(workspace) >= 0 && !settings_load(app, &prepared) { return false }
	arrange_cancel(app, w)
	focus_leave(app, w)
	tab_close_restore(w)
	w.tab_menu.open, w.rename_open, w.workspace_picker.open = false, false, false
	w.close_confirm = {}
	clear(&w.close_restore)
	ui.editor_destroy(&w.editor)
	w.editor = prepared.editor
	w.workspace = workspace
	w.tree = &selected_tab(workspace).tree
	if workspace.selection_anchor == 0 { tab_select_one(workspace, workspace.selected) }
	clear(&w.tab_positions)
	clear(&w.tab_controls)
	w.tab_underline = {value = f32(workspace.selected), target = f32(workspace.selected)}
	w.tab_hover, w.tab_close_pressed = -1, -1
	w.tab_pressed = false
	window_relayout(app, w)
	focus_enter(app, w)
	return true
}

workspace_new :: proc(app: ^App, w: ^Window, new_window: bool) {
	workspace := workspace_create_empty(app)
	if workspace == nil { notify(app, .Error, "Could not create a workspace."); return }
	if !tab_create(app, workspace) {
		_ = workspace_discard_empty(app, workspace)
		notify(app, .Error, "Could not create the workspace shell.")
		return
	}
	opened := new_window ? window_open(app, workspace) : workspace_select(app, w, workspace)
	if !opened {
		workspace_close_tab(app, workspace, 0)
		_ = workspace_discard_empty(app, workspace)
		notify(app, .Error, "Could not open the new workspace.")
	}
	mark_all_dirty(app)
}

workspace_rename_open :: proc(app: ^App, w: ^Window) {
	arrange_cancel(app, w)
	leader_cancel(w)
	ui.palette_close(&app.palette)
	w.workspace_picker.open, w.tab_menu.open = false, false
	ui.field_set(&w.rename, w.workspace.name)
	ui.field_select_all(&w.rename)
	w.rename_open, w.rename_workspace, w.rename_id, w.dirty = true, true, w.workspace.id, true
}

workspace_button_width :: proc(w: ^Window) -> f32 {
	return min(184*w.scale, max(0, (f32(w.width)-218*w.scale)*0.35))
}

workspace_button_draw :: proc(app: ^App, w: ^Window) -> glyphs.Result {
	width := workspace_button_width(w)
	if width <= 12*w.scale { return .Ok }
	r := render.Rect{5*w.scale, 6*w.scale, max(0, width-10*w.scale), 28*w.scale}
	if render.push_layer(&w.list, {0, 0, width, ui.TAB_HEIGHT*w.scale}) != .None { return .Ok }
	fill := w.workspace_picker.open ? app.theme.selection : app.theme.pane
	if render.push_rect(&w.list, {rect = r, color = fill, radius = 6*w.scale}) != .None { return .Ok }
	if result := ui.draw_fading_text(&w.ui_text, &w.list, w.workspace.name, 12*w.scale,
		(ui.TAB_HEIGHT*w.scale-w.ui_text.line_height)/2+w.ui_text.ascent,
		app.theme.text, max(0, width-36*w.scale)); result != .Ok { return result }
	return ui.draw_text(&w.ui_text, &w.list, "⌄", width-23*w.scale,
		(ui.TAB_HEIGHT*w.scale-w.ui_text.line_height)/2+w.ui_text.ascent, app.theme.muted, 16*w.scale)
}

@(private)
workspace_status :: proc(app: ^App, workspace: ^Workspace) -> string {
	done, blocked := false, false
	for tab in workspace.tabs {
		for node in tab.tree.nodes {
			pane, ok := node.(layout.Pane)
			if !ok || pane.content.kind != .Terminal { continue }
			entry := session_find(app, pane.content.id)
			if entry == nil { continue }
			done ||= entry.status == .Exited
			blocked ||= entry.status == .Failed
			statuses, err := term.program_status(entry.session, context.temp_allocator)
			if err != nil { continue }
			for status in statuses {
				done ||= status.state == .Done
				blocked ||= status.state == .Blocked || status.state == .Error
			}
			term.destroy_program_status(statuses, context.temp_allocator)
		}
	}
	return blocked ? "Blocked" : done ? "Finished" : ""
}

workspace_picker_filter :: proc(app: ^App, w: ^Window) {
	p := &w.workspace_picker
	clear(&p.rows)
	query := strings.to_lower(strings.trim_space(ui.field_string(&p.query)), context.temp_allocator)
	for workspace in app.workspaces {
		name := strings.to_lower(workspace.name, context.temp_allocator)
		if query != "" && !strings.contains(name, query) { continue }
		if _, err := append(&p.rows, Workspace_Row{workspace.id, workspace_status(app, workspace)}); err != nil {
			notify(app, .Error, "Could not list all workspaces.")
			break
		}
	}
	p.selected, p.scroll, w.dirty = 0, 0, true
}

@(private)
workspace_pickers_refresh :: proc(app: ^App) {
	for w in app.windows {
		p := &w.workspace_picker
		if !p.open { continue }
		id := p.selected >= 0 && p.selected < len(p.rows) ? p.rows[p.selected].id : 0
		action := p.selected-len(p.rows)
		workspace_picker_filter(app, w)
		if id != 0 {
			for row, i in p.rows { if row.id == id { p.selected = i; break } }
		} else { p.selected = len(p.rows)+clamp(action, 0, 2) }
	}
}

workspace_picker_status_changed :: proc(app: ^App) {
	for w in app.windows {
		if !w.workspace_picker.open { continue }
		for &row in w.workspace_picker.rows {
			if workspace := workspace_find(app, row.id); workspace != nil {
				row.status = workspace_status(app, workspace)
			}
		}
		w.dirty = true
	}
}

workspace_picker_open :: proc(app: ^App, w: ^Window) {
	arrange_cancel(app, w)
	leader_cancel(w)
	pane_header_cancel(w)
	ui.palette_close(&app.palette)
	w.tab_menu.open, w.rename_open = false, false
	w.close_confirm = {}
	tab_close_restore(w)
	w.selecting, w.autoscrolling = false, false
	ui.field_set(&w.workspace_picker.query, "")
	w.workspace_picker.open = true
	workspace_picker_filter(app, w)
	for row, i in w.workspace_picker.rows { if row.id == w.workspace.id { w.workspace_picker.selected = i } }
}

workspace_picker_choose :: proc(app: ^App, w: ^Window) {
	p := &w.workspace_picker
	index, count := p.selected, len(p.rows)
	p.open, w.dirty = false, true
	if index < count {
		if index >= 0 && !workspace_select(app, w, workspace_find(app, p.rows[index].id)) {
			notify(app, .Error, "Could not select the workspace.")
		}
		return
	}
	switch index-count {
	case 0: workspace_new(app, w, false)
	case 1: workspace_rename_open(app, w)
	case 2: workspace_new(app, w, true)
	}
}

workspace_picker_text :: proc(app: ^App, w: ^Window, value: string) {
	ui.field_text(&w.workspace_picker.query, value)
	workspace_picker_filter(app, w)
}

workspace_picker_key :: proc(app: ^App, w: ^Window, e: platform.Key_Event) {
	if !e.pressed { return }
	p := &w.workspace_picker
	count := len(p.rows)+3
	#partial switch e.key {
	case .Escape: p.open = false
	case .Arrow_Up: p.selected = (p.selected+count-1)%count
	case .Arrow_Down, .Tab: p.selected = (p.selected+1)%count
	case .Enter, .Numpad_Enter: workspace_picker_choose(app, w)
	case:
		switch clipboard_chord(e) {
		case .Copy: clipboard_copy(app, ui.field_selected_text(&p.query))
		case .Cut:
			if clipboard_copy(app, ui.field_selected_text(&p.query)) { workspace_picker_text(app, w, "") }
		case .Paste:
			if text, ok := platform.clipboard_get_text(&app.platform, context.temp_allocator); ok {
				workspace_picker_text(app, w, text)
			}
		case .None:
			if ui.field_key(&p.query, e) == .Edited { workspace_picker_filter(app, w) }
		}
	}
	w.dirty = true
}

workspace_picker_rect :: proc(w: ^Window) -> (render.Rect, int) {
	s := w.scale
	rows := min(len(w.workspace_picker.rows)+3, max(1, int((f32(w.height)-132*s)/(34*s))))
	width := min(500*s, max(0, f32(w.width)-24*s))
	return {(f32(w.width)-width)/2, min(64*s, max(0, f32(w.height)-f32(rows)*34*s-112*s)),
		width, 104*s+f32(rows)*34*s}, rows
}

workspace_picker_hit :: proc(w: ^Window, x, y: f32) -> int {
	r, rows := workspace_picker_rect(w)
	if x < r.x+8*w.scale || x >= r.x+r.width-8*w.scale ||
	   y < r.y+96*w.scale || y >= r.y+96*w.scale+f32(rows)*34*w.scale { return -1 }
	return w.workspace_picker.scroll+int((y-r.y-96*w.scale)/(34*w.scale))
}

workspace_picker_pointer :: proc(app: ^App, w: ^Window, x: f32, pressed, extend: bool) {
	r, _ := workspace_picker_rect(w)
	f := &w.workspace_picker.query
	width := max(1, r.width-48*w.scale)
	start := ui.field_view_start(f, &w.ui_text, width)
	at := ui.field_offset_at(f, &w.ui_text, start, r.x+24*w.scale, x)
	ui.field_pointer(f, at, pressed, extend)
	w.dirty = true
}

workspace_picker_draw :: proc(app: ^App, w: ^Window) -> glyphs.Result {
	p := &w.workspace_picker
	r, rows := workspace_picker_rect(w)
	s := w.scale
	p.scroll = clamp(p.scroll, max(0, p.selected-rows+1), p.selected)
	p.scroll = clamp(p.scroll, 0, max(0, len(p.rows)+3-rows))
	if render.push_layer(&w.list, {0, 0, f32(w.width), f32(w.height)}) != .None { return .Ok }
	if render.push_rect(&w.list, {rect = {0, 0, f32(w.width), f32(w.height)}, color = {0, 0, 0, 0.35}}) != .None {
		return .Ok
	}
	if render.push_rect(&w.list, {rect = r, color = app.theme.surface, radius = 10*s}) != .None { return .Ok }
	if render.push_layer(&w.list, r, 10*s) != .None { return .Ok }
	if result := ui.draw_text(&w.ui_text, &w.list, "Change Workspace…", r.x+16*s, r.y+28*s,
		app.theme.text); result != .Ok { return result }
	field := render.Rect{r.x+16*s, r.y+44*s, max(0, r.width-32*s), 36*s}
	if render.push_rect(&w.list, {rect = field, color = app.theme.pane, radius = 5*s}) != .None { return .Ok }
	if result := ui.field_draw(&p.query, &w.list, &w.ui_text, app.theme, field.x+8*s,
		field.y+(field.height-w.ui_text.line_height)/2+w.ui_text.ascent, max(1, field.width-16*s),
		true, "Search workspaces", app.theme.text, s); result != .Ok { return result }
	for visible in 0..<rows {
		i := p.scroll+visible
		row := render.Rect{r.x+8*s, r.y+96*s+f32(visible)*34*s, max(0, r.width-16*s), 34*s}
		if i == p.selected {
			if render.push_rect(&w.list, {rect = row, color = app.theme.selection, radius = 5*s}) != .None {
				return .Ok
			}
		}
		label, detail := "", ""
		if i < len(p.rows) {
			workspace := workspace_find(app, p.rows[i].id)
			if workspace == nil { continue }
			label, detail = workspace.name, p.rows[i].status
			if workspace == w.workspace { detail = "Current" }
			else if window_for_workspace(app, workspace) != nil { detail = "Open in window" }
			if p.rows[i].status != "" && detail != p.rows[i].status {
				detail = fmt.tprintf("%s · %s", detail, p.rows[i].status)
			}
		} else {
			labels := [3]string{"New Workspace", "Rename Workspace…", "New Window"}
			label = labels[i-len(p.rows)]
		}
		baseline := row.y+(row.height-w.ui_text.line_height)/2+w.ui_text.ascent
		detail_width := ui.text_width(&w.ui_text, detail)
		if result := ui.draw_fading_text(&w.ui_text, &w.list, label, row.x+8*s, baseline,
			app.theme.text, max(0, row.width-detail_width-32*s)); result != .Ok { return result }
		if result := ui.draw_text(&w.ui_text, &w.list, detail, row.x+row.width-detail_width-8*s,
			baseline, app.theme.muted, detail_width); result != .Ok { return result }
	}
	return .Ok
}
