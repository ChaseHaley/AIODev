package main

import "aio:glyphs"
import "aio:layout"
import "aio:platform"
import "aio:render"
import "aio:settings"
import "aio:term"
import "aio:ui"
import "core:fmt"
import "core:strings"

Workspace_Row :: struct {
	id: u32,
	status: string,
}

Workspace_Picker :: struct {
	open: bool,
	icons: bool,
	query: ui.Text_Field,
	rows: [dynamic]Workspace_Row,
	selected, scroll: int,
	menu_id, rename_id, icon_id: u32,
	menu_selected: int,
	rename_motion: ui.Motion,
	rename_error: bool,
	saved_query: ui.Text_Field,
}

WORKSPACE_ACTIONS :: [?]Action{.New_Workspace, .New_Window}

@(private)
workspace_rect_contains :: proc(r: render.Rect, x, y: f32) -> bool {
	return x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height
}

workspace_index :: proc(app: ^App, index: int) -> ^Workspace {
	if index < 0 {return nil}
	at := 0
	for workspace in app.workspaces {
		if workspace.provisional {continue}
		if owner := window_for_workspace(app, workspace);
		   owner != nil && owner.preparing {continue}
		if at == index {return workspace}
		at += 1
	}
	return nil
}

workspace_select_index :: proc(app: ^App, w: ^Window, index: int) {
	workspace := workspace_index(app, index)
	if workspace != nil && !workspace_select(app, w, workspace) {
		notify(app, .Error, "Could not select the workspace.")
	}
}

@(require_results)
workspace_create_empty :: proc(app: ^App, provisional := false) -> ^Workspace {
	if app.next_workspace_id == max(u32) {return nil}
	workspace, err := new(Workspace)
	if err != nil {return nil}
	number: u32
	if !provisional {
		workspace.name, number = workspace_default_name(app)
		if number == 0 {free(workspace); return nil}
	}
	workspace.id = app.next_workspace_id + 1
	workspace.provisional = provisional
	if _, append_error := append(&app.workspaces, workspace); append_error != nil {
		workspace_destroy(workspace)
		return nil
	}
	app.next_workspace_id = workspace.id
	if !provisional {app.next_workspace_number = number}
	workspace_pickers_refresh(app)
	return workspace
}

@(require_results)
workspace_discard_empty :: proc(app: ^App, workspace: ^Workspace) -> bool {
	if workspace == nil ||
	   len(workspace.tabs) != 0 ||
	   window_for_workspace(app, workspace) != nil {
		return false
	}
	for current, i in app.workspaces {
		if current != workspace {continue}
		ordered_remove(&app.workspaces, i)
		workspace_destroy(workspace)
		workspace_pickers_refresh(app)
		return true
	}
	return false
}

workspace_find :: proc(app: ^App, id: u32) -> ^Workspace {
	for workspace in app.workspaces {if workspace.id == id {return workspace}}
	return nil
}

@(require_results)
workspace_rename :: proc(app: ^App, workspace: ^Workspace, value: string) -> bool {
	if workspace == nil || workspace_find(app, workspace.id) != workspace {return false}
	clean := settings.display_title(strings.trim_space(value), context.temp_allocator)
	if clean == "" {return false}
	name, err := strings.clone(clean)
	if err != nil {return false}
	delete(workspace.name)
	workspace.name = name
	for w in app.windows {window_relayout(app, w)}
	workspace_pickers_refresh(app)
	return true
}

@(require_results)
workspace_select :: proc(app: ^App, w: ^Window, workspace: ^Workspace) -> bool {
	if workspace == nil ||
	   workspace.provisional ||
	   workspace_find(app, workspace.id) != workspace {return false}
	if owner := window_for_workspace(app, workspace); owner != nil {
		if owner.preparing {return false}
		if owner == w {return true}
		return window_activate(app, owner)
	}
	if len(workspace.tabs) == 0 && !tab_create(app, workspace) {return false}
	// Load before changing ownership so an unreadable settings file leaves the old view intact.
	prepared: Window
	if settings_tab_index(workspace) >= 0 && !settings_load(app, &prepared) {return false}
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
	if workspace.selection_anchor == 0 {tab_select_one(workspace, workspace.selected)}
	clear(&w.tab_positions)
	clear(&w.tab_controls)
	w.tab_underline = {
		value  = f32(workspace.selected),
		target = f32(workspace.selected),
	}
	w.tab_hover, w.tab_close_pressed = -1, -1
	w.tab_pressed = false
	window_relayout(app, w)
	focus_enter(app, w)
	return true
}

