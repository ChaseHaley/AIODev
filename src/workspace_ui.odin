package main

import "aio:input"
import "aio:render"
import "aio:ui"
import "core:fmt"
import "core:strings"

Workspace_Row :: struct {
	id: u32,
	status: string,
}

WORKSPACE_ACTIONS :: [?]Action{.New_Workspace, .New_Window}

workspace_index :: proc(app: ^App, index: int) -> ^Workspace {
	if index < 0 {return nil}
	at := 0
	for workspace in app.workspaces {
		if !workspace_eligible(app, workspace) {continue}
		if at == index {return workspace}
		at += 1
	}
	return nil
}

workspace_select_index :: proc(app: ^App, w: ^Window, index: int) {
	workspace := workspace_index(app, index)
	if workspace == nil {return}
	if !workspace_select(app, w, workspace) {
		notify(app, .Error, "Could not select the workspace.")
		return
	}
	rail_overlay_dismiss(app, w)
}

// Steps through the same order as Select Workspace N, wrapping at either end.
workspace_select_step :: proc(app: ^App, w: ^Window, step: int) {
	count, current := 0, -1
	for workspace in app.workspaces {
		if !workspace_eligible(app, workspace) {continue}
		if workspace == w.workspace {current = count}
		count += 1
	}
	if count < 2 || current < 0 {return}
	workspace_select_index(app, w, (current + step + count) % count)
}

@(require_results)
workspace_create_empty :: proc(app: ^App, provisional := false) -> ^Workspace {
	if app.next_workspace_id == max(u32) {return nil}
	workspace, err := new(Workspace)
	if err != nil {return nil}
	if !provisional {
		workspace.name = workspace_default_name(app)
		if workspace.name == "" {free(workspace); return nil}
	}
	workspace.id = app.next_workspace_id + 1
	workspace.provisional = provisional
	if _, append_error := append(&app.workspaces, workspace); append_error != nil {
		workspace_destroy(workspace)
		return nil
	}
	app.next_workspace_id = workspace.id
	workspace_mutation_finish(app, workspace, {.Names})
	return workspace
}

@(require_results)
workspace_discard_empty :: proc(app: ^App, workspace: ^Workspace) -> bool {
	// Deliberately not workspace_eligible: a tear-off preview is provisional, and discarding it
	// is how that preview workspace is torn down.
	if workspace == nil ||
	   len(workspace.tabs) != 0 ||
	   window_for_workspace(app, workspace) != nil {
		return false
	}
	for current, i in app.workspaces {
		if current != workspace {continue}
		ordered_remove(&app.workspaces, i)
		workspace_destroy(workspace)
		workspace_mutation_finish(app, nil, {.Names})
		return true
	}
	return false
}

workspace_find :: proc(app: ^App, id: u32) -> ^Workspace {
	for workspace in app.workspaces {if workspace.id == id {return workspace}}
	return nil
}

@(require_results)
workspace_select :: proc(app: ^App, w: ^Window, workspace: ^Workspace) -> bool {
	if !workspace_eligible(app, workspace) {return false}
	if owner := window_for_workspace(app, workspace); owner != nil {
		if owner == w {return true}
		return window_activate(app, owner)
	}
	if len(workspace.tabs) == 0 {
		if _, created := tab_create(app, workspace); !created {return false}
	}
	// Loading happens inside adoption before ownership changes, so an unreadable settings file
	// leaves the old view intact.
	return workspace_adopt(app, w, workspace, .Retain)
}

// Creates the workspace and its shell at once, under a suggested name. Launching AIODev again asks for
// a shell, not a name, so only the other paths start naming it in its chip.
workspace_new :: proc(app: ^App, w: ^Window, new_window: bool, name_it := true) {
	owner := w
	if owner == nil {owner = window_primary(app)}
	if owner == nil {return}
	if !gesture_cancel(app, owner) {return}
	workspace_picker_cancel(owner)
	palette_close(app, owner)
	workspace := workspace_create_empty(app)
	if workspace == nil {notify(app, .Error, "Could not create a workspace."); return}
	if _, created := tab_create(app, workspace); !created {
		_ = workspace_discard_empty(app, workspace)
		notify(app, .Error, "Could not create the workspace shell.")
		return
	}
	opened := new_window ? window_open(app, workspace) : workspace_select(app, owner, workspace)
	if !opened {
		workspace_close_tab(app, workspace, 0)
		_ = workspace_discard_empty(app, workspace)
		notify(app, .Error, "Could not open the new workspace.")
		return
	}
	mark_all_dirty(app)
	if !name_it {return}
	if target := window_for_workspace(app, workspace); target != nil {workspace_name_begin(app, target)}
}

