package main

import "aio:glyphs"
import "aio:platform"
import "aio:render"
import "aio:term"
import "aio:ui"
import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import "core:time"

// The three program status overviews: a title-bar pill that opens the inbox, a docked activity
// panel, and a full-window board. They list the same items; only grouping and order differ.

@(private)
STATUS_PILL_WIDTH :: f32(52)
@(private)
STATUS_ROW_HEIGHT :: f32(46)
@(private)
STATUS_GROUP_HEIGHT :: f32(24)
@(private)
STATUS_INBOX_WIDTH :: f32(420)
@(private)
STATUS_PANEL_WIDTH :: f32(300)
@(private)
STATUS_CARD_HEIGHT :: f32(74)
@(private)
STATUS_HEADER_HEIGHT :: f32(36)

Status_Surface :: enum {
	None,
	Inbox,
	Panel,
	Board,
}

Status_Overview :: struct {
	panel_width: f32,
	panel_side_armed: ui.Armed(bool),
	panel_side_hover: bool,
	inbox_open, board_open: bool,
	// Keyboard selection in the inbox, and the item under the pointer on any surface.
	selected:               int,
	hover:                  int,
	hover_surface:          Status_Surface,
	pill_hover:             bool,
	inbox_scroll:           f32,
	panel_scroll:           f32,
}

// One row in an overview. A group row names the pane the rows below it came from. The record's
// strings borrow from the session's snapshot, so items live for one frame or event at most.
Status_Item :: struct {
	session: u32,
	record:  term.Program_Status,
	crumb:   string,
	group:   bool,
}

@(private)
status_crumb_at :: proc(workspace: ^Workspace, tab: int, entry: ^Session_Entry) -> string {
	title := status_tab_title(workspace, tab)
	if tab_pane_count(workspace.tabs[tab]) > 1 {
		return fmt.tprintf("%s › %s › %s", workspace.name, title, status_pane_title(entry))
	}
	return fmt.tprintf("%s › %s", workspace.name, title)
}

@(private)
status_item_less :: proc(a, b: Status_Item) -> bool {
	return status_before(a.record, b.record)
}

@(private)
status_record_id_less :: proc(a, b: term.Program_Status) -> bool {
	return a.id < b.id
}

// Every shown record in the window's scope, by urgency, or by place with a group row per pane.
status_items :: proc(app: ^App, w: ^Window, by_location: bool) -> []Status_Item {
	items := make([dynamic]Status_Item, context.temp_allocator)
	if !app.settings.status.enabled {return items[:]}
	for workspace in app.workspaces {
		if !workspace_eligible(app, workspace) || !status_in_scope(app, w, workspace) {continue}
		walk := workspace_session_panes(app, workspace)
		for pane, ok := workspace_pane_next(&walk); ok; pane, ok = workspace_pane_next(&walk) {
			entry := pane.session
			if entry == nil || len(entry.statuses) == 0 {continue}
			records := slice.clone(entry.statuses, context.temp_allocator)
			slice.sort_by(records, status_record_id_less)
			crumb := ""
			for record in records {
				if !status_shown(app, record) {continue}
				if crumb == "" {
					crumb = status_crumb_at(workspace, pane.tab, entry)
					if by_location {append(&items, Status_Item{session = entry.id, crumb = crumb, group = true})}
				}
				append(&items, Status_Item{session = entry.id, record = record, crumb = crumb})
			}
		}
	}
	if !by_location {slice.sort_by(items[:], status_item_less)}
	return items[:]
}

@(private)
status_age :: proc(at: time.Time) -> string {
	seconds := int(time.duration_seconds(time.since(at)))
	switch {
	case seconds < 60:
		return fmt.tprintf("%ds", max(0, seconds))
	case seconds < 3600:
		return fmt.tprintf("%dm", seconds / 60)
	case seconds < 86400:
		return fmt.tprintf("%dh", seconds / 3600)
	}
	return fmt.tprintf("%dd", seconds / 86400)
}

@(private)
status_item_name :: proc(app: ^App, item: Status_Item) -> string {
	if entry := session_find(app, item.session); entry != nil {return status_record_name(entry, item.record)}
	return item.record.app
}

@(private)
status_finished_seen :: proc(record: term.Program_Status) -> bool {
	return record.seen && (record.state == .Done || record.state == .Error)
}

@(private)
status_dismissable :: proc(record: term.Program_Status) -> bool {
	return record.state == .Done || record.state == .Error
}

@(private)
status_dismiss_rect :: proc(w: ^Window, row: render.Rect) -> render.Rect {
	s := w.scale
	return {row.x + row.width - 28 * s, row.y + (row.height - 22 * s) / 2, 22 * s, 22 * s}
}

