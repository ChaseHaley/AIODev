package main

import "aio:commands"
import "aio:glyphs"
import "aio:platform"
import "aio:render"
import "aio:term"
import "aio:ui"
import "core:fmt"
import "core:math"
import "core:slice"
import "core:time"

// The inbox orders program status by urgency; the activity panel groups it by location.

@(private)
STATUS_PILL_WIDTH :: f32(52)
@(private)
STATUS_ROW_HEIGHT :: f32(48)
@(private)
STATUS_INBOX_WIDTH :: f32(420)
// In the rail the panel keeps its header and a row, and the tabs keep the footer and two rows.
@(private)
STATUS_PANEL_RAIL_MIN :: f32(80)
@(private)
STATUS_RAIL_TABS_MIN :: f32(96)
@(private)
STATUS_HEADER_HEIGHT :: f32(40)
// The inbox footer and the Activity panel's title band.
STATUS_FOOTER_HEIGHT :: ui.HEIGHT_STANDARD
STATUS_PANEL_HEADER :: ui.HEIGHT_STANDARD

// The inbox while it is open. The pointer moves its keyboard selection, so it keeps no hover.
Status_Inbox :: struct {
	selected: int,
	scroll:   f32,
}

Status_Panel_Button :: enum {
	None,
	Side,
	View,
}

Status_Overview :: struct {
	// A dragged width in DIPs and in-rail height as a share of the rail; zero follows the settings.
	panel_width, panel_height: f32,
	panel_button_armed: ui.Armed(Status_Panel_Button),
	panel_button_hover: Status_Panel_Button,
	inbox:              Maybe(Status_Inbox),
	// The Activity panel row under the pointer.
	panel_hover:        Maybe(int),
	pill_hover:         bool,
	panel_scroll:       f32,
}

// One report in an overview. The record's strings borrow from the session's snapshot, so items live
// for one frame or event at most.
Status_Item :: struct {
	session:   u32,
	record:    term.Program_Status,
	crumb:     string,
	workspace: string,
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

// Every shown record in the window's scope, by urgency.
status_items :: proc(app: ^App, w: ^Window) -> []Status_Item {
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
				if crumb == "" {crumb = status_crumb_at(workspace, pane.tab, entry)}
				append(&items, Status_Item{entry.id, record, crumb, workspace.name})
			}
		}
	}
	slice.sort_by(items[:], status_item_less)
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
status_dismiss_rect :: proc(w: ^Window, row: render.Rect) -> render.Rect {
	s := w.scale
	size := ui.HEIGHT_COMPACT * s
	return {row.x + row.width - ui.SPACE_1 * s - size, row.y + (row.height - size) / 2, size, size}
}

// Two lines: name, state and age; then where it came from and the message.
@(private)
status_row_draw :: proc(
	app: ^App,
	w: ^Window,
	r: render.Rect,
	item: Status_Item,
	highlighted: bool,
) -> glyphs.Result {
	s := w.scale
	if highlighted {
		ui.draw_rect(&w.list, {rect = r, color = app.theme.selection, radius = ui.RADIUS_CONTROL * s})
	}
	mark := status_mark(item.record)
	left := r.x + ui.CONTROL_INSET * s
	strong := ui.text_styled(&w.ui_text, .Strong)
	small := ui.text_styled(&w.ui_text, .Detail)
	line_one, line_two := ui.stacked_baselines(r, &strong, &small, s)
	icon := ui.ICON_BUTTON * s
	icon_y := line_one - strong.ascent + (strong.line_height - icon) / 2
	if result := status_mark_draw(app, w, {left, icon_y, icon, icon}, mark); result != .Ok {
		return result
	}
	quiet := term.program_status_seen(item.record.state)
	text_x := left + icon + ui.SPACE_2 * s
	show_dismiss := highlighted && term.program_status_finished(item.record.state)
	right := r.x + r.width - (show_dismiss ? ui.SPACE_1 + ui.HEIGHT_COMPACT + ui.SPACE_1 : ui.CONTROL_INSET) * s
	age := status_age(item.record.updated_at)
	age_width := ui.text_width(&small, age)
	if !show_dismiss {
		if result := ui.draw_text(&small, &w.list, age, right - age_width, line_one, app.theme.faint);
		   result != .Ok {return result}
	}
	name := status_item_name(app, item)
	name_room := max(0, right - age_width - ui.SPACE_2 * s - text_x)
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
		text_x + name_width + ui.SPACE_2 * s,
		line_one,
		headline_color,
		max(0, name_room - name_width - ui.SPACE_2 * s),
	); result != .Ok {return result}
	detail := item.record.message == "" ? item.crumb : fmt.tprintf("%s · %s", item.crumb, item.record.message)
	if result := ui.draw_fading_text(
		&small,
		&w.list,
		detail,
		text_x,
		line_two,
		app.theme.faint,
		max(0, right - text_x),
	); result != .Ok {return result}
	ui.status_progress_draw(
		&w.list,
		app.theme,
		{text_x, r.y, max(0, right - text_x), r.height - 2 * s},
		mark,
		s,
	)
	if show_dismiss {
		close := status_dismiss_rect(w, r)
		ui.icon_draw(&w.list, .Close, close, app.theme.muted, ui.ICON_INDICATOR, s)
	}
	return .Ok
}