workspace_button_width :: proc(w: ^Window) -> f32 {
	left := title_actions_end(w)
	available := max(0, f32(w.width) - window_caption_reserve(w) - left)
	return left + min(184 * w.scale, available, max(40 * w.scale, available * 0.35))
}

// The chip's visual and hit rectangle. Hit testing keeps this rectangle even while the
// control is drawn lifted, so the hover never changes where the click target is.
workspace_button_rect :: proc(w: ^Window) -> render.Rect {
	width := workspace_button_width(w)
	left := title_actions_end(w)
	height := ui.HEIGHT_TOOLBAR * w.scale
	top := (ui.TITLE_BAR_HEIGHT * w.scale - height) / 2
	return {left + ui.SPACE_1 * w.scale, top, max(0, width - left - 2 * ui.SPACE_1 * w.scale), height}
}

workspace_button_draw :: proc(app: ^App, w: ^Window) -> render.Build_Status {
	width := workspace_button_width(w)
	if width <= 12 * w.scale {return .Ok}
	r := workspace_button_rect(w)
	// While the chip holds the name field it stays flat, so nothing shows around the field.
	hover := chip_name_shown(w) ? 0 : w.workspace_motion.hover.value
	lift := ui.hover_lift_at(app.theme, hover, w.scale)
	r.y -= lift
	if render.push_layer(&w.list, {0, 0, width, ui.TITLE_BAR_HEIGHT * w.scale}) != .None {return .Ok}
	radius := ui.RADIUS_CONTROL * w.scale
	if lift > 0 {
		if result := ui.hover_shadow_draw(&w.list, app.theme, r, radius, hover, w.scale);
		   result != .None {return .Ok}
	}
	active := workspace_picker_active(&w.workspace_picker)
	fill := active ? app.theme.selection : app.theme.pane
	if render.push_rect(&w.list, {rect = r, color = fill, radius = radius}) != .None { return .Ok }
	// An open picker already tints the chip; an opaque paper fill would paint over it, while a
	// translucent dark fill can pass over without hiding it.
	skip_fill := ui.hover_fill_opaque(app.theme) && active
	if hover > 0 && !skip_fill {
		fill = app.theme.hover
		fill.a *= hover
		if render.push_rect(&w.list, {rect = r, color = fill, radius = radius}) != .None {
			return .Ok
		}
	}
	if width >= 72 * w.scale {
		size := ui.ICON_BUTTON * w.scale
		icon := render.Rect{r.x + ui.CONTROL_INSET * w.scale, r.y + (r.height - size) / 2, size, size}
		if result := workspace_icon_draw(w, w.workspace.icon, icon, app.theme.text);
		   result != .Ok { return result }
	}
	indicator := workspace_button_indicator_rect(w)
	indicator.y -= lift
	label_x := r.x + (ui.CONTROL_INSET + ui.ICON_BUTTON + ui.SPACE_2) * w.scale
	label_width := indicator.x - label_x - ui.SPACE_2 * w.scale
	if label_width >= 24 * w.scale {
		if result := ui.draw_fading_text(&w.ui_text, &w.list, w.workspace.name, label_x,
			r.y + (r.height - w.ui_text.line_height) / 2 + w.ui_text.ascent,
			app.theme.text, label_width); result != .Ok { return result }
	}
	chevron_ink := hover > 0 ? app.theme.text : app.theme.muted
	ui.icon_draw(&w.list, .Chevron_Down, indicator, chevron_ink, ui.ICON_INDICATOR, w.scale)
	if hover > 0 {
		if result := ui.hover_rim_draw(
			&w.list,
			app.theme,
			r,
			6 * w.scale,
			hover,
			w.scale,
			w.pointer,
			!skip_fill,
		); result != .None {return .Ok}
	}
	return .Ok
}