// Two lines: name, state and age; then the message, with where it came from when `crumb` is set.
@(private)
status_row_draw :: proc(
	app: ^App,
	w: ^Window,
	r: render.Rect,
	item: Status_Item,
	highlighted, crumb: bool,
	indent: f32,
) -> glyphs.Result {
	s := w.scale
	if highlighted {ui.draw_rect(&w.list, {rect = r, color = app.theme.selection, radius = 6 * s})}
	mark := status_mark(item.record)
	left := r.x + 8 * s + indent
	if result := status_mark_draw(app, w, {left, r.y + 8 * s, 14 * s, 14 * s}, mark); result != .Ok {
		return result
	}
	strong := ui.text_styled(&w.ui_text, .Strong)
	small := ui.text_styled(&w.ui_text, .Small)
	quiet := status_finished_seen(item.record)
	text_x := left + 22 * s
	show_dismiss := highlighted && status_dismissable(item.record)
	right := r.x + r.width - (show_dismiss ? 34 : 8) * s
	age := status_age(item.record.updated_at)
	age_width := ui.text_width(&small, age)
	line_one := r.y + 6 * s + strong.ascent
	if !show_dismiss {
		if result := ui.draw_text(&small, &w.list, age, right - age_width, line_one, app.theme.faint);
		   result != .Ok {return result}
	}
	name := status_item_name(app, item)
	name_room := max(0, right - age_width - 8 * s - text_x)
	name_width := min(ui.text_width(&strong, name), name_room * 0.6)
	if result := ui.draw_fading_text(
		&strong,
		&w.list,
		name,
		text_x,
		line_one,
		quiet ? app.theme.muted : app.theme.text,
		name_width,
	); result != .Ok {return result}
	buffer: [8]u8
	headline := ui.status_headline(mark, buffer[:])
	headline_color := app.theme.muted
	if ui.status_blocked(mark.glyph) || mark.glyph == .Error {
		headline_color = ui.status_color(app.theme, mark.glyph)
	}
	if result := ui.draw_fading_text(
		&small,
		&w.list,
		headline,
		text_x + name_width + 6 * s,
		line_one,
		headline_color,
		max(0, name_room - name_width - 6 * s),
	); result != .Ok {return result}
	detail := item.record.message
	if crumb {detail = detail == "" ? item.crumb : fmt.tprintf("%s · %s", item.crumb, detail)}
	if detail != "" {
		if result := ui.draw_fading_text(
			&small,
			&w.list,
			detail,
			text_x,
			r.y + 25 * s + small.ascent,
			app.theme.faint,
			max(0, right - text_x),
		); result != .Ok {return result}
	}
	ui.status_progress_draw(
		&w.list,
		app.theme,
		{text_x, r.y, max(0, right - text_x), r.height - 2 * s},
		mark,
		s,
	)
	if show_dismiss {
		close := status_dismiss_rect(w, r)
		large := w.ui_text
		ui.text_set_size(&large, w.ui_text.size_px * 1.35)
		if result := ui.draw_glyph_centered(&large, &w.list, '×', close, app.theme.muted); result != .Ok {
			return result
		}
	}
	return .Ok
}

@(private)
status_group_draw :: proc(app: ^App, w: ^Window, r: render.Rect, item: Status_Item) -> glyphs.Result {
	small := ui.text_styled(&w.ui_text, .Small)
	return ui.draw_fading_text(
		&small,
		&w.list,
		item.crumb,
		r.x + 8 * w.scale,
		r.y + r.height - 6 * w.scale - small.line_height + small.ascent,
		app.theme.faint,
		max(0, r.width - 16 * w.scale),
	)
}

@(private)
status_item_height :: proc(w: ^Window, item: Status_Item) -> f32 {
	return (item.group ? STATUS_GROUP_HEIGHT : STATUS_ROW_HEIGHT) * w.scale
}

@(private)
status_dismiss_item :: proc(app: ^App, item: Status_Item) {
	if entry := session_find(app, item.session); entry != nil {
		term.program_status_dismiss(entry.session, item.record.id)
	}
}

@(private)
status_open_item :: proc(app: ^App, w: ^Window, item: Status_Item) {
	w.status.inbox_open, w.status.board_open = false, false
	w.dirty = true
	if !status_reveal(app, w, item.session) {notify(app, .Error, "Could not show that pane.")}
}


status_pill_width :: proc(app: ^App, w: ^Window) -> f32 {
	s := &app.settings.status
	return s.enabled && s.inbox ? STATUS_PILL_WIDTH * w.scale : 0
}