workspace_new :: proc(app: ^App, w: ^Window, new_window: bool) {
	workspace := workspace_create_empty(app)
	if workspace == nil {notify(app, .Error, "Could not create a workspace."); return}
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
	workspace_picker_open(app, w)
	workspace_row_rename_open(app, w, w.workspace.id)
}

workspace_button_width :: proc(w: ^Window) -> f32 {
	available := max(0, f32(w.width)-218*w.scale)
	return min(184*w.scale, available, max(40*w.scale, available*0.35))
}

workspace_button_draw :: proc(app: ^App, w: ^Window) -> glyphs.Result {
	width := workspace_button_width(w)
	if width <= 12 * w.scale {return .Ok}
	r := render.Rect{5 * w.scale, 6 * w.scale, max(0, width - 10 * w.scale), 28 * w.scale}
	if render.push_layer(&w.list, {0, 0, width, ui.TAB_HEIGHT * w.scale}) != .None {return .Ok}
	fill := w.workspace_picker.open ? app.theme.selection : app.theme.pane
	if render.push_rect(&w.list, {rect = r, color = fill, radius = 6*w.scale}) != .None { return .Ok }
	if width >= 72*w.scale {
		if result := workspace_icon_draw(w, w.workspace.icon, {10*w.scale, 8*w.scale, 24*w.scale, 24*w.scale},
			app.theme.text); result != .Ok { return result }
	}
	label_width := workspace_button_indicator_rect(w).x-48*w.scale
	if label_width >= 24*w.scale {
		if result := ui.draw_fading_text(&w.ui_text, &w.list, w.workspace.name, 40*w.scale,
			(ui.TAB_HEIGHT*w.scale-w.ui_text.line_height)/2+w.ui_text.ascent,
			app.theme.text, label_width); result != .Ok { return result }
	}
	workspace_chevron_draw(&w.list, workspace_button_indicator_rect(w), app.theme.text, w.scale)
	return .Ok
}