@(private)
workspace_status :: proc(app: ^App, workspace: ^Workspace) -> string {
	done, blocked := false, false
	walk := workspace_session_panes(app, workspace)
	for pane, ok := workspace_pane_next(&walk); ok; pane, ok = workspace_pane_next(&walk) {
		entry := pane.session
		if entry == nil {continue}
		done ||= entry.status == .Exited
		blocked ||= entry.status == .Failed
	}
	if blocked {
		return "Blocked"
	}
	if done {
		return "Finished"
	}
	return ""
}

workspace_picker_filter :: proc(app: ^App, w: ^Window) {
	defer workspace_picker_layout_changed(w)
	p := &w.workspace_picker
	clear(&p.rows)
	query := strings.to_lower(
		strings.trim_space(ui.field_string(&p.query)),
		context.temp_allocator,
	)
	move, _ := workspace_picker_move(p)
	for workspace in app.workspaces {
		if !workspace_eligible(app, workspace) {continue}
		if move.request.workspace == workspace.id {continue}
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
workspace_pickers_refresh :: proc(app: ^App, preserve_scroll := false) {
	for w in app.windows {
		p := &w.workspace_picker
		if !workspace_picker_active(p) { continue }
		if id := workspace_order_grabbed(p); id != 0 && workspace_row_target(app, id) == nil {
			workspace_order_end(w)
		}
		if workspace_picker_icons(p) {
			if workspace_row_target(app, workspace_picker_icon_id(p)) == nil {
				workspace_picker_return(app, w)
			}
			continue
		}
		if id := workspace_picker_menu_id(p); id != 0 && workspace_row_target(app, id) == nil {
			workspace_picker_transition(w, Workspace_Picker_List{})
		}
		if id := workspace_picker_rename_id(p); id != 0 && workspace_row_target(app, id) == nil {
			workspace_row_rename_finish(app, w, false)
		}
		selected := workspace_picker_selection(w)
		scroll := p.scroll
		workspace_picker_filter(app, w)
		if menu := workspace_picker_menu_id(p); menu != 0 && workspace_row_index(w, menu) < 0 {
			workspace_picker_transition(w, Workspace_Picker_List{})
		}
		if rename := workspace_picker_rename_id(p); rename != 0 && workspace_row_index(w, rename) < 0 {
			workspace_row_rename_finish(app, w, false)
		}
		// The cursor stays on its target. A workspace row filtered out leaves it at the top; a cursor on no
		// row goes to the first target after the rows.
		if index, shown := workspace_picker_target_index(w, selected); shown {
			p.selected = index
		} else if _, row := selected.(Picker_Workspace); !row {p.selected = len(p.rows)}
		if preserve_scroll {p.scroll = scroll}
		workspace_picker_layout_changed(w)
	}
}

workspace_picker_status_changed :: proc(app: ^App) {
	for w in app.windows {
		if !workspace_picker_active(&w.workspace_picker) {continue}
		for &row in w.workspace_picker.rows {
			if workspace := workspace_find(app, row.id); workspace != nil {
				row.status = workspace_status(app, workspace)
			}
		}
		w.dirty = true
	}
}

workspace_picker_open :: proc(app: ^App, w: ^Window) {
	if !gesture_cancel(app, w) {return}
	defer workspace_picker_layout_changed(w)
	window_overlays_cancel(app, w)
	ui.field_set(&w.workspace_picker.query, "")
	workspace_picker_transition(w, Workspace_Picker_List{})
	workspace_picker_filter(app, w)
	for row, i in w.workspace_picker.rows {if row.id == w.workspace.id {w.workspace_picker.selected = i}}
}

workspace_icon_open :: proc(app: ^App, w: ^Window) {
	workspace_picker_open(app, w)
	workspace_row_icon_open(app, w, w.workspace.id)
}

workspace_picker_choose :: proc(app: ^App, w: ^Window) {
	p := &w.workspace_picker
	chosen := workspace_picker_selection(w)
	if move, moving := workspace_picker_move(p); moving {
		destination: Workspace_Move_Destination
		#partial switch t in chosen {
		case Picker_Workspace: destination = Workspace_Move_Existing{t.id}
		case Picker_New_Workspace: destination = Workspace_Move_New{}
		case: return
		}
		workspace_picker_cancel(w)
		workspace_move_choose(app, w, move.request, destination)
		return
	}
	defer workspace_picker_layout_changed(w)
	if workspace_picker_icons(p) {
		preset, emoji := 0, ""
		#partial switch t in chosen {
		case Picker_Tint, Picker_Tint_Back: workspace_icon_color_choose(app, w); return
		case Picker_Tint_Open: workspace_icon_color_open(app, w); return
		case Picker_Icon: preset = t.preset
		case Picker_Emoji_Field, Picker_Emoji_Apply:
			emoji = ui.field_string(&p.query)
			if !workspace_icon_valid(emoji) {
				notify(app, .Error, "Enter an emoji (up to 32 Unicode characters), then apply it.")
				return
			}
		case: return
		}
		workspace := workspace_row_target(app, workspace_picker_icon_id(p))
		if workspace == nil { workspace_picker_return(app, w); return }
		if !workspace_icon_set(app, workspace, preset, emoji) {
			notify(app, .Error, "Could not change the workspace icon.")
			return
		}
		workspace_picker_return(app, w)
		return
	}
	workspace_picker_cancel(w)
	#partial switch t in chosen {
	case Picker_Workspace:
		if !workspace_select(app, w, workspace_find(app, t.id)) {
			notify(app, .Error, "Could not select the workspace.")
		}
	case Picker_Action: run_action(app, w, t.action)
	}
}