status_pill_rect :: proc(app: ^App, w: ^Window) -> render.Rect {
	width := status_pill_width(app, w)
	if width == 0 {return {}}
	return {workspace_button_width(w) + 2 * w.scale, 6 * w.scale, width - 6 * w.scale, 28 * w.scale}
}

@(private)
status_rect_contains :: proc(r: render.Rect, x, y: f32) -> bool {
	return r.width > 0 && x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height
}

status_pill_draw :: proc(app: ^App, w: ^Window) -> glyphs.Result {
	r := status_pill_rect(app, w)
	if r.width <= 0 {return .Ok}
	s := w.scale
	if render.push_layer(&w.list, {0, 0, f32(w.width), ui.TITLE_BAR_HEIGHT * s}) != .None {return .Ok}
	if w.status.inbox_open {
		ui.draw_rect(&w.list, {rect = r, color = app.theme.selection, radius = 6 * s})
	} else if w.status.pill_hover {
		ui.draw_rect(&w.list, {rect = r, color = app.theme.hover, radius = 6 * s})
	}
	summary: Status_Summary
	for workspace in app.workspaces {
		if !workspace_eligible(app, workspace) || !status_in_scope(app, w, workspace) {continue}
		walk := workspace_session_panes(app, workspace)
		for pane, ok := workspace_pane_next(&walk); ok; pane, ok = workspace_pane_next(&walk) {
			status_summary_add(app, &summary, pane.session)
		}
	}
	mark, shown := status_indicator(summary)
	if !shown {mark = {glyph = .Idle, progress = -1}}
	count := status_needs(summary)
	if count == 0 {count = summary.working}
	glyph_x := count > 0 ? r.x + 8 * s : r.x + (r.width - 14 * s) / 2
	if result := status_mark_draw(app, w, {glyph_x, r.y + 7 * s, 14 * s, 14 * s}, mark); result != .Ok {
		return result
	}
	if count > 0 {
		label := fmt.tprintf("%d", count)
		strong := ui.text_styled(&w.ui_text, .Strong)
		ink := status_needs(summary) > 0 ? ui.status_color(app.theme, mark.glyph) : app.theme.muted
		if result := ui.draw_text(
			&strong,
			&w.list,
			label,
			r.x + 28 * s,
			r.y + (r.height - strong.line_height) / 2 + strong.ascent,
			ink,
		); result != .Ok {return result}
	}
	if w.status.pill_hover && !w.status.inbox_open {
		if ui.hover_rim_draw(&w.list, app.theme, r, 6 * s, 1, s, w.pointer) != .None {return .Ok}
	}
	return .Ok
}

status_inbox_toggle :: proc(app: ^App, w: ^Window) {
	if w.status.inbox_open {
		w.status.inbox_open, w.dirty = false, true
		return
	}
	if !app.settings.status.enabled {
		notify(app, .Info, "Program status is off. Turn on status.enabled to use the inbox.")
		return
	}
	if !gesture_cancel(app, w) {return}
	window_overlays_cancel(app, w)
	w.status.board_open = false
	w.status.inbox_open = true
	w.status.selected, w.status.hover, w.status.inbox_scroll = 0, -1, 0
	w.dirty = true
}

@(private)
status_inbox_layout :: proc(
	app: ^App,
	w: ^Window,
	items: []Status_Item,
) -> (
	surface, list: render.Rect,
	footer_y: f32,
) {
	s := w.scale
	width := min(STATUS_INBOX_WIDTH * s, f32(w.width) - 16 * s)
	anchor := status_pill_rect(app, w)
	if anchor.width == 0 {anchor = workspace_button_rect(w)}
	x := clamp(anchor.x, 8 * s, max(8 * s, f32(w.width) - width - 8 * s))
	y := ui.TITLE_BAR_HEIGHT * s + 2 * s
	content := f32(max(1, len(items))) * STATUS_ROW_HEIGHT * s
	room := max(STATUS_ROW_HEIGHT * s, f32(w.height) - y - 8 * s - 2 * STATUS_HEADER_HEIGHT * s)
	height := min(content, room)
	surface = {x, y, width, STATUS_HEADER_HEIGHT * s + height + 30 * s}
	list = {x + 4 * s, y + STATUS_HEADER_HEIGHT * s, width - 8 * s, height}
	return surface, list, list.y + list.height
}

@(private)
status_dismiss_all_rect :: proc(w: ^Window, surface: render.Rect) -> render.Rect {
	s := w.scale
	return {surface.x + surface.width - 130 * s, surface.y + 6 * s, 122 * s, 24 * s}
}