@(private)
status_dismiss_item :: proc(app: ^App, item: Status_Item) {
	if entry := session_find(app, item.session); entry != nil {
		term.program_status_dismiss(entry.session, item.record.id)
	}
}

@(private)
status_open_item :: proc(app: ^App, w: ^Window, item: Status_Item) {
	status_inbox_close(w)
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
	height := ui.HEIGHT_TOOLBAR * w.scale
	top := (ui.TITLE_BAR_HEIGHT * w.scale - height) / 2
	return {workspace_button_width(w), top, width - ui.SPACE_1 * w.scale, height}
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
	if status_inbox_shown(w) {
		ui.draw_rect(&w.list, {rect = r, color = app.theme.selection, radius = ui.RADIUS_CONTROL * s})
	} else if w.status.pill_hover {
		ui.draw_rect(&w.list, {rect = r, color = app.theme.hover, radius = ui.RADIUS_CONTROL * s})
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
	icon := ui.ICON_BUTTON * s
	glyph_x := count > 0 ? r.x + ui.CONTROL_INSET * s : r.x + (r.width - icon) / 2
	glyph := render.Rect{glyph_x, r.y + (r.height - icon) / 2, icon, icon}
	if result := status_mark_draw(app, w, glyph, mark); result != .Ok {
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
	if w.status.pill_hover && !status_inbox_shown(w) {
		radius := ui.RADIUS_CONTROL * s
		if ui.hover_rim_draw(&w.list, app.theme, r, radius, 1, s, w.pointer, compact = true) != .None {return .Ok}
	}
	return .Ok
}

status_inbox_shown :: proc(w: ^Window) -> bool {
	_, open := w.status.inbox.?
	return open
}

// Opening starts at the top with the first item selected; closing forgets both.
status_inbox_toggle :: proc(app: ^App, w: ^Window) {
	if status_inbox_shown(w) {
		status_inbox_close(w)
		return
	}
	if !app.settings.status.enabled {
		notify(app, .Info, "Program status is off. Turn on status.enabled to use the inbox.")
		return
	}
	if !gesture_cancel(app, w) {return}
	window_overlays_cancel(app, w)
	w.status.inbox = Status_Inbox{}
	w.dirty = true
}

status_inbox_close :: proc(w: ^Window) {
	if !status_inbox_shown(w) {return}
	w.status.inbox = nil
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
	y := (ui.TITLE_BAR_HEIGHT + ui.SPACE_1) * s
	content := f32(max(1, len(items))) * STATUS_ROW_HEIGHT * s
	room := max(STATUS_ROW_HEIGHT * s, f32(w.height) - y - 8 * s - 2 * STATUS_HEADER_HEIGHT * s)
	height := min(content, room)
	surface = {x, y, width, STATUS_HEADER_HEIGHT * s + height + STATUS_FOOTER_HEIGHT * s}
	pad := ui.OVERLAY_PADDING * s
	list = {x + pad, y + STATUS_HEADER_HEIGHT * s, width - 2 * pad, height}
	return surface, list, list.y + list.height
}

@(private)
status_dismiss_all_rect :: proc(w: ^Window, surface: render.Rect) -> render.Rect {
	s := w.scale
	size := ui.HEIGHT_COMPACT * s
	top := (STATUS_HEADER_HEIGHT * s - size) / 2
	return {surface.x + surface.width - ui.SPACE_2 * s - 120 * s, surface.y + top, 120 * s, size}
}

@(private)
status_inbox_row_rect :: proc(w: ^Window, list: render.Rect, scroll: f32, index: int) -> render.Rect {
	height := STATUS_ROW_HEIGHT * w.scale
	return {list.x, list.y + f32(index) * height - scroll, list.width, height}
}

@(private)
status_inbox_clamp :: proc(w: ^Window, inbox: ^Status_Inbox, list: render.Rect, count: int) {
	height := STATUS_ROW_HEIGHT * w.scale
	limit := max(0, f32(count) * height - list.height)
	inbox.selected = clamp(inbox.selected, 0, max(0, count - 1))
	top := f32(inbox.selected) * height
	if top < inbox.scroll {inbox.scroll = top}
	if top + height > inbox.scroll + list.height {inbox.scroll = top + height - list.height}
	inbox.scroll = clamp(inbox.scroll, 0, limit)
}

status_inbox_draw :: proc(app: ^App, w: ^Window) -> glyphs.Result {
	inbox, open := &w.status.inbox.?
	if !open {return .Ok}
	items := status_items(app, w)
	surface, list, footer_y := status_inbox_layout(app, w, items)
	s := w.scale
	if render.push_layer(&w.list, {0, 0, f32(w.width), f32(w.height)}) != .None {return .Ok}
	frame := ui.popover_panel(surface, s)
	if ui.panel_draw(&w.list, frame, app.theme) != .None {return .Ok}
	if render.push_layer(&w.list, surface, ui.RADIUS_OVERLAY * s) != .None {return .Ok}
	strong := ui.text_styled(&w.ui_text, .Strong)
	small := ui.text_styled(&w.ui_text, .Detail)
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
	status_inbox_clamp(w, inbox, list, len(items))
	for item, i in items {
		r := status_inbox_row_rect(w, list, inbox.scroll, i)
		if r.y + r.height < list.y || r.y > list.y + list.height {continue}
		highlighted := i == inbox.selected
		if result := status_row_draw(app, w, r, item, highlighted); result != .Ok {return result}
	}
	if render.push_layer(&w.list, surface, ui.RADIUS_OVERLAY * s) != .None {return .Ok}
	ui.draw_rect(&w.list, {rect = {surface.x, footer_y, surface.width, s}, color = app.theme.border})
	hint := "Enter go to pane · Delete dismiss"
	buffer: [commands.SHORTCUT_TEXT_CAP]u8
	if next := action_shortcut_text(app, .Status_Next, buffer[:]); next != "" {
		hint = fmt.tprintf("%s next that needs you · %s", next, hint)
	}
	return ui.draw_fading_text(
		&small,
		&w.list,
		hint,
		surface.x + 12 * s,
		footer_y + (STATUS_FOOTER_HEIGHT * s - small.line_height) / 2 + small.ascent,
		app.theme.faint,
		max(0, surface.width - 24 * s),
	)
}

@(private)
status_inbox_hit :: proc(app: ^App, w: ^Window, items: []Status_Item, scroll, x, y: f32) -> int {
	_, list, _ := status_inbox_layout(app, w, items)
	if !status_rect_contains(list, x, y) {return -1}
	index := int(math.floor((y - list.y + scroll) / (STATUS_ROW_HEIGHT * w.scale)))
	return index >= 0 && index < len(items) ? index : -1
}

status_inbox_button :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) {
	inbox, open := w.status.inbox.?
	if !e.pressed || !open {return}
	gesture_swallow(w, e.button, .Status_Inbox)
	x, y := f32(e.x), f32(e.y)
	items := status_items(app, w)
	surface, _, _ := status_inbox_layout(app, w, items)
	w.dirty = true
	if !status_rect_contains(surface, x, y) {
		status_inbox_close(w)
		return
	}
	if e.button != .Left {return}
	if status_rect_contains(status_dismiss_all_rect(w, surface), x, y) {
		status_dismiss_finished(app, w)
		return
	}
	index := status_inbox_hit(app, w, items, inbox.scroll, x, y)
	if index < 0 {return}
	_, list, _ := status_inbox_layout(app, w, items)
	row := status_inbox_row_rect(w, list, inbox.scroll, index)
	if term.program_status_finished(items[index].record.state) &&
	   status_rect_contains(status_dismiss_rect(w, row), x, y) {
		status_dismiss_item(app, items[index])
		return
	}
	status_open_item(app, w, items[index])
}

status_inbox_move :: proc(app: ^App, w: ^Window, x, y: f32) {
	inbox, open := &w.status.inbox.?
	if !open {return}
	items := status_items(app, w)
	index := status_inbox_hit(app, w, items, inbox.scroll, x, y)
	if index >= 0 && index != inbox.selected {
		inbox.selected, w.dirty = index, true
	}
	surface, _, _ := status_inbox_layout(app, w, items)
	dismiss_all := status_rect_contains(status_dismiss_all_rect(w, surface), x, y)
	pointer_set(app, w, index >= 0 || dismiss_all ? .Hand : .Arrow)
}

status_inbox_wheel :: proc(app: ^App, w: ^Window, delta: f32) {
	inbox, open := &w.status.inbox.?
	if !open {return}
	inbox.scroll -= f32(math.sign(delta)) * 3 * STATUS_ROW_HEIGHT * w.scale
	items := status_items(app, w)
	_, list, _ := status_inbox_layout(app, w, items)
	height := STATUS_ROW_HEIGHT * w.scale
	inbox.scroll = clamp(inbox.scroll, 0, max(0, f32(len(items)) * height - list.height))
	first := int(math.ceil(inbox.scroll / height))
	last := int(math.floor((inbox.scroll + list.height) / height)) - 1
	inbox.selected = clamp(inbox.selected, first, max(first, last))
	w.dirty = true
}

status_inbox_key :: proc(app: ^App, w: ^Window, e: platform.Key_Event) {
	inbox, open := &w.status.inbox.?
	if !e.pressed || !open {return}
	items := status_items(app, w)
	if step := ui.list_step(e); step != 0 {
		inbox.selected = clamp(inbox.selected + step, 0, max(0, len(items) - 1))
		w.dirty = true
		return
	}
	selected := inbox.selected >= 0 && inbox.selected < len(items)
	#partial switch e.key {
	case .Escape:
		status_inbox_close(w)
	case .Enter, .Numpad_Enter:
		if selected {status_open_item(app, w, items[inbox.selected])}
	case .Delete:
		if selected {status_dismiss_item(app, items[inbox.selected])}
	case .J:
		if .Control in e.modifiers && .Shift in e.modifiers {
			status_inbox_close(w)
			status_next_attention(app, w)
		}
	}
}


