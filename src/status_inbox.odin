package main

import "aio:commands"
import "aio:input"
import "aio:render"
import "aio:term"
import "aio:ui"
import "core:fmt"
import "core:math"
import "core:slice"
import "core:time"

// The title-bar pill and the inbox it opens, which lists program status in the rows the Activity panel
// (status_panel.odin) shows, grouped, ordered and named the same way (status_rows.odin).

@(private)
STATUS_ROW_HEIGHT :: f32(48)
@(private)
STATUS_INBOX_WIDTH :: f32(420)
@(private)
STATUS_HEADER_HEIGHT :: f32(40)
STATUS_FOOTER_HEIGHT :: ui.HEIGHT_STANDARD
// Rows one wheel notch scrolls the inbox by.
@(private)
STATUS_INBOX_WHEEL_ROWS :: 3

// The inbox while it is open. The pointer moves its keyboard selection, so it keeps no hover. The
// selection is the index of a report row; -1 when there is none.
Status_Inbox :: struct {
	selected: int,
	scroll:   f32,
}

// A window's status overviews: the Activity panel, the open inbox and the pill's hover.
Status_Overview :: struct {
	using panel: Status_Panel,
	inbox:       Maybe(Status_Inbox),
	pill_hover:  bool,
}

@(private)
status_age :: proc(at, now: time.Time) -> string {
	seconds := int(time.duration_seconds(time.diff(at, now)))
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

// Rows the user has read go quiet, except blocked work, which still waits for them.
@(private)
status_item_quiet :: proc(item: Status_Item) -> bool {
	return item.record.read && item.record.state != .Blocked
}

// How long a record has held its state.
@(private)
status_state_age :: proc(app: ^App, record: term.Program_Status) -> string {
	return status_age(record.since, clock_wall(&app.clock))
}

// A row's receipt: two checks once read, one check when the last read came before the latest
// change, or a ring when the pane was never read; then how long ago, or "now" while it is in view.
@(private)
status_receipt :: proc(app: ^App, item: Status_Item) -> (icon: ui.Icon, text: string) {
	pane := item.pane
	switch {
	case item.record.read:
		icon = .Check_Double
	case pane.read_at == {} && !pane.watched:
		return .Circle, "never"
	case:
		icon = .Check
	}
	if pane.watched {return icon, "now"}
	return icon, status_age(pane.read_at, clock_wall(&app.clock))
}

// Whether reading or unreading a row means anything: a working row out of view is always unread.
@(private)
status_item_markable :: proc(item: Status_Item) -> bool {
	return item.record.state != .Working || item.pane.watched
}

// What a receipt means and what a click on it does.
@(private)
status_receipt_tooltip :: proc(app: ^App, item: Status_Item) -> string {
	_, ago := status_receipt(app, item)
	switch {
	case !status_item_markable(item) && item.pane.read_at == {}:
		return "Working · never read"
	case !status_item_markable(item):
		return fmt.tprintf("Working · new output since last read %s ago", ago)
	case item.record.read && item.pane.watched:
		return "Read now · click to mark unread"
	case item.record.read:
		return fmt.tprintf("Read %s ago · click to mark unread", ago)
	case item.pane.read_at == {} && !item.pane.watched:
		return "Never read · click to mark read"
	case item.pane.watched:
		return "Marked unread · click to mark read"
	}
	return fmt.tprintf("Not read since it changed, last read %s ago · click to mark read", ago)
}

// When the pane was last read, in words, for a row's tooltip.
@(private)
status_read_words :: proc(app: ^App, item: Status_Item) -> string {
	if item.pane.watched {return "read now"}
	if item.pane.read_at == {} {return "never read"}
	return fmt.tprintf("read %s ago", status_age(item.pane.read_at, clock_wall(&app.clock)))
}

// The receipt's place: its icon and time, ending at `right`, centred on `middle`.
@(private)
status_receipt_rect :: proc(app: ^App, w: ^Window, item: Status_Item, right, middle: f32) -> render.Rect {
	_, text := status_receipt(app, item)
	small := ui.text_styled(&w.ui_text, .Detail)
	width := (ui.ICON_INDICATOR + ui.SPACE_1) * w.scale + ui.text_width(&small, text)
	height := ui.ICON_BUTTON * w.scale
	return {right - width, math.round(middle - height / 2), width, height}
}

// Unread receipts take the accent, so a row that changed since the user looked stands out.
@(private)
status_receipt_draw :: proc(
	app: ^App,
	w: ^Window,
	item: Status_Item,
	area: render.Rect,
	baseline: f32,
) -> render.Build_Status {
	icon, text := status_receipt(app, item)
	ink := item.record.read ? app.theme.faint : app.theme.accent
	size := ui.ICON_INDICATOR * w.scale
	glyph := render.Rect{area.x, area.y + (area.height - size) / 2, size, size}
	ui.icon_draw(&w.list, icon, glyph, ink, ui.ICON_INDICATOR, w.scale)
	small := ui.text_styled(&w.ui_text, .Detail)
	return ui.draw_text(&small, &w.list, text, area.x + area.width - ui.text_width(&small, text), baseline, ink)
}

// Reads or unreads the pane a row came from, whichever the row is not.
@(private)
status_receipt_toggle :: proc(app: ^App, item: Status_Item) {
	if !status_item_markable(item) {return}
	status_mark(app, item.session, !item.record.read)
}

@(private)
status_dismiss_rect :: proc(w: ^Window, row: render.Rect) -> render.Rect {
	s := w.scale
	size := ui.HEIGHT_COMPACT * s
	return {row.x + row.width - ui.SPACE_1 * s - size, row.y + (row.height - size) / 2, size, size}
}

// Where an inbox row's text ends: before Dismiss while the highlighted row offers it.
@(private)
status_row_right :: proc(w: ^Window, r: render.Rect, item: Status_Item, highlighted: bool) -> f32 {
	dismiss := highlighted && term.program_status_finished(item.record.state)
	return r.x + r.width - (dismiss ? ui.SPACE_1 + ui.HEIGHT_COMPACT + ui.SPACE_1 : ui.CONTROL_INSET) * w.scale
}

@(private)
status_row_receipt_rect :: proc(
	app: ^App,
	w: ^Window,
	r: render.Rect,
	item: Status_Item,
	highlighted: bool,
) -> render.Rect {
	strong := ui.text_styled(&w.ui_text, .Strong)
	small := ui.text_styled(&w.ui_text, .Detail)
	_, line_two := ui.stacked_baselines(r, &strong, &small, w.scale)
	right := status_row_right(w, r, item, highlighted)
	return status_receipt_rect(app, w, item, right, line_two - small.ascent + small.line_height / 2)
}

// Two lines: name, state and how long it has held; then the row's terms and the receipt. Reports
// under another sit indented.
@(private)
status_row_draw :: proc(
	app: ^App,
	w: ^Window,
	r: render.Rect,
	row: Status_Row,
	highlighted: bool,
) -> render.Build_Status {
	s := w.scale
	item := row.item
	if highlighted {
		ui.draw_rect(&w.list, {rect = r, color = app.theme.selection, radius = ui.RADIUS_CONTROL * s})
	}
	quiet := status_item_quiet(item)
	mark := status_presentation(item.record).mark
	mark.dim = quiet
	indent := f32(min(row.depth, STATUS_PANEL_DEPTH_MAX)) * STATUS_PANEL_INDENT * s
	left := r.x + indent + ui.CONTROL_INSET * s
	strong := ui.text_styled(&w.ui_text, .Strong)
	small := ui.text_styled(&w.ui_text, .Detail)
	line_one, line_two := ui.stacked_baselines(r, &strong, &small, s)
	icon := ui.ICON_BUTTON * s
	icon_y := line_one - strong.ascent + (strong.line_height - icon) / 2
	if result := status_mark_draw(app, w, {left, icon_y, icon, icon}, mark); result != .Ok {
		return result
	}
	text_x := left + icon + ui.SPACE_2 * s
	show_dismiss := highlighted && term.program_status_finished(item.record.state)
	right := status_row_right(w, r, item, highlighted)
	age := status_state_age(app, item.record)
	age_width := ui.text_width(&small, age)
	if !show_dismiss {
		ink := quiet ? app.theme.faint : ui.status_color(app.theme, mark.glyph)
		if result := ui.draw_text(&small, &w.list, age, right - age_width, line_one, ink); result != .Ok {
			return result
		}
	}
	name := status_report_name(&app.settings.status, item, row.depth)
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
	headline := status_headline(mark, buffer[:])
	headline_color := mark.urgent && !quiet ? ui.status_color(app.theme, mark.glyph) : app.theme.muted
	if result := ui.draw_fading_text(
		&small,
		&w.list,
		headline,
		text_x + name_width + ui.SPACE_2 * s,
		line_one,
		headline_color,
		max(0, name_room - name_width - ui.SPACE_2 * s),
	); result != .Ok {return result}
	receipt := status_row_receipt_rect(app, w, r, item, highlighted)
	if result := status_receipt_draw(app, w, item, receipt, line_two); result != .Ok {return result}
	if result := ui.draw_fading_text(
		&small,
		&w.list,
		status_report_terms(&app.settings.status, item, name),
		text_x,
		line_two,
		app.theme.faint,
		max(0, receipt.x - ui.SPACE_2 * s - text_x),
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
	_ = session_show(app, w, item.session)
}

status_pill_width :: proc(app: ^App, w: ^Window) -> f32 {
	s := &app.settings.status
	return s.enabled && s.inbox ? ui.TITLE_BUTTON_WIDTH * w.scale : 0
}

// The inbox button is one more title button: the palette button's size, right after it.
status_pill_rect :: proc(app: ^App, w: ^Window) -> render.Rect {
	width := status_pill_width(app, w)
	if width == 0 {return {}}
	palette := title_action_rect(w, .Palette)
	return {palette.x + palette.width, palette.y, width, palette.height}
}

status_pill_hover_set :: proc(w: ^Window, hovered: bool) {
	if hovered == w.status.pill_hover {return}
	w.status.pill_hover, w.dirty = hovered, true
}

// The donut's ring, in DIPs. Idle draws the whole ring at the same width.
@(private)
STATUS_DONUT_RADIUS :: f32(6)
@(private)
STATUS_DONUT_WIDTH :: f32(2.5)
// The gap between two arcs, in radians.
@(private)
STATUS_DONUT_GAP :: f32(0.24)

// One arc of the donut: a pane's most urgent unseen report.
@(private)
Status_Donut_Arc :: struct {
	rank:  Status_Rank,
	glyph: ui.Status_Glyph,
}

// The inbox button draws a donut: one arc per pane with live status in its state's colour, most
// urgent first from the top, or a whole faint ring when nothing is going on.
status_pill_draw :: proc(app: ^App, w: ^Window) -> render.Build_Status {
	r := status_pill_rect(app, w)
	if r.width <= 0 {return .Ok}
	s := w.scale
	if render.push_layer(&w.list, {0, 0, f32(w.width), ui.TITLE_BAR_HEIGHT * s}) != .None {return .Ok}
	button := ui.Button {
		rect     = r,
		hover    = w.status.pill_hover ? 1 : 0,
		selected = status_inbox_shown(w),
	}
	face, _, err := ui.button_draw(&w.list, app.theme, button, s, w.pointer)
	if err != .None {return .Ok}
	arcs := make([dynamic]Status_Donut_Arc, context.temp_allocator)
	walk := status_scope_walk(app, w, eligible_only = true)
	for pane, _, ok := status_scope_next(&walk); ok; pane, _, ok = status_scope_next(&walk) {
		summary: Status_Summary
		status_summary_add(app, &summary, pane.session)
		mark, shown := status_indicator(summary)
		if !shown || mark.glyph == .Idle {continue}
		append(&arcs, Status_Donut_Arc{status_presentation(summary.top).rank, mark.glyph})
	}
	slice.sort_by(arcs[:], proc(a, b: Status_Donut_Arc) -> bool {return a.rank < b.rank})
	center := [2]f32{face.x + face.width / 2, face.y + face.height / 2}
	radius, width := STATUS_DONUT_RADIUS * s, STATUS_DONUT_WIDTH * s
	if len(arcs) == 0 {
		_ = render.push_arc(&w.list, center, radius, 0, 2 * math.PI, width, app.theme.faint)
		return .Ok
	}
	step := 2 * math.PI / f32(len(arcs))
	gap := len(arcs) > 1 ? min(STATUS_DONUT_GAP, step / 2) : 0
	for arc, i in arcs {
		start := -math.PI / 2 + f32(i) * step + gap / 2
		ink := ui.status_color(app.theme, arc.glyph)
		if render.push_arc(&w.list, center, radius, start, step - gap, width, ink) != .None {return .Ok}
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
	total: f32,
) -> (
	surface, list: render.Rect,
	footer_y: f32,
) {
	s := w.scale
	width := min(STATUS_INBOX_WIDTH * s, f32(w.width) - 16 * s)
	anchor := status_pill_rect(app, w)
	if anchor.width == 0 {anchor = workspace_button_rect(app, w)}
	x := clamp(anchor.x, 8 * s, max(8 * s, f32(w.width) - width - 8 * s))
	y := (ui.TITLE_BAR_HEIGHT + ui.SPACE_1) * s
	content := max(total, STATUS_ROW_HEIGHT * s)
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
status_inbox_row_rect :: proc(list: render.Rect, row: Status_Row, scroll: f32) -> render.Rect {
	return {list.x, list.y + row.y - scroll, list.width, row.height}
}

// The first report row from `index` on in `direction`, or -1.
@(private)
status_inbox_report :: proc(rows: []Status_Row, index, direction: int) -> int {
	for i := index; i >= 0 && i < len(rows); i += direction {
		if rows[i].report {return i}
	}
	return -1
}

// Keeps the selection on a report, the nearest one at or after it, else before it, and scrolls it into
// view with the label right above it.
@(private)
status_inbox_clamp :: proc(inbox: ^Status_Inbox, list: render.Rect, rows: []Status_Row, total: f32) {
	index := clamp(inbox.selected, 0, max(0, len(rows) - 1))
	selected := status_inbox_report(rows, index, 1)
	if selected < 0 {selected = status_inbox_report(rows, index, -1)}
	inbox.selected = selected
	if selected >= 0 {
		row := rows[selected]
		top := row.y
		if selected > 0 && !rows[selected - 1].report {top = rows[selected - 1].y}
		if top < inbox.scroll {inbox.scroll = top}
		if row.y + row.height > inbox.scroll + list.height {inbox.scroll = row.y + row.height - list.height}
	}
	inbox.scroll = clamp(inbox.scroll, 0, max(0, total - list.height))
}

// The open inbox as this frame or event lays it out. Rows borrow from session snapshots.
@(private)
Status_Inbox_View :: struct {
	rows:          []Status_Row,
	total:         f32,
	surface, list: render.Rect,
	footer_y:      f32,
}

// Projects the open inbox and keeps its selection and scroll within the projection, so drawing
// and every event see the same rows.
@(private)
status_inbox_view :: proc(app: ^App, w: ^Window, inbox: ^Status_Inbox) -> (view: Status_Inbox_View) {
	heights := Status_Row_Heights{STATUS_ROW_HEIGHT, STATUS_ROW_HEIGHT}
	group := app.settings.status.group_by
	view.rows, view.total = status_rows_project(group, status_reports(app, w), heights, w.scale)
	view.surface, view.list, view.footer_y = status_inbox_layout(app, w, view.total)
	status_inbox_clamp(inbox, view.list, view.rows, view.total)
	return
}

// The footer names the chord bound to status.next, if any.
@(private)
status_inbox_hint :: proc(app: ^App) -> string {
	actions :: "Enter go to pane · U read or unread · Delete dismiss"
	buffer: [commands.SHORTCUT_TEXT_CAP]u8
	chord := action_shortcut_text(app, .Status_Next, buffer[:])
	if chord == "" {return actions}
	return fmt.tprintf("%s next that needs you · %s", chord, actions)
}

status_inbox_draw :: proc(app: ^App, w: ^Window) -> render.Build_Status {
	inbox, open := &w.status.inbox.?
	if !open {return .Ok}
	view := status_inbox_view(app, w, inbox)
	rows, surface, list, footer_y := view.rows, view.surface, view.list, view.footer_y
	s := w.scale
	if !ui.popover_open(&w.list, surface, app.theme, f32(w.width), f32(w.height), s) {return .Ok}
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
	if len(rows) == 0 {
		if result := ui.draw_text(
			&small,
			&w.list,
			STATUS_EMPTY_TEXT,
			list.x + 8 * s,
			list.y + (list.height - small.line_height) / 2 + small.ascent,
			app.theme.faint,
		); result != .Ok {return result}
	}
	for row, i in rows {
		r := status_inbox_row_rect(list, row, inbox.scroll)
		if r.y + r.height < list.y || r.y > list.y + list.height {continue}
		result: render.Build_Status
		if row.report {
			result = status_row_draw(app, w, r, row, i == inbox.selected)
		} else {
			result = status_label_draw(app, w, r, row)
		}
		if result != .Ok {return result}
	}
	if render.push_layer(&w.list, surface, ui.RADIUS_OVERLAY * s) != .None {return .Ok}
	ui.draw_rect(&w.list, {rect = {surface.x, footer_y, surface.width, s}, color = app.theme.border})
	return ui.draw_fading_text(
		&small,
		&w.list,
		status_inbox_hint(app),
		surface.x + 12 * s,
		footer_y + (STATUS_FOOTER_HEIGHT * s - small.line_height) / 2 + small.ascent,
		app.theme.faint,
		max(0, surface.width - 24 * s),
	)
}

// The report row under the point, or -1.
@(private)
status_inbox_hit :: proc(view: Status_Inbox_View, scroll, x, y: f32) -> int {
	if !render.rect_contains(view.list, x, y) {return -1}
	for row, i in view.rows {
		if row.report && render.rect_contains(status_inbox_row_rect(view.list, row, scroll), x, y) {return i}
	}
	return -1
}

status_inbox_button :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) {
	inbox, open := &w.status.inbox.?
	if !e.pressed || !open {return}
	gesture_swallow(w, e.button, .Status_Inbox)
	x, y := f32(e.x), f32(e.y)
	view := status_inbox_view(app, w, inbox)
	w.dirty = true
	if !render.rect_contains(view.surface, x, y) {
		status_inbox_close(w)
		return
	}
	if e.button != .Left {return}
	if render.rect_contains(status_dismiss_all_rect(w, view.surface), x, y) {
		status_dismiss_finished(app, w)
		return
	}
	index := status_inbox_hit(view, inbox.scroll, x, y)
	if index < 0 {return}
	row := view.rows[index]
	r := status_inbox_row_rect(view.list, row, inbox.scroll)
	if term.program_status_finished(row.item.record.state) &&
	   render.rect_contains(status_dismiss_rect(w, r), x, y) {
		status_dismiss_item(app, row.item)
		return
	}
	if status_item_markable(row.item) &&
	   render.rect_contains(status_row_receipt_rect(app, w, r, row.item, index == inbox.selected), x, y) {
		status_receipt_toggle(app, row.item)
		return
	}
	status_open_item(app, w, row.item)
}

status_inbox_move :: proc(app: ^App, w: ^Window, x, y: f32) {
	inbox, open := &w.status.inbox.?
	if !open {return}
	view := status_inbox_view(app, w, inbox)
	index := status_inbox_hit(view, inbox.scroll, x, y)
	if index >= 0 && index != inbox.selected {
		inbox.selected, w.dirty = index, true
		status_inbox_clamp(inbox, view.list, view.rows, view.total)
	}
	dismiss_all := render.rect_contains(status_dismiss_all_rect(w, view.surface), x, y)
	pointer_set(app, w, index >= 0 || dismiss_all ? .Hand : .Arrow)
}

// Scrolls a fixed number of report rows per notch, then keeps the selection among the rows in view.
status_inbox_wheel :: proc(app: ^App, w: ^Window, delta: f32) {
	inbox, open := &w.status.inbox.?
	if !open {return}
	view := status_inbox_view(app, w, inbox)
	step := f32(math.sign(delta)) * STATUS_INBOX_WHEEL_ROWS * STATUS_ROW_HEIGHT * w.scale
	inbox.scroll = clamp(inbox.scroll - step, 0, max(0, view.total - view.list.height))
	if inbox.selected >= 0 {
		row := view.rows[inbox.selected]
		top, bottom := inbox.scroll, inbox.scroll + view.list.height
		if row.y < top || row.y + row.height > bottom {
			// The first report wholly in view, else the last one that is.
			first, last := -1, -1
			for candidate, i in view.rows {
				if !candidate.report || candidate.y < top || candidate.y + candidate.height > bottom {continue}
				if first < 0 {first = i}
				last = i
			}
			if first >= 0 {inbox.selected = row.y < top ? first : last}
		}
	}
	w.dirty = true
}

// The keys the open inbox keeps: list navigation, Enter, U, Delete, Escape and the chord bound to
// status.next. It reports whether it kept the key; every other key, and every release, goes on to the
// shortcuts and the focused pane.
status_inbox_key :: proc(app: ^App, w: ^Window, e, logical: input.Key_Event) -> bool {
	inbox, open := &w.status.inbox.?
	if !e.pressed || !open {return false}
	view := status_inbox_view(app, w, inbox)
	rows := view.rows
	if step := ui.list_step(logical); step != 0 {
		// Labels are passed over; the selection stops at the first and last report.
		if next := status_inbox_report(rows, inbox.selected + step, step); next >= 0 {inbox.selected = next}
		status_inbox_clamp(inbox, view.list, rows, view.total)
		w.dirty = true
		return true
	}
	selected := inbox.selected >= 0 && inbox.selected < len(rows)
	#partial switch logical.key {
	case .Escape:
		status_inbox_close(w)
	case .Enter, .Numpad_Enter:
		if selected {status_open_item(app, w, rows[inbox.selected].item)}
	case .Delete:
		if selected {status_dismiss_item(app, rows[inbox.selected].item)}
	case .U:
		if logical.modifiers != {} {return false}
		if selected {status_receipt_toggle(app, rows[inbox.selected].item)}
	case:
		action, found := shortcut_action(app, e)
		if !found || action != .Status_Next {return false}
		status_inbox_close(w)
		status_next_attention(app, w)
	}
	return true
}

// A key the focused pane takes as its own, such as typing, ends the open inbox. Modifiers, and keys that
// ran a shortcut, leave it open; a shortcut that opens another surface closes it there.
status_inbox_typed :: proc(w: ^Window, e: input.Key_Event) {
	if e.pressed && !input.is_modifier_key(e.key) {status_inbox_close(w)}
}

status_overview_cancel :: proc(w: ^Window) {
	status_inbox_close(w)
	status_panel_hover_clear(w)
	w.status.pill_hover = false
}

when AIO_CONTROL {
	// The open inbox's verification keys: its rows as the panel reports its own, and the selection.
	status_inbox_state_report :: proc(r: ^State_Report, app: ^App, w: ^Window) {
		inbox, open := &w.status.inbox.?
		state_value(r, "inbox.open", open)
		if !open {return}
		view := status_inbox_view(app, w, inbox)
		state_value(r, "inbox.selected", inbox.selected)
		status_rows_state_report(r, app, "inbox.row", view.rows, view.list, inbox.scroll)
	}
}

// Activity inbox pointer surface

@(private)
status_inbox_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {return status_inbox_shown(w)}

@(private)
status_inbox_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: input.Mouse_Move_Event) {
	if owner == .Status_Inbox {status_inbox_move(app, w, f32(e.x), f32(e.y))}
}

// Activity pill pointer surface

@(private)
status_pill_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	return render.rect_contains(status_pill_rect(app, w), x, y)
}

@(private)
status_pill_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: input.Mouse_Move_Event) {
	hovered := owner == .Status_Pill
	status_pill_hover_set(w, hovered)
	if hovered {pointer_set(app, w, chrome_pointer(app, w, f32(e.x), f32(e.y)))}
}

@(private)
status_pill_tooltip :: proc(_: ^App, _: ^Window, _, _: f32) -> string {return "Activity"}

@(private)
status_pill_press :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) {
	if e.button == .Left {status_inbox_toggle(app, w)}
}

@(private)
status_pill_leave :: proc(_: ^App, w: ^Window) {
	status_pill_hover_set(w, false)
}