@(private)
status_inbox_row_rect :: proc(w: ^Window, list: render.Rect, scroll: f32, index: int) -> render.Rect {
	height := STATUS_ROW_HEIGHT * w.scale
	return {list.x, list.y + f32(index) * height - scroll, list.width, height}
}

@(private)
status_inbox_clamp :: proc(w: ^Window, list: render.Rect, count: int) {
	height := STATUS_ROW_HEIGHT * w.scale
	limit := max(0, f32(count) * height - list.height)
	w.status.selected = clamp(w.status.selected, 0, max(0, count - 1))
	top := f32(w.status.selected) * height
	if top < w.status.inbox_scroll {w.status.inbox_scroll = top}
	if top + height > w.status.inbox_scroll + list.height {w.status.inbox_scroll = top + height - list.height}
	w.status.inbox_scroll = clamp(w.status.inbox_scroll, 0, limit)
}

status_inbox_draw :: proc(app: ^App, w: ^Window) -> glyphs.Result {
	if !w.status.inbox_open {return .Ok}
	items := status_items(app, w, false)
	surface, list, footer_y := status_inbox_layout(app, w, items)
	s := w.scale
	if render.push_layer(&w.list, {0, 0, f32(w.width), f32(w.height)}) != .None {return .Ok}
	frame := ui.Panel {
		rect     = surface,
		radius   = 10 * s,
		scale    = s,
		shadow_y = 5,
		softness = 16,
		border   = .Stroked,
	}
	if ui.panel_draw(&w.list, frame, app.theme) != .None {return .Ok}
	if render.push_layer(&w.list, surface, 10 * s) != .None {return .Ok}
	strong := ui.text_styled(&w.ui_text, .Strong)
	small := ui.text_styled(&w.ui_text, .Small)
	scope := app.settings.status.scope == .All ? "All workspaces" : "This workspace"
	if result := ui.draw_text(
		&strong,
		&w.list,
		"Program status",
		surface.x + 12 * s,
		surface.y + (STATUS_HEADER_HEIGHT * s - strong.line_height) / 2 + strong.ascent,
		app.theme.text,
	); result != .Ok {return result}
	if result := ui.draw_text(
		&small,
		&w.list,
		scope,
		surface.x + 12 * s + ui.text_width(&strong, "Program status") + 8 * s,
		surface.y + (STATUS_HEADER_HEIGHT * s - small.line_height) / 2 + small.ascent,
		app.theme.faint,
	); result != .Ok {return result}
	dismiss := status_dismiss_all_rect(w, surface)
	label := "Dismiss finished"
	if result := ui.draw_text(
		&small,
		&w.list,
		label,
		dismiss.x + dismiss.width - ui.text_width(&small, label),
		dismiss.y + (dismiss.height - small.line_height) / 2 + small.ascent,
		app.theme.accent,
	); result != .Ok {return result}
	if render.push_layer(&w.list, list) != .None {return .Ok}
	if len(items) == 0 {
		if result := ui.draw_text(
			&small,
			&w.list,
			"Nothing is reporting status.",
			list.x + 8 * s,
			list.y + (list.height - small.line_height) / 2 + small.ascent,
			app.theme.faint,
		); result != .Ok {return result}
	}
	status_inbox_clamp(w, list, len(items))
	for item, i in items {
		r := status_inbox_row_rect(w, list, w.status.inbox_scroll, i)
		if r.y + r.height < list.y || r.y > list.y + list.height {continue}
		highlighted := i == w.status.selected
		if result := status_row_draw(app, w, r, item, highlighted, true, 0); result != .Ok {return result}
	}
	if render.push_layer(&w.list, surface, 10 * s) != .None {return .Ok}
	ui.draw_rect(&w.list, {rect = {surface.x, footer_y, surface.width, s}, color = app.theme.border})
	hint := "Ctrl+Shift+J next that needs you · Enter go to pane · Delete dismiss"
	return ui.draw_fading_text(
		&small,
		&w.list,
		hint,
		surface.x + 12 * s,
		footer_y + (30 * s - small.line_height) / 2 + small.ascent,
		app.theme.faint,
		max(0, surface.width - 24 * s),
	)
}

@(private)
status_inbox_hit :: proc(app: ^App, w: ^Window, items: []Status_Item, x, y: f32) -> int {
	_, list, _ := status_inbox_layout(app, w, items)
	if !status_rect_contains(list, x, y) {return -1}
	index := int(math.floor((y - list.y + w.status.inbox_scroll) / (STATUS_ROW_HEIGHT * w.scale)))
	return index >= 0 && index < len(items) ? index : -1
}