workspace_picker_text :: proc(app: ^App, w: ^Window, value: string) {
	defer workspace_picker_layout_changed(w)
	workspace_order_reset(w)
	p := &w.workspace_picker
	#partial switch _ in p.state {
	case Workspace_Picker_Tint, Workspace_Picker_Menu: return
	case Workspace_Picker_Rename:
		ui.field_text(&p.rename, value)
		workspace_row_rename_error_set(w, false)
		return
	}
	ui.field_text(&p.query, value)
	if workspace_picker_icons(p) {
		workspace_picker_select_target(w, Picker_Emoji_Field{})
		return
	}
	workspace_picker_filter(app, w)
}

workspace_picker_key :: proc(app: ^App, w: ^Window, e: input.Key_Event) {
	window_id := w.id
	defer if window_find(app, window_id) == w {workspace_picker_layout_changed(w)}
	if !e.pressed {return}
	p := &w.workspace_picker
	if workspace_order_grabbed(p) != 0 {
		workspace_order_end(w)
		if e.key == .Escape {return}
	}
	if workspace_row_key(app, w, e) { return }
	count := workspace_picker_count(w)
	w.dirty = true
	if workspace_picker_tint(p) { workspace_icon_color_key(app, w, e); return }
	if workspace_picker_icons(p) && workspace_icon_picker_key(w, e) { return }
	if step := ui.list_step(e); step != 0 {
		p.selected = (p.selected + count + step) % count
		return
	}
	#partial switch e.key {
	case .Escape:
		if workspace_picker_icons(p) { workspace_picker_return(app, w) } else { workspace_picker_cancel(w) }
	case .Tab: p.selected = (p.selected + count + (.Shift in e.modifiers ? -1 : 1)) % count
	case .Enter, .Numpad_Enter: workspace_picker_choose(app, w); return
	case .Delete:
		row, on_row := workspace_picker_selection(w).(Picker_Workspace)
		if workspace_picker_browsing(p) && e.modifiers == {.Shift} && on_row {
			workspace_delete_request(app, w, workspace_find(app, row.id))
		} else {
			change := ui.field_key(&p.query, e)
			if workspace_picker_icons(p) && change != .None {
				workspace_picker_select_target(w, Picker_Emoji_Field{})
			} else if change == .Edited { workspace_picker_filter(app, w) }
		}
	case:
		edit := field_edit_key(app, &p.query, e)
		if workspace_picker_icons(p) && (edit.change != .None || edit.pasted) {
			workspace_picker_select_target(w, Picker_Emoji_Field{})
		} else if edit.change == .Edited || edit.pasted {
			workspace_picker_filter(app, w)
		}
	}
	w.dirty = true
}

// The search field sits in the row column, so its text lines up with the row labels.
// Workspace rows are standard rows; their icons are 16 DIP like every leading icon.
WORKSPACE_ROW_HEIGHT :: ui.HEIGHT_STANDARD