// Pointer hover for every overview surface; true when an overview took the pointer.
status_overview_move :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	button := status_panel_button_at(app, w, x, y)
	if button != w.status.panel_button_hover {w.status.panel_button_hover, w.dirty = button, true}
	pill := status_rect_contains(status_pill_rect(app, w), x, y)
	if pill != w.status.pill_hover {w.status.pill_hover, w.dirty = pill, true}
	over := status_panel_contains(app, w, x, y)
	hover: Maybe(int)
	if over {
		if _, on_divider := divider_cursor(w, x, y); on_divider {return false}
		rows, _ := status_panel_rows(app, w)
		if index, _ := status_panel_hit(app, w, rows, x, y); index >= 0 {hover = index}
	}
	status_panel_hover_set(w, hover)
	if !over {return false}
	_, on_row := hover.?
	pointer_set(app, w, on_row || button != .None ? .Hand : .Arrow)
	return true
}

// The pointer left the Activity panel for a surface above it.
status_overview_leave :: proc(w: ^Window) {
	status_panel_hover_set(w, nil)
	if w.status.panel_button_hover != .None {w.status.panel_button_hover, w.dirty = .None, true}
}

@(private = "file")
status_panel_hover_set :: proc(w: ^Window, hover: Maybe(int)) {
	if hover == w.status.panel_hover {return}
	w.status.panel_hover = hover
	w.dirty = true
}

status_overview_cancel :: proc(w: ^Window) {
	status_inbox_close(w)
	w.status.panel_hover, w.status.pill_hover = nil, false
}