status_inbox_button :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) {
	if !e.pressed {return}
	w.header_buttons += {e.button}
	x, y := f32(e.x), f32(e.y)
	items := status_items(app, w, false)
	surface, _, _ := status_inbox_layout(app, w, items)
	w.dirty = true
	if !status_rect_contains(surface, x, y) {
		w.status.inbox_open = false
		return
	}
	if e.button != .Left {return}
	if status_rect_contains(status_dismiss_all_rect(w, surface), x, y) {
		status_dismiss_finished(app, w)
		return
	}
	index := status_inbox_hit(app, w, items, x, y)
	if index < 0 {return}
	_, list, _ := status_inbox_layout(app, w, items)
	row := status_inbox_row_rect(w, list, w.status.inbox_scroll, index)
	if status_dismissable(items[index].record) && status_rect_contains(status_dismiss_rect(w, row), x, y) {
		status_dismiss_item(app, items[index])
		return
	}
	status_open_item(app, w, items[index])
}

status_inbox_move :: proc(app: ^App, w: ^Window, x, y: f32) {
	items := status_items(app, w, false)
	if index := status_inbox_hit(app, w, items, x, y); index >= 0 && index != w.status.selected {
		w.status.selected, w.dirty = index, true
	}
	pointer_set(app, w, .Arrow)
}

status_inbox_wheel :: proc(app: ^App, w: ^Window, delta: f32) {
	w.status.inbox_scroll -= f32(math.sign(delta)) * 3 * STATUS_ROW_HEIGHT * w.scale
	items := status_items(app, w, false)
	_, list, _ := status_inbox_layout(app, w, items)
	height := STATUS_ROW_HEIGHT * w.scale
	w.status.inbox_scroll = clamp(w.status.inbox_scroll, 0, max(0, f32(len(items)) * height - list.height))
	first := int(math.ceil(w.status.inbox_scroll / height))
	last := int(math.floor((w.status.inbox_scroll + list.height) / height)) - 1
	w.status.selected = clamp(w.status.selected, first, max(first, last))
	w.dirty = true
}

status_inbox_key :: proc(app: ^App, w: ^Window, e: platform.Key_Event) {
	if !e.pressed {return}
	items := status_items(app, w, false)
	if step := ui.list_step(e); step != 0 {
		w.status.selected = clamp(w.status.selected + step, 0, max(0, len(items) - 1))
		w.dirty = true
		return
	}
	#partial switch e.key {
	case .Escape:
		w.status.inbox_open, w.dirty = false, true
	case .Enter, .Numpad_Enter:
		if w.status.selected >= 0 && w.status.selected < len(items) {
			status_open_item(app, w, items[w.status.selected])
		}
	case .Delete:
		if w.status.selected >= 0 && w.status.selected < len(items) {
			status_dismiss_item(app, items[w.status.selected])
		}
	case .J:
		if .Control in e.modifiers && .Shift in e.modifiers {
			w.status.inbox_open = false
			status_next_attention(app, w)
		}
	}
}


status_panel_visible :: proc(app: ^App, w: ^Window) -> bool {
	s := &app.settings.status
	if !s.enabled || !s.panel || w.preparing {return false}
	return true
}

status_panel_dock_width :: proc(app: ^App, w: ^Window) -> f32 {
	if !status_panel_visible(app, w) {return 0}
	width := w.status.panel_width > 0 ? w.status.panel_width : STATUS_PANEL_WIDTH
	available := f32(w.width) - (rail_docked(w) ? rail_width_pixels(w) : 0)
	return ui.rail_pixel_width(w.scale, width, available)
}

status_panel_rect :: proc(app: ^App, w: ^Window) -> render.Rect {
	if !status_panel_visible(app, w) {return {}}
	content := window_content_area(app, w)
	gap := window_gap(app, w)
	width := status_panel_dock_width(app, w) - gap
	if app.settings.status.panel_side == .Left {
		return {gap, content.y, max(0, width), content.height}
	}
	return {content.x + content.width + gap, content.y, max(0, width), content.height}
}

status_panel_side_rect :: proc(app: ^App, w: ^Window) -> render.Rect {
	r := status_panel_rect(app, w)
	if r.width <= 0 {return {}}
	return {r.x + r.width - 28 * w.scale, r.y + 3 * w.scale, 24 * w.scale, 24 * w.scale}
}

status_panel_side_toggle :: proc(app: ^App) {
	next := app.settings.status.panel_side == .Right ? "left" : "right"
	if _, has_file := settings_save_value(app, "status.panel_side", next, "Could not save Activity side.");
	   !has_file {
		app.settings.status.panel_side = next == "left" ? .Left : .Right
		for window in app.windows {window_relayout(app, window)}
	}
}