workspace_picker_header :: proc(w: ^Window) -> f32 {
	return (ui.OVERLAY_PADDING + ui.HEIGHT_STANDARD + 8) * w.scale
}

workspace_picker_rect :: proc(w: ^Window) -> (render.Rect, int) {
	if workspace_picker_icons(&w.workspace_picker) {
		g := workspace_icon_picker_layout(w)
		return g.panel, g.visible_rows
	}
	s := w.scale
	x, y := ui.SPACE_1 * s, ui.TITLE_BAR_HEIGHT * s
	width := min(380 * s, max(0, f32(w.width) - 2 * ui.SPACE_1 * s))
	header := workspace_picker_header(w)
	extra := workspace_row_rename_height(w)
	_, renaming := w.workspace_picker.state.(Workspace_Picker_Rename)
	reserve := renaming ? WORKSPACE_RENAME_HEIGHT * s : 0
	available := f32(w.height) - y - header - 24 * s - reserve
	rows := min(workspace_picker_count(w), max(1, int(available / (WORKSPACE_ROW_HEIGHT * s))))
	content := header + f32(rows) * WORKSPACE_ROW_HEIGHT * s + (8 + ui.OVERLAY_PADDING) * s + extra
	height := min(max(0, f32(w.height) - y - ui.SPACE_1 * s), content)
	return {x, y, width, height}, rows
}

workspace_picker_field_rect :: proc(w: ^Window) -> render.Rect {
	if workspace_picker_tint(&w.workspace_picker) { return {} }
	if workspace_picker_icons(&w.workspace_picker) { return workspace_icon_picker_layout(w).field }
	r, _ := workspace_picker_rect(w)
	s := w.scale
	pad := ui.OVERLAY_PADDING * s
	return {r.x + pad, r.y + pad, max(0, r.width - 2 * pad), ui.HEIGHT_STANDARD * s}
}

workspace_picker_query_box :: proc(w: ^Window) -> ui.Field_Box {
	rect := workspace_picker_field_rect(w)
	return ui.field_box_standard(&w.workspace_picker.query, &w.ui_text, rect, w.scale)
}

workspace_picker_slot_rect :: proc(w: ^Window, index: int) -> render.Rect {
	if workspace_picker_icons(&w.workspace_picker) {
		return workspace_icon_picker_cell(w, workspace_icon_picker_layout(w), index)
	}
	r, _ := workspace_picker_rect(w)
	p, s := &w.workspace_picker, w.scale
	gap := !workspace_picker_icons(p) && index >= len(p.rows) && p.scroll <= len(p.rows) ? 8 * s : 0
	rename_index := workspace_row_index(w, workspace_picker_rename_id(p))
	if rename_index >= p.scroll && index > rename_index { gap += workspace_row_rename_height(w) }
	pad := ui.OVERLAY_PADDING * s
	row_height := WORKSPACE_ROW_HEIGHT * s
	return {r.x + pad, r.y + workspace_picker_header(w) + f32(index - p.scroll) * row_height + gap,
		max(0, r.width - 2 * pad), row_height}
}

workspace_picker_row_rect :: proc(w: ^Window, index: int) -> render.Rect {
	r := workspace_picker_slot_rect(w, index)
	p := &w.workspace_picker
	if index >= 0 && index < len(p.rows) && !workspace_picker_icons(p) {
		if entry := workspace_order_position(p, p.rows[index].id); entry != nil {
			r.y += (entry.position.value - f32(index)) * r.height
		}
	}
	return r
}

workspace_picker_hit :: proc(w: ^Window, x, y: f32) -> int {
	if workspace_picker_icons(&w.workspace_picker) { return workspace_icon_picker_hit(w, x, y) }
	r, _ := workspace_picker_rect(w)
	if !render.rect_contains(r, x, y) {return -1}
	if y < r.y + workspace_picker_header(w) {return -1}
	for lifted in ([?]bool{true, false}) {
		for i in 0..<workspace_picker_count(w) {
			if workspace_order_lifted(&w.workspace_picker, i) != lifted {continue}
			if render.rect_contains(workspace_picker_row_rect(w, i), x, y) {return i}
		}
	}
	return -1
}