@(private)
workspace_status :: proc(app: ^App, workspace: ^Workspace) -> string {
	done, blocked := false, false
	for tab in workspace.tabs {
		for node in tab.tree.nodes {
			pane, ok := node.(layout.Pane)
			if !ok || pane.content.kind != .Terminal {continue}
			entry := session_find(app, pane.content.id)
			if entry == nil {continue}
			done ||= entry.status == .Exited
			blocked ||= entry.status == .Failed
			statuses, err := term.program_status(entry.session, context.temp_allocator)
			if err != nil {continue}
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
	query := strings.to_lower(
		strings.trim_space(ui.field_string(&p.query)),
		context.temp_allocator,
	)
	for workspace in app.workspaces {
		if workspace.provisional {continue}
		if owner := window_for_workspace(app, workspace);
		   owner != nil && owner.preparing {continue}
		name := strings.to_lower(workspace.name, context.temp_allocator)
		if query != "" && !strings.contains(name, query) {continue}
		if _, err := append(
			&p.rows,
			Workspace_Row{workspace.id, workspace_status(app, workspace)},
		); err != nil {
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
		if p.icons {
			if workspace_row_target(app, p.icon_id) == nil { workspace_picker_return(app, w) }
			continue
		}
		if workspace_row_target(app, p.menu_id) == nil { p.menu_id = 0 }
		if workspace_row_target(app, p.rename_id) == nil { workspace_row_rename_finish(app, w, false) }
		id := p.selected >= 0 && p.selected < len(p.rows) ? p.rows[p.selected].id : 0
		action := p.selected - len(p.rows)
		workspace_picker_filter(app, w)
		if workspace_row_index(w, p.menu_id) < 0 { p.menu_id = 0 }
		if workspace_row_index(w, p.rename_id) < 0 { workspace_row_rename_finish(app, w, false) }
		if id != 0 {
			for row, i in p.rows {if row.id == id {p.selected = i; break}}
		} else {p.selected = len(p.rows) + clamp(action, 0, len(WORKSPACE_ACTIONS) - 1)}
	}
}

workspace_picker_status_changed :: proc(app: ^App) {
	for w in app.windows {
		if !w.workspace_picker.open {continue}
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
	window_overlays_cancel(app, w)
	w.tab_menu.open, w.rename_open = false, false
	w.close_confirm = {}
	tab_close_restore(w)
	w.selecting, w.autoscrolling = false, false
	ui.field_set(&w.workspace_picker.query, "")
	w.workspace_picker.open, w.workspace_picker.icons = true, false
	w.workspace_picker.menu_id, w.workspace_picker.rename_id, w.workspace_picker.icon_id = 0, 0, 0
	w.workspace_picker.rename_motion = {}
	w.rename.dragging = false
	workspace_picker_filter(app, w)
	for row, i in w.workspace_picker.rows {if row.id == w.workspace.id {w.workspace_picker.selected = i}}
}

workspace_icon_open :: proc(app: ^App, w: ^Window) {
	workspace_picker_open(app, w)
	workspace_row_icon_open(app, w, w.workspace.id)
}

workspace_picker_count :: proc(w: ^Window) -> int {
	return w.workspace_picker.icons ? len(WORKSPACE_ICONS)+2 : len(w.workspace_picker.rows)+len(WORKSPACE_ACTIONS)
}

workspace_picker_choose :: proc(app: ^App, w: ^Window) {
	p := &w.workspace_picker
	index, count := p.selected, len(p.rows)
	if p.icons {
		emoji := index >= len(WORKSPACE_ICONS) ? ui.field_string(&p.query) : ""
		if index >= len(WORKSPACE_ICONS) && !workspace_icon_valid(emoji) {
			notify(app, .Error, "Enter an emoji (up to 32 Unicode characters), then apply it.")
			return
		}
		target := workspace_row_target(app, p.icon_id)
		if target == nil { workspace_picker_return(app, w); return }
		if !workspace_icon_set(app, target, index < len(WORKSPACE_ICONS) ? index : 0, emoji) {
			notify(app, .Error, "Could not change the workspace icon.")
			return
		}
		workspace_picker_return(app, w)
		return
	}
	p.open, w.dirty = false, true
	if index < count {
		if index >= 0 && !workspace_select(app, w, workspace_find(app, p.rows[index].id)) {
			notify(app, .Error, "Could not select the workspace.")
		}
		return
	}
	if index - count >= 0 && index - count < len(WORKSPACE_ACTIONS) {
		@(static, rodata)
		actions := WORKSPACE_ACTIONS
		run_action(app, w, actions[index - count])
	}
}

workspace_picker_text :: proc(app: ^App, w: ^Window, value: string) {
	if w.workspace_picker.menu_id != 0 { return }
	if w.workspace_picker.rename_id != 0 {
		ui.field_text(&w.rename, value)
		w.workspace_picker.rename_error, w.dirty = false, true
		return
	}
	ui.field_text(&w.workspace_picker.query, value)
	if w.workspace_picker.icons {
		w.workspace_picker.selected, w.dirty = len(WORKSPACE_ICONS), true
		return
	}
	workspace_picker_filter(app, w)
}

workspace_picker_key :: proc(app: ^App, w: ^Window, e: platform.Key_Event) {
	if !e.pressed {return}
	p := &w.workspace_picker
	if workspace_row_key(app, w, e) { return }
	count := workspace_picker_count(w)
	w.dirty = true
	if p.icons && workspace_icon_picker_key(w, e) { return }
	if step := ui.list_step(e); step != 0 {
		p.selected = (p.selected + count + step) % count
		return
	}
	#partial switch e.key {
	case .Escape:
		if p.icons { workspace_picker_return(app, w) } else { p.open = false }
	case .Tab: p.selected = (p.selected+count+(.Shift in e.modifiers ? -1 : 1))%count
	case .Enter, .Numpad_Enter: workspace_picker_choose(app, w)
	case .Delete:
		if !p.icons && e.modifiers == {.Shift} && p.selected < len(p.rows) {
			workspace_delete_request(app, w, workspace_find(app, p.rows[p.selected].id))
		} else {
			change := ui.field_key(&p.query, e)
			if p.icons && change != .None { p.selected = len(WORKSPACE_ICONS) }
			else if change == .Edited { workspace_picker_filter(app, w) }
		}
	case:
		switch clipboard_chord(e) {
		case .Copy:
			clipboard_copy(app, ui.field_selected_text(&p.query))
		case .Cut:
			if clipboard_copy(
				app,
				ui.field_selected_text(&p.query),
			) {workspace_picker_text(app, w, "")}
		case .Paste:
			if text, ok := platform.clipboard_get_text(&app.platform, context.temp_allocator); ok {
				workspace_picker_text(app, w, text)
			}
		case .None:
			change := ui.field_key(&p.query, e)
			if p.icons && change != .None { p.selected = len(WORKSPACE_ICONS) }
			else if change == .Edited { workspace_picker_filter(app, w) }
		}
	}
	w.dirty = true
}

workspace_picker_header :: proc(w: ^Window) -> f32 {
	return 56*w.scale
}

workspace_picker_rect :: proc(w: ^Window) -> (render.Rect, int) {
	if w.workspace_picker.icons {
		g := workspace_icon_picker_layout(w)
		return g.panel, g.visible_rows
	}
	s := w.scale
	x, y := 5 * s, ui.TAB_HEIGHT * s
	width := min(380 * s, max(0, f32(w.width) - 10 * s))
	header := workspace_picker_header(w)
	extra := workspace_row_rename_height(w)
	reserve := w.workspace_picker.rename_id != 0 ? 68*s : 0
	rows := min(workspace_picker_count(w), max(1, int((f32(w.height)-y-header-24*s-reserve)/(34*s))))
	height := min(max(0, f32(w.height)-y-5*s), header+f32(rows)*34*s+16*s+extra)
	return {x, y, width, height}, rows
}

workspace_picker_field_rect :: proc(w: ^Window) -> render.Rect {
	if w.workspace_picker.icons { return workspace_icon_picker_layout(w).field }
	r, _ := workspace_picker_rect(w)
	s := w.scale
	return {r.x+12*s, r.y+12*s, max(0, r.width-24*s), 32*s}
}

workspace_picker_row_rect :: proc(w: ^Window, index: int) -> render.Rect {
	if w.workspace_picker.icons { return workspace_icon_picker_cell(w, workspace_icon_picker_layout(w), index) }
	r, _ := workspace_picker_rect(w)
	p, s := &w.workspace_picker, w.scale
	gap := !p.icons && index >= len(p.rows) && p.scroll <= len(p.rows) ? 8*s : 0
	rename_index := workspace_row_index(w, p.rename_id)
	if rename_index >= p.scroll && index > rename_index { gap += workspace_row_rename_height(w) }
	return {r.x+6*s, r.y+workspace_picker_header(w)+f32(index-p.scroll)*34*s+gap,
		max(0, r.width-12*s), 34*s}
}

workspace_picker_hit :: proc(w: ^Window, x, y: f32) -> int {
	if w.workspace_picker.icons { return workspace_icon_picker_hit(w, x, y) }
	r, rows := workspace_picker_rect(w)
	if !workspace_rect_contains(r, x, y) {return -1}
	for visible in 0 ..< rows {
		i := w.workspace_picker.scroll + visible
		if i >= workspace_picker_count(w) {break}
		if workspace_rect_contains(workspace_picker_row_rect(w, i), x, y) {return i}
	}
	return -1
}

workspace_picker_menu_button_rect :: proc(w: ^Window, index: int) -> render.Rect {
	r := workspace_picker_row_rect(w, index)
	return {r.x+r.width-34*w.scale, r.y+w.scale, 32*w.scale, 32*w.scale}
}

workspace_picker_click :: proc(app: ^App, w: ^Window, x, y: f32, extend: bool) {
	p := &w.workspace_picker
	if workspace_row_click(app, w, x, y, extend) { return }
	if hit := workspace_picker_hit(w, x, y); hit >= 0 {
		if !p.icons && hit < len(p.rows) &&
		   workspace_rect_contains(workspace_picker_menu_button_rect(w, hit), x, y) {
			workspace_row_menu_open(app, w, p.rows[hit].id)
			return
		}
		p.selected = hit
		workspace_picker_choose(app, w)
	} else if workspace_rect_contains(workspace_picker_field_rect(w), x, y) {
		workspace_picker_pointer(app, w, x, true, extend)
	}
}

workspace_picker_pointer :: proc(app: ^App, w: ^Window, x: f32, pressed, extend: bool) {
	if w.workspace_picker.icons { w.workspace_picker.selected = len(WORKSPACE_ICONS) }
	r := workspace_picker_field_rect(w)
	f := &w.workspace_picker.query
	if w.workspace_picker.rename_id != 0 { r, f = workspace_row_rename_field_rect(w), &w.rename }
	width := max(1, r.width-16*w.scale)
	start := ui.field_view_start(f, &w.ui_text, width)
	at := ui.field_offset_at(f, &w.ui_text, start, r.x + 8 * w.scale, x)
	ui.field_pointer(f, at, pressed, extend)
	w.dirty = true
}

workspace_picker_draw :: proc(app: ^App, w: ^Window) -> glyphs.Result {
	p := &w.workspace_picker
	r, rows := workspace_picker_rect(w)
	s := w.scale
	@(static, rodata) actions := WORKSPACE_ACTIONS
	@(static, rodata) action_info := ACTIONS
	if !p.icons {
		if index := workspace_row_index(w, p.rename_id); index >= 0 { p.selected = index }
		p.scroll = clamp(p.scroll, max(0, p.selected-rows+1), p.selected)
		p.scroll = clamp(p.scroll, 0, max(0, workspace_picker_count(w)-rows))
	}
	if render.push_layer(&w.list, {0, 0, f32(w.width), f32(w.height)}) != .None { return .Ok }
	shadow := render.Rect{r.x+2*s, r.y+3*s, r.width, r.height}
	if render.push_rect(&w.list, {rect = shadow, color = app.theme.shadow, radius = 7*s}) != .None { return .Ok }
	if render.push_rect(&w.list, {rect = r, color = app.theme.surface, radius = 7*s}) != .None { return .Ok }
	if render.push_layer(&w.list, r, 7*s) != .None { return .Ok }
	if p.icons { return workspace_icon_picker_draw(app, w) }
	field := workspace_picker_field_rect(w)
	if render.push_rect(&w.list, {rect = field, color = app.theme.pane, radius = 5*s}) != .None { return .Ok }
	if result := ui.field_draw(&p.query, &w.list, &w.ui_text, app.theme, field.x+8*s,
		field.y+(field.height-w.ui_text.line_height)/2+w.ui_text.ascent, max(1, field.width-16*s),
		p.rename_id == 0 && p.menu_id == 0, "Search workspaces", app.theme.text, s); result != .Ok { return result }
	for visible in 0..<rows {
		i := p.scroll+visible
		if i >= workspace_picker_count(w) { break }
		row := workspace_picker_row_rect(w, i)
		if !p.icons && i == len(p.rows) {
			divider := render.Rect{row.x + 6 * s, row.y - 5 * s, max(0, row.width - 12 * s), s}
			if render.push_rect(&w.list, {rect = divider, color = app.theme.border}) !=
			   .None {return .Ok}
		}
		if i == p.selected {
			if render.push_rect(
				   &w.list,
				   {rect = row, color = app.theme.selection, radius = 5 * s},
			   ) !=
			   .None {return .Ok}
		}
		label, detail := "", ""
		icon := Workspace_Icon{}
		has_icon := false
		if i < len(p.rows) {
			workspace := workspace_find(app, p.rows[i].id)
			if workspace == nil {continue}
			label, detail, icon, has_icon = workspace.name, p.rows[i].status, workspace.icon, true
			if workspace == w.workspace { detail = "Current" }
			else if window_for_workspace(app, workspace) != nil { detail = "Open in window" }
			if p.rows[i].status != "" && detail != p.rows[i].status {
				detail = fmt.tprintf("%s · %s", detail, p.rows[i].status)
			}
		} else {label = action_info[actions[i - len(p.rows)]].title}
		baseline := row.y + (row.height - w.ui_text.line_height) / 2 + w.ui_text.ascent
		label_x := row.x + 8 * s
		if has_icon {
			if result := workspace_icon_draw(
				w,
				icon,
				{row.x + 6 * s, row.y + 5 * s, 24 * s, 24 * s},
				app.theme.text,
			); result != .Ok {return result}
			label_x += 30 * s
		}
		right := row.x+row.width-8*s
		if has_icon {
			workspace_row_ellipsis_draw(app, w, i)
			right -= 36*s
		}
		detail_width := min(ui.text_width(&w.ui_text, detail), max(0, (right - label_x) * 0.5))
		if result := ui.draw_fading_text(
			&w.ui_text,
			&w.list,
			label,
			label_x,
			baseline,
			app.theme.text,
			max(0, right - label_x - detail_width - 8 * s),
		); result != .Ok {return result}
		if result := ui.draw_fading_text(
			&w.ui_text,
			&w.list,
			detail,
			right - detail_width,
			baseline,
			app.theme.muted,
			detail_width,
		); result != .Ok {return result}
	}
	if result := workspace_row_rename_draw(app, w); result != .Ok { return result }
	return workspace_row_menu_draw(app, w)
}