@(private)
status_panel_list :: proc(app: ^App, w: ^Window, panel: render.Rect) -> render.Rect {
	s := w.scale
	return {panel.x + 4 * s, panel.y + 30 * s, max(0, panel.width - 8 * s), max(0, panel.height - 34 * s)}
}

@(private)
status_panel_offsets :: proc(w: ^Window, items: []Status_Item) -> (offsets: []f32, total: f32) {
	offsets = make([]f32, len(items), context.temp_allocator)
	for item, i in items {
		offsets[i] = total
		total += status_item_height(w, item)
	}
	return offsets, total
}

status_panel_draw :: proc(app: ^App, w: ^Window) -> glyphs.Result {
	panel := status_panel_rect(app, w)
	if panel.width <= 0 || panel.height <= 0 {return .Ok}
	s := w.scale
	if render.push_layer(&w.list, panel) != .None {return .Ok}
	{
		radius := f32(app.settings.pane.corner_radius) * s
		ui.draw_rect(&w.list, {rect = panel, color = app.theme.pane, radius = radius})
		ui.draw_rect(&w.list, {rect = panel, color = app.theme.pane_border, radius = radius, stroke = max(1, s)})
	}
	items := status_items(app, w, true)
	small := ui.text_styled(&w.ui_text, .Small)
	title := "ACTIVITY"
	if result := ui.draw_text(
		&small,
		&w.list,
		title,
		panel.x + 12 * s,
		panel.y + 9 * s + small.ascent,
		app.theme.faint,
	); result != .Ok {return result}
	button := status_panel_side_rect(app, w)
	hover := status_rect_contains(button, w.pointer.x, w.pointer.y)
	if hover {ui.draw_rect(&w.list, {rect = button, color = app.theme.pane_border, radius = 3 * s})}
	icon := render.Rect{button.x + 5 * s, button.y + 6 * s, 14 * s, 12 * s}
	ui.draw_rect(&w.list, {rect = icon, color = app.theme.faint, stroke = s})
	left := app.settings.status.panel_side == .Right
	stripe := render.Rect{left ? icon.x + 3 * s : icon.x + icon.width - 4 * s, icon.y, s, icon.height}
	ui.draw_rect(&w.list, {rect = stripe, color = app.theme.faint})
	list := status_panel_list(app, w, panel)
	if render.push_layer(&w.list, list) != .None {return .Ok}
	if len(items) == 0 {
		return ui.draw_fading_text(
			&small,
			&w.list,
			"Nothing is reporting status.",
			list.x + 8 * s,
			list.y + 8 * s + small.ascent,
			app.theme.faint,
			max(0, list.width - 16 * s),
		)
	}
	offsets, total := status_panel_offsets(w, items)
	w.status.panel_scroll = clamp(w.status.panel_scroll, 0, max(0, total - list.height))
	for item, i in items {
		top := list.y + offsets[i] - w.status.panel_scroll
		r := render.Rect{list.x, top, list.width, status_item_height(w, item)}
		if r.y + r.height < list.y || r.y > list.y + list.height {continue}
		if item.group {
			if result := status_group_draw(app, w, r, item); result != .Ok {return result}
			continue
		}
		depth := f32(min(3, strings.count(item.record.id, "/") + (item.record.id != "" ? 1 : 0)))
		highlighted := w.status.hover_surface == .Panel && w.status.hover == i
		if result := status_row_draw(app, w, r, item, highlighted, false, depth * 12 * s); result != .Ok {
			return result
		}
	}
	return .Ok
}

@(private)
status_panel_hit :: proc(
	app: ^App,
	w: ^Window,
	items: []Status_Item,
	x, y: f32,
) -> (
	index: int,
	row: render.Rect,
) {
	panel := status_panel_rect(app, w)
	list := status_panel_list(app, w, panel)
	if !status_rect_contains(list, x, y) {return -1, {}}
	offsets, _ := status_panel_offsets(w, items)
	for item, i in items {
		top := list.y + offsets[i] - w.status.panel_scroll
		r := render.Rect{list.x, top, list.width, status_item_height(w, item)}
		if !item.group && status_rect_contains(r, x, y) {return i, r}
	}
	return -1, {}
}

status_panel_contains :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	return status_rect_contains(status_panel_rect(app, w), x, y)
}