workspace_picker_menu_button_rect :: proc(w: ^Window, index: int) -> render.Rect {
	r := workspace_picker_row_rect(w, index)
	size := ui.HEIGHT_COMPACT * w.scale
	return {r.x + r.width - ui.SPACE_1 * w.scale - size, r.y + (r.height - size) / 2, size, size}
}

workspace_picker_click :: proc(app: ^App, w: ^Window, x, y: f32, extend: bool) {
	window_id := w.id
	defer if window_find(app, window_id) == w {workspace_picker_layout_changed(w)}
	p := &w.workspace_picker
	if workspace_row_click(app, w, x, y, extend) { return }
	if hit := workspace_picker_hit(w, x, y); hit >= 0 {
		row, on_row := workspace_picker_target_at(w, hit).(Picker_Workspace)
		if workspace_picker_browsing(p) && on_row &&
		   render.rect_contains(workspace_picker_menu_button_rect(w, hit), x, y) {
			workspace_row_menu_open(app, w, row.id)
			return
		}
		p.selected = hit
		workspace_picker_choose(app, w)
	} else if render.rect_contains(workspace_picker_field_rect(w), x, y) {
		workspace_picker_pointer(app, w, x, true, extend)
	}
}

workspace_picker_pointer :: proc(app: ^App, w: ^Window, x: f32, pressed, extend: bool) {
	defer workspace_picker_layout_changed(w)
	if workspace_picker_icons(&w.workspace_picker) { workspace_picker_select_target(w, Picker_Emoji_Field{}) }
	box := workspace_picker_query_box(w)
	if _, renaming := w.workspace_picker.state.(Workspace_Picker_Rename); renaming {
		box = workspace_row_rename_box(w)
	}
	ui.field_pointer(box.field, ui.field_box_offset(box, x), pressed, extend)
	w.dirty = true
}