// Panel clicks open the pane a row came from; the panel takes every press inside it.
status_panel_button :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) -> bool {
	x, y := f32(e.x), f32(e.y)
	if !e.pressed || !status_panel_contains(app, w, x, y) {return false}
	w.header_buttons += {e.button}
	if e.button != .Left {return true}
	if status_rect_contains(status_panel_side_rect(app, w), x, y) {
		ui.armed_press(&w.status.panel_side_armed, true)
		return true
	}
	items := status_items(app, w, true)
	index, row := status_panel_hit(app, w, items, x, y)
	if index < 0 {return true}
	if status_dismissable(items[index].record) && status_rect_contains(status_dismiss_rect(w, row), x, y) {
		status_dismiss_item(app, items[index])
		w.dirty = true
		return true
	}
	status_open_item(app, w, items[index])
	return true
}

status_panel_wheel :: proc(app: ^App, w: ^Window, x, y, delta: f32) -> bool {
	if !status_panel_contains(app, w, x, y) {return false}
	step := f32(math.sign(delta)) * 2 * STATUS_ROW_HEIGHT * w.scale
	w.status.panel_scroll = max(0, w.status.panel_scroll - step)
	w.dirty = true
	return true
}


status_board_toggle :: proc(app: ^App, w: ^Window) {
	if w.status.board_open {
		w.status.board_open, w.dirty = false, true
		return
	}
	s := &app.settings.status
	if !s.enabled || !s.board {
		notify(app, .Info, "The program status board is off. Turn on status.enabled and status.board.")
		return
	}
	if !gesture_cancel(app, w) {return}
	window_overlays_cancel(app, w)
	w.status.inbox_open = false
	w.status.board_open, w.status.hover = true, -1
	w.dirty = true
}

@(private)
status_board_column :: proc(record: term.Program_Status) -> int {
	switch record.state {
	case .Blocked:
		return 0
	case .Error:
		return record.seen ? 2 : 0
	case .Working:
		return 1
	case .Done:
		return 2
	case .Idle:
		return 3
	}
	return 3
}

@(private)
STATUS_BOARD_TITLES :: [4]string{"Needs you", "Running", "Finished", "Idle"}

@(private)
status_board_area :: proc(w: ^Window) -> render.Rect {
	top := ui.TITLE_BAR_HEIGHT * w.scale
	return {0, top, f32(w.width), max(0, f32(w.height) - top)}
}

// Card rectangles parallel to `items`; a card that does not fit has zero width.
@(private)
status_board_cards :: proc(
	w: ^Window,
	items: []Status_Item,
) -> (
	cards: []render.Rect,
	hidden: [4]int,
	columns: [4]render.Rect,
) {
	s := w.scale
	area := status_board_area(w)
	pad := 16 * s
	gutter := 12 * s
	top := area.y + 52 * s
	width := max(0, (area.width - 2 * pad - 3 * gutter) / 4)
	for i in 0 ..< 4 {
		x := area.x + pad + f32(i) * (width + gutter)
		columns[i] = {x, top, width, max(0, area.y + area.height - pad - top)}
	}
	cards = make([]render.Rect, len(items), context.temp_allocator)
	next: [4]f32
	for item, i in items {
		column := status_board_column(item.record)
		c := columns[column]
		y := c.y + 28 * s + next[column]
		height := STATUS_CARD_HEIGHT * s
		if y + height > c.y + c.height - 20 * s {
			hidden[column] += 1
			continue
		}
		cards[i] = {c.x, y, c.width, height}
		next[column] += height + 8 * s
	}
	return cards, hidden, columns
}

status_board_draw :: proc(app: ^App, w: ^Window) -> glyphs.Result {
	if !w.status.board_open {return .Ok}
	s := w.scale
	area := status_board_area(w)
	if render.push_layer(&w.list, area) != .None {return .Ok}
	ui.draw_rect(&w.list, {rect = area, color = app.theme.window})
	items := status_items(app, w, false)
	cards, hidden, columns := status_board_cards(w, items)
	strong := ui.text_styled(&w.ui_text, .Strong)
	small := ui.text_styled(&w.ui_text, .Small)
	heading := "Program status"
	heading_y := area.y + 18 * s + strong.ascent
	if result := ui.draw_text(&strong, &w.list, heading, area.x + 16 * s, heading_y, app.theme.text);
	   result != .Ok {return result}
	scope := app.settings.status.scope == .All ? "All workspaces" : "This workspace"
	note := fmt.tprintf("%s · %d reporting · Esc or Ctrl+Shift+G closes", scope, len(items))
	if result := ui.draw_text(
		&small,
		&w.list,
		note,
		area.x + 24 * s + ui.text_width(&strong, heading),
		area.y + 18 * s + strong.ascent,
		app.theme.faint,
	); result != .Ok {return result}
	counts: [4]int
	for item in items {counts[status_board_column(item.record)] += 1}
	samples := [4]ui.Status_Mark {
		{glyph = .Blocked},
		{glyph = .Working, progress = 50},
		{glyph = .Done},
		{glyph = .Idle},
	}
	titles := STATUS_BOARD_TITLES
	for c, i in columns {
		if result := ui.status_glyph_draw(
			&w.list,
			&w.ui_text,
			app.theme,
			{c.x, c.y + 3 * s, 12 * s, 12 * s},
			samples[i],
			0,
			s,
		); result != .Ok {return result}
		label := fmt.tprintf("%s · %d", titles[i], counts[i])
		label_y := c.y + 2 * s + small.ascent
		if result := ui.draw_text(&small, &w.list, label, c.x + 18 * s, label_y, app.theme.muted);
		   result != .Ok {return result}
		if counts[i] == 0 {
			if result := ui.draw_text(&small, &w.list, "None", c.x, c.y + 34 * s + small.ascent, app.theme.faint);
			   result != .Ok {return result}
		}
		if hidden[i] > 0 {
			more := fmt.tprintf("+%d more", hidden[i])
			if result := ui.draw_text(
				&small,
				&w.list,
				more,
				c.x,
				c.y + c.height - 16 * s + small.ascent,
				app.theme.faint,
			); result != .Ok {return result}
		}
	}
	for item, i in items {
		r := cards[i]
		if r.width <= 0 {continue}
		mark := status_mark(item.record)
		edge := app.theme.border
		if ui.status_blocked(mark.glyph) || mark.glyph == .Error && !mark.dim {
			edge = ui.status_color(app.theme, mark.glyph)
			edge.a *= 0.6
		}
		if w.status.hover_surface == .Board && w.status.hover == i {edge = app.theme.pane_focus}
		ui.draw_rect(&w.list, {rect = r, color = app.theme.surface, radius = 8 * s})
		ui.draw_rect(&w.list, {rect = r, color = edge, radius = 8 * s, stroke = max(1, s)})
		inner := render.Rect{r.x + 2 * s, r.y + 2 * s, r.width - 4 * s, 46 * s}
		if result := status_row_draw(app, w, inner, item, false, false, 0); result != .Ok {return result}
		if result := ui.draw_fading_text(
			&small,
			&w.list,
			item.crumb,
			r.x + 32 * s,
			r.y + r.height - 10 * s - small.line_height + small.ascent,
			app.theme.faint,
			max(0, r.width - 40 * s),
		); result != .Ok {return result}
	}
	return .Ok
}

@(private)
status_board_hit :: proc(w: ^Window, items: []Status_Item, x, y: f32) -> int {
	cards, _, _ := status_board_cards(w, items)
	for r, i in cards {
		if status_rect_contains(r, x, y) {return i}
	}
	return -1
}

status_board_button :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) {
	if !e.pressed {return}
	w.header_buttons += {e.button}
	if e.button != .Left {return}
	items := status_items(app, w, false)
	if index := status_board_hit(w, items, f32(e.x), f32(e.y)); index >= 0 {
		status_open_item(app, w, items[index])
	}
}

status_board_key :: proc(app: ^App, w: ^Window, e: platform.Key_Event) -> bool {
	if !e.pressed || e.key != .Escape {return false}
	w.status.board_open, w.dirty = false, true
	return true
}

// Pointer hover for every overview surface; true when an overview took the pointer.
status_overview_move :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	side_hover := status_rect_contains(status_panel_side_rect(app, w), x, y)
	if side_hover != w.status.panel_side_hover {w.status.panel_side_hover, w.dirty = side_hover, true}
	pill := status_rect_contains(status_pill_rect(app, w), x, y)
	if pill != w.status.pill_hover {w.status.pill_hover, w.dirty = pill, true}
	surface := Status_Surface.None
	hover := -1
	if w.status.board_open && y >= ui.TITLE_BAR_HEIGHT * w.scale {
		surface = .Board
		hover = status_board_hit(w, status_items(app, w, false), x, y)
	} else if status_panel_contains(app, w, x, y) {
		if _, over := divider_cursor(w, x, y); over {return false}
		surface = .Panel
		hover, _ = status_panel_hit(app, w, status_items(app, w, true), x, y)
	}
	if surface != w.status.hover_surface || hover != w.status.hover {
		w.status.hover_surface, w.status.hover, w.dirty = surface, hover, true
	}
	if surface == .None {return false}
	pointer_set(app, w, .Arrow)
	return true
}

status_overview_cancel :: proc(w: ^Window) {
	if w.status.inbox_open || w.status.board_open {w.dirty = true}
	w.status.inbox_open, w.status.board_open = false, false
	w.status.hover_surface, w.status.hover, w.status.pill_hover = .None, -1, false
}