workspace_picker_draw :: proc(app: ^App, w: ^Window) -> render.Build_Status {
	p := &w.workspace_picker
	r, _ := workspace_picker_rect(w)
	s := w.scale
	@(static, rodata) action_info := ACTIONS
	if !ui.popover_open(&w.list, r, app.theme, f32(w.width), f32(w.height), s) { return .Ok }
	if workspace_picker_icons(p) { return workspace_icon_picker_draw(app, w) }
	box := workspace_picker_query_box(w)
	field := box.rect
	field_fill := render.Rect_Instance{rect = field, color = app.theme.pane, radius = ui.RADIUS_CONTROL * s}
	if render.push_rect(&w.list, field_fill) != .None {
		return .Ok
	}
	_, listing := p.state.(Workspace_Picker_List)
	if result := ui.field_box_draw(box, &w.list, app.theme, ui.field_box_baseline(box),
		listing, "Search workspaces"); result != .Ok { return result }
	if render.push_layer(&w.list, r, ui.RADIUS_OVERLAY * s) != .None { return .Ok }
	clip := render.Rect{r.x, r.y + workspace_picker_header(w), r.width,
		max(0, r.height - workspace_picker_header(w) - ui.OVERLAY_PADDING * s)}
	_, moving := workspace_picker_move(p)
	for lifted in ([?]bool{false, true}) {
		if render.push_layer(&w.list, clip) != .None {return .Ok}
		for i in 0..<workspace_picker_count(w) {
			if workspace_order_lifted(p, i) != lifted {continue}
			row := workspace_picker_row_rect(w, i)
			if row.y + row.height <= clip.y || row.y >= clip.y + clip.height {continue}
			if lifted {
				if render.push_rect(&w.list, {rect = row, color = app.theme.surface,
					radius = ui.RADIUS_CONTROL * s}) != .None {return .Ok}
			}
			if !workspace_picker_icons(p) && i == len(p.rows) {
				divider := render.Rect{row.x + 8 * s, row.y - 4 * s, max(0, row.width - 16 * s), s}
				if render.push_rect(&w.list, {rect = divider, color = app.theme.border}) !=
				   .None {return .Ok}
			}
			if i == p.selected {
				if render.push_rect(
					   &w.list,
					   {rect = row, color = app.theme.selection, radius = ui.RADIUS_CONTROL * s},
				   ) !=
				   .None {return .Ok}
			}
			label, detail := "", ""
			icon := Workspace_Icon{}
			has_icon := false
			#partial switch t in workspace_picker_target_at(w, i) {
			case Picker_Workspace:
				workspace := workspace_find(app, t.id)
				if workspace == nil {continue}
				label, detail, icon, has_icon = workspace.name, p.rows[i].status, workspace.icon, true
				if workspace == w.workspace { detail = "Current" }
				else if window_for_workspace(app, workspace) != nil { detail = "Open in window" }
				if p.rows[i].status != "" && detail != p.rows[i].status {
					detail = fmt.tprintf("%s · %s", detail, p.rows[i].status)
				}
				if program := status_picker_text(app, workspace); program != "" {
					detail = detail == "" ? program : fmt.tprintf("%s · %s", detail, program)
				}
			case Picker_New_Workspace: label = "Move to New Workspace"
			case Picker_New_Window: label = "Move to New Window"
			case Picker_Action: label = action_info[t.action].title
			}
			baseline := row.y + (row.height - w.ui_text.line_height) / 2 + w.ui_text.ascent
			label_x := row.x + ui.CONTROL_INSET * s
			if has_icon {
				if result := workspace_icon_draw(
					w,
					icon,
					{label_x, row.y + (row.height - ui.ICON_BUTTON * s) / 2, ui.ICON_BUTTON * s, ui.ICON_BUTTON * s},
					app.theme.text,
				); result != .Ok {return result}
				label_x += (ui.ICON_BUTTON + ui.SPACE_2) * s
			}
			right := row.x + row.width - ui.CONTROL_INSET * s
			if has_icon && !moving {
				workspace_row_ellipsis_draw(app, w, i)
				right = row.x + row.width - (ui.SPACE_1 + ui.HEIGHT_COMPACT + ui.SPACE_2) * s
			}
			detail_text := ui.text_styled(&w.ui_text, .Detail)
			detail_width := min(ui.text_width(&detail_text, detail), max(0, (right - label_x) * 0.5))
			if result := ui.draw_fading_text(
				&w.ui_text,
				&w.list,
				label,
				label_x,
				baseline,
				app.theme.text,
				max(0, right - label_x - detail_width - ui.SPACE_2 * s),
			); result != .Ok {return result}
			if result := ui.draw_fading_text(
				&detail_text,
				&w.list,
				detail,
				right - detail_width,
				baseline,
				app.theme.muted,
				detail_width,
			); result != .Ok {return result}
			// Rows are a reading surface: they take the pointer light but never the lift. The
			// selected row keeps its tint, so it takes no paper hairline.
			if render.rect_contains(row, w.pointer.x, w.pointer.y) {
				if result := ui.hover_rim_draw(
					&w.list,
					app.theme,
					row,
					ui.RADIUS_CONTROL * s,
					1,
					s,
					w.pointer,
					i != p.selected,
				); result != .None {return .Ok}
			}
		}
	}
	if render.push_layer(&w.list, r, ui.RADIUS_OVERLAY * s) != .None {return .Ok}
	if result := workspace_row_rename_draw(app, w); result != .Ok { return result }
	return workspace_row_menu_draw(app, w)
}

// Workspace button pointer surface

@(private)
workspace_button_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	return y >= 0 && y < window_title_height(w) && x >= title_actions_end(w) &&
		x < workspace_button_width(w)
}

@(private)
workspace_button_hover :: proc(
	app: ^App,
	w: ^Window,
	owner: Pointer_Target,
	e: input.Mouse_Move_Event,
) {
	if owner == .Workspace_Button {pointer_set(app, w, chrome_pointer(app, w, f32(e.x), f32(e.y)))}
}

@(private)
workspace_button_tooltip :: proc(_: ^App, _: ^Window, _, _: f32) -> string {return "Workspaces"}

@(private)
workspace_button_press :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) {
	if e.button == .Left {workspace_picker_chip_press(app, w, e.time_ns)}
}

@(private)
workspace_button_leave :: proc(_: ^App, w: ^Window) {
	w.workspace_hovered = false
}

// Every move that reaches the window updates the button's hover, which drives its motion; a drag or a
// modal surface does not hide it.
workspace_button_track :: proc(w: ^Window, x, y: f32) {
	if hovered := render.rect_contains(workspace_button_rect(w), x, y); hovered != w.workspace_hovered {
		w.workspace_hovered, w.dirty = hovered, true
	}
}
