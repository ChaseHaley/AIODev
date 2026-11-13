package main

import "aio:input"
import "aio:layout"
import "aio:render"
import "aio:settings"
import "aio:term"
import "aio:ui"
import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"

// Sizes in DIPs. The logos sit left and the state mark right in both views.
@(private) STATUS_PANEL_COMFY_ROW :: f32(56)
@(private) STATUS_PANEL_COMFY_LOGO :: f32(20)
@(private) STATUS_PANEL_COMFY_CHILD_LOGO :: f32(16)
@(private) STATUS_PANEL_DENSE_ROW :: f32(32)
@(private) STATUS_PANEL_DENSE_CHILD :: f32(28)
@(private) STATUS_PANEL_DENSE_LOGO :: f32(16)
@(private) STATUS_PANEL_DENSE_CHILD_LOGO :: f32(14)
@(private) STATUS_PANEL_INDENT :: f32(12)
@(private) STATUS_PANEL_DEPTH_MAX :: 3
// In the rail the panel keeps its header and a row, and the tabs keep the footer and two rows.
@(private) STATUS_PANEL_RAIL_MIN :: f32(80)
@(private) STATUS_RAIL_TABS_MIN :: f32(96)
// The Activity panel's title band.
STATUS_PANEL_HEADER :: ui.HEIGHT_STANDARD
// One wheel notch, independent of the views' row heights.
@(private) STATUS_PANEL_WHEEL :: f32(96)

// The header's buttons, listed from the right edge: dock side, view, grouping, then what rows show.
Status_Panel_Button :: enum {
	None,
	Side,
	View,
	Group,
	Show,
}

// The Activity panel's state in one window.
Status_Panel :: struct {
	// A dragged width in DIPs and in-rail height as a share of the rail; zero follows the settings.
	panel_width, panel_height: f32,
	panel_button_armed: ui.Armed(Status_Panel_Button),
	panel_button_hover: Status_Panel_Button,
	// The row under the pointer.
	panel_hover:        Maybe(int),
	// Kept within the rows by status_panel_rows, which every draw and event projects through.
	panel_scroll:       f32,
}

status_panel_visible :: proc(app: ^App, w: ^Window) -> bool {
	return status_panel_visible_in(app, w, w.pane_fill)
}

// Whether the panel shows when the window's pane fill is `fill`; a filling pane covers it.
status_panel_visible_in :: proc(app: ^App, w: ^Window, fill: layout.Pane_Fill) -> bool {
	s := &app.settings.status
	if !s.enabled || !s.panel || w.phase == .Preparing || window_linked(w) || fill != .None {
		return false
	}
	return true
}

// Vertical view puts a left panel under the tabs in the docked rail.
status_panel_in_rail :: proc(app: ^App, w: ^Window) -> bool {
	return status_panel_in_rail_in(app, w, w.pane_fill)
}

status_panel_in_rail_in :: proc(app: ^App, w: ^Window, fill: layout.Pane_Fill) -> bool {
	return status_panel_visible_in(app, w, fill) && app.settings.status.panel_side == .Left &&
		rail_docked_in(w, fill)
}

// The rail gives the bottom of its height to the panel in vertical view.
status_panel_rail_height :: proc(app: ^App, w: ^Window) -> f32 {
	if !status_panel_in_rail(app, w) {return 0}
	share := w.status.panel_height > 0 ? w.status.panel_height : f32(app.settings.status.panel_height) / 100
	return status_panel_rail_clamp(w, rail_area(w).height * share)
}

// Whole-pixel panel height that leaves both the panel and the tab list usable.
status_panel_rail_clamp :: proc(w: ^Window, height: f32) -> f32 {
	area := rail_area(w)
	lowest := min(STATUS_PANEL_RAIL_MIN * w.scale, area.height / 2)
	highest := max(lowest, area.height - STATUS_RAIL_TABS_MIN * w.scale)
	return math.round(clamp(height, lowest, highest))
}

status_panel_dock_width :: proc(app: ^App, w: ^Window) -> f32 {
	return status_panel_dock_width_in(app, w, w.pane_fill)
}

// The width the panel takes beside the panes when the window's pane fill is `fill`.
status_panel_dock_width_in :: proc(app: ^App, w: ^Window, fill: layout.Pane_Fill) -> f32 {
	if !status_panel_visible_in(app, w, fill) || status_panel_in_rail_in(app, w, fill) {return 0}
	width := w.status.panel_width > 0 ? w.status.panel_width : f32(app.settings.status.panel_width)
	available := f32(w.width) - (rail_docked_in(w, fill) ? rail_width_pixels(w) : 0)
	return ui.rail_pixel_width(w.scale, width, available)
}

// Refreshes what the panel reserves from the rail: its width left of the rail, which places the rail,
// and its height in the rail, which the tab list leaves free. Relayout and dock edge drags call it.
window_dock_reserve :: proc(app: ^App, w: ^Window) {
	w.dock_left_width = app.settings.status.panel_side == .Left ? status_panel_dock_width(app, w) : 0
	w.status_rail_reserve = status_panel_rail_height(app, w)
}

status_panel_rect :: proc(app: ^App, w: ^Window) -> render.Rect {
	if !status_panel_visible(app, w) {return {}}
	if status_panel_in_rail(app, w) {
		area := rail_area(w)
		height := status_panel_rail_height(app, w)
		return {area.x, area.y + area.height - height, area.width, height}
	}
	content := window_content_area(app, w)
	gap := window_gap(app, w)
	width := status_panel_dock_width(app, w) - gap
	if app.settings.status.panel_side == .Left {
		return {gap, content.y, max(0, width), content.height}
	}
	return {content.x + content.width + gap, content.y, max(0, width), content.height}
}

// A header button's square: Side at the right edge, each later button one step further left.
status_panel_button_rect :: proc(app: ^App, w: ^Window, button: Status_Panel_Button) -> render.Rect {
	r := status_panel_rect(app, w)
	if r.width <= 0 || button == .None {return {}}
	size := ui.HEIGHT_COMPACT * w.scale
	top := (STATUS_PANEL_HEADER * w.scale - size) / 2
	step := f32(int(button) - int(Status_Panel_Button.Side)) * (size + ui.SPACE_1 * w.scale)
	return {r.x + r.width - ui.SPACE_1 * w.scale - size - step, r.y + top, size, size}
}

// One preference in the settings file, so Settings and every window follow it.
status_panel_view_toggle :: proc(app: ^App) {
	@(static, rodata)
	names := settings.STATUS_PANEL_VIEW_NAME
	next: settings.Status_Panel_View = app.settings.status.panel_view == .Comfy ? .Dense : .Comfy
	settings_save_value(app, "status.panel_view", names[next], "Could not save Activity view.")
}

// Runs a header button after a press and release both landed on it.
@(private)
status_panel_button_fire :: proc(app: ^App, w: ^Window, button: Status_Panel_Button) {
	switch button {
	case .None:
	case .Side:
		status_panel_side_toggle(app)
	case .View:
		status_panel_view_toggle(app)
	case .Group:
		activity_menu_toggle(app, w, .Group, status_panel_button_rect(app, w, .Group))
	case .Show:
		activity_menu_toggle(app, w, .Show, status_panel_button_rect(app, w, .Show))
	}
}

status_panel_side_toggle :: proc(app: ^App) {
	@(static, rodata)
	names := settings.STATUS_PANEL_SIDE_NAME
	next: settings.Status_Panel_Side = app.settings.status.panel_side == .Right ? .Left : .Right
	settings_save_value(app, "status.panel_side", names[next], "Could not save Activity side.")
}

@(private)
status_panel_list :: proc(w: ^Window, panel: render.Rect) -> render.Rect {
	s := w.scale
	header, pad := STATUS_PANEL_HEADER * s, ui.OVERLAY_PADDING * s
	return {panel.x + pad, panel.y + header, max(0, panel.width - 2 * pad), max(0, panel.height - header - pad)}
}

// Report row heights for a view.
@(private)
status_panel_heights :: proc(view: settings.Status_Panel_View) -> Status_Row_Heights {
	switch view {
	case .Comfy:
		return {STATUS_PANEL_COMFY_ROW, STATUS_PANEL_COMFY_ROW}
	case .Dense:
		return {STATUS_PANEL_DENSE_ROW, STATUS_PANEL_DENSE_CHILD}
	}
	return {}
}

// The panel's rows, their height and the scroll kept within them, projected without storing anything.
@(private)
status_panel_layout :: proc(app: ^App, w: ^Window) -> (rows: []Status_Row, total, scroll: f32) {
	s := &app.settings.status
	rows, total = status_rows_project(s.group_by, status_reports(app, w), status_panel_heights(s.panel_view),
		w.scale)
	list := status_panel_list(w, status_panel_rect(app, w))
	return rows, total, clamp(w.status.panel_scroll, 0, max(0, total - list.height))
}

// The panel's rows this frame or event. Projecting also stores the scroll clamp, so a hit test after
// the reports shrink or the panel resizes sees the rows a draw would show.
status_panel_rows :: proc(app: ^App, w: ^Window) -> (rows: []Status_Row, total: f32) {
	rows, total, w.status.panel_scroll = status_panel_layout(app, w)
	return
}

// Goes to the pane `step` places after the focused one in the order the panel lists its rows, wrapping
// at either end; with the focused pane not listed, Next starts at the first and Previous at the last.
// A pane several rows report from counts once, at its first row.
status_panel_step :: proc(app: ^App, w: ^Window, step: int) {
	rows, _, _ := status_panel_layout(app, w)
	focused := focused_session(app, w)
	sessions := make([dynamic]u32, 0, len(rows), context.temp_allocator)
	current := -1
	for row in rows {
		if !row.report || slice.contains(sessions[:], row.item.session) {continue}
		if focused != nil && row.item.session == focused.id {current = len(sessions)}
		append(&sessions, row.item.session)
	}
	if len(sessions) == 0 {
		notify(app, .Info, STATUS_EMPTY_TEXT)
		return
	}
	next := step > 0 ? 0 : len(sessions) - 1
	if current >= 0 {next = (current + step) %% len(sessions)}
	if session_show(app, w, sessions[next]) {status_panel_reveal(app, w, sessions[next])}
}

// Scrolls the panel the least that brings the first row `session` reports from wholly into view.
@(private)
status_panel_reveal :: proc(app: ^App, w: ^Window, session: u32) {
	if !status_panel_visible(app, w) {return}
	rows, _ := status_panel_rows(app, w)
	list := status_panel_list(w, status_panel_rect(app, w))
	for row in rows {
		if !row.report || row.item.session != session {continue}
		scroll := w.status.panel_scroll
		if row.y < scroll {
			scroll = row.y
		} else if row.y + row.height > scroll + list.height {
			scroll = row.y + row.height - list.height
		}
		if scroll != w.status.panel_scroll {
			w.status.panel_scroll = scroll
			w.dirty = true
		}
		return
	}
}

// Rows from the focused pane are drawn as the selected tab is.
@(private)
status_panel_row_selected :: proc(focused: ^Session_Entry, row: Status_Row) -> bool {
	return row.report && focused != nil && row.item.session == focused.id
}

@(private)
status_panel_row_rect :: proc(list: render.Rect, row: Status_Row, scroll: f32) -> render.Rect {
	return {list.x, list.y + row.y - scroll, list.width, row.height}
}

@(private)
status_panel_row_box :: proc(w: ^Window, r: render.Rect, row: Status_Row) -> render.Rect {
	indent := f32(min(row.depth, STATUS_PANEL_DEPTH_MAX)) * STATUS_PANEL_INDENT * w.scale
	return {r.x + indent, r.y, max(0, r.width - indent), r.height}
}

// The vertical middle of a Comfy row's title line, which its logo, mark and dismiss button share.
@(private)
status_panel_comfy_title_middle :: proc(w: ^Window, r: render.Rect) -> f32 {
	strong := ui.text_styled(&w.ui_text, .Strong)
	small := ui.text_styled(&w.ui_text, .Detail)
	line_one, _ := ui.stacked_baselines(r, &strong, &small, w.scale)
	return line_one - strong.ascent + strong.line_height / 2
}

status_panel_dismiss_rect :: proc(app: ^App, w: ^Window, r: render.Rect) -> render.Rect {
	close := status_dismiss_rect(w, r)
	if app.settings.status.panel_view == .Comfy {
		close.y = math.round(status_panel_comfy_title_middle(w, r) - close.height / 2)
	}
	return close
}

// A short elbow from the top of a child row to its logo.
@(private)
status_panel_guide_draw :: proc(app: ^App, w: ^Window, box: render.Rect, middle: f32) {
	line := max(1, math.round(w.scale))
	x, y := math.round(box.x), math.round(middle)
	ui.draw_rect(&w.list, {rect = {x, box.y, line, y - box.y}, color = app.theme.border})
	ui.draw_rect(&w.list, {rect = {x, y, ui.SPACE_2 * w.scale, line}, color = app.theme.border})
}

@(private)
status_panel_logo_draw :: proc(
	app: ^App,
	w: ^Window,
	x, middle, size: f32,
	item: Status_Item,
) -> render.Build_Status {
	s := w.scale
	extent := math.round(size * s)
	area := render.Rect{math.round(x), math.round(middle - extent / 2), extent, extent}
	atlas, pending, result := report_icon(app, session_find(app, item.session), item.record.app, extent)
	if result != .Ok {return result}
	if atlas.width > 0 {return ui.shell_badge_draw(&w.list, &w.ui_text, app.theme, area, "", s, atlas)}
	if !pending {ui.icon_draw(&w.list, .Terminal, area, app.theme.muted, ui.ICON_BUTTON, s)}
	return .Ok
}

// Where a row's state pair starts: its mark at `right`, and before it `text`, how long the record has
// held its state.
@(private)
status_panel_state_left :: proc(w: ^Window, right: f32, text: string) -> f32 {
	small := ui.text_styled(&w.ui_text, .Detail)
	return right - (ui.ICON_INDICATOR + ui.SPACE_1) * w.scale - ui.text_width(&small, text)
}

// A Dense row's state text: its progress while it reports one, else how long it has held its state.
@(private)
status_panel_dense_state :: proc(app: ^App, item: Status_Item, buffer: []u8) -> string {
	if item.record.progress >= 0 && item.record.state == .Working {
		return status_progress_text(item.record.progress, buffer)
	}
	return status_state_age(app, item.record)
}

// Where a report row's receipt sits, for drawing and for the press that toggles it: under the state
// pair in Comfy, before it in Dense.
status_panel_receipt_rect :: proc(app: ^App, w: ^Window, r: render.Rect, row: Status_Row) -> render.Rect {
	s := w.scale
	box := status_panel_row_box(w, r, row)
	right := box.x + box.width - ui.CONTROL_INSET * s
	small := ui.text_styled(&w.ui_text, .Detail)
	if app.settings.status.panel_view == .Comfy {
		strong := ui.text_styled(&w.ui_text, .Strong)
		_, line_two := ui.stacked_baselines(r, &strong, &small, s)
		return status_receipt_rect(app, w, row.item, right, line_two - small.ascent + small.line_height / 2)
	}
	buffer: [8]u8
	left := status_panel_state_left(w, right, status_panel_dense_state(app, row.item, buffer[:]))
	return status_receipt_rect(app, w, row.item, left - ui.SPACE_2 * s, r.y + r.height / 2)
}

// The right end of a row's first line: the state's mark with `text` before it, or Dismiss while a
// finished row is hovered. Returns where the text before it must end.
@(private)
status_panel_end_draw :: proc(
	app: ^App,
	w: ^Window,
	r: render.Rect,
	middle, right, baseline: f32,
	item: Status_Item,
	mark: ui.Status_Mark,
	text: string,
	highlighted: bool,
) -> (
	left: f32,
	result: render.Build_Status,
) {
	if highlighted && term.program_status_finished(item.record.state) {
		close := status_panel_dismiss_rect(app, w, r)
		ui.icon_draw(&w.list, .Close, close, app.theme.muted, ui.ICON_INDICATOR, w.scale)
		return close.x, .Ok
	}
	size := ui.ICON_INDICATOR * w.scale
	area := render.Rect{right - size, math.round(middle - size / 2), size, size}
	if result = status_mark_draw(app, w, area, mark); result != .Ok {return}
	left = status_panel_state_left(w, right, text)
	small := ui.text_styled(&w.ui_text, .Detail)
	ink := mark.dim ? app.theme.faint : ui.status_color(app.theme, mark.glyph)
	return left, ui.draw_text(&small, &w.list, text, left, baseline, ink)
}

// Comfy: logo, name, then the state's mark and how long it has held; then the row's terms, or the
// state, and the receipt; then any progress.
@(private)
status_panel_comfy_draw :: proc(
	app: ^App,
	w: ^Window,
	r: render.Rect,
	row: Status_Row,
	highlighted: bool,
) -> render.Build_Status {
	s := w.scale
	item := row.item
	box := status_panel_row_box(w, r, row)
	middle := status_panel_comfy_title_middle(w, r)
	if row.depth > 0 {status_panel_guide_draw(app, w, box, middle)}
	logo := row.depth > 0 ? STATUS_PANEL_COMFY_CHILD_LOGO : STATUS_PANEL_COMFY_LOGO
	left := box.x + ui.CONTROL_INSET * s
	if result := status_panel_logo_draw(app, w, left, middle, logo, item); result != .Ok {return result}
	strong := ui.text_styled(&w.ui_text, .Strong)
	small := ui.text_styled(&w.ui_text, .Detail)
	line_one, line_two := ui.stacked_baselines(r, &strong, &small, s)
	text_x := left + (logo + ui.SPACE_2) * s
	right := box.x + box.width - ui.CONTROL_INSET * s
	quiet := status_item_quiet(item)
	mark := status_presentation(item.record).mark
	mark.dim = quiet
	state_left, drawn := status_panel_end_draw(
		app, w, r, middle, right, line_one, item, mark, status_state_age(app, item.record), highlighted,
	)
	if drawn != .Ok {return drawn}
	name := status_report_name(&app.settings.status, item, row.depth)
	if result := ui.draw_fading_text(&strong, &w.list, name, text_x, line_one,
		quiet ? app.theme.muted : app.theme.text, max(0, state_left - ui.SPACE_2 * s - text_x));
	   result != .Ok {return result}
	receipt := status_panel_receipt_rect(app, w, r, row)
	if result := status_receipt_draw(app, w, item, receipt, line_two); result != .Ok {return result}
	buffer: [8]u8
	detail := status_report_terms(&app.settings.status, item, name)
	if detail == "" {detail = status_headline(mark, buffer[:])}
	if result := ui.draw_fading_text(&small, &w.list, detail, text_x, line_two, app.theme.faint,
		max(0, receipt.x - ui.SPACE_2 * s - text_x)); result != .Ok {return result}
	bar := render.Rect{text_x, r.y, max(0, right - text_x), r.height - ui.SPACE_1 * s}
	ui.status_progress_draw(&w.list, app.theme, bar, mark, s)
	return .Ok
}

// Dense: logo, then the name and the row's terms, or a child's name, then the receipt, then progress
// or how long it has held its state, and the state's mark.
@(private)
status_panel_dense_draw :: proc(
	app: ^App,
	w: ^Window,
	r: render.Rect,
	row: Status_Row,
	highlighted: bool,
) -> render.Build_Status {
	s := w.scale
	item := row.item
	box := status_panel_row_box(w, r, row)
	middle := r.y + r.height / 2
	if row.depth > 0 {status_panel_guide_draw(app, w, box, middle)}
	logo := row.depth > 0 ? STATUS_PANEL_DENSE_CHILD_LOGO : STATUS_PANEL_DENSE_LOGO
	left := box.x + (row.depth > 0 ? STATUS_PANEL_INDENT : ui.CONTROL_INSET) * s
	if result := status_panel_logo_draw(app, w, left, middle, logo, item); result != .Ok {return result}
	body := ui.text_styled(&w.ui_text, .Body)
	small := ui.text_styled(&w.ui_text, .Detail)
	baseline := middle - body.line_height / 2 + body.ascent
	right := box.x + box.width - ui.CONTROL_INSET * s
	quiet := status_item_quiet(item)
	mark := status_presentation(item.record).mark
	mark.dim = quiet
	buffer: [8]u8
	state := status_panel_dense_state(app, item, buffer[:])
	if _, result := status_panel_end_draw(app, w, r, middle, right, baseline, item, mark, state, highlighted);
	   result != .Ok {return result}
	receipt := status_panel_receipt_rect(app, w, r, row)
	if result := status_receipt_draw(app, w, item, receipt, baseline); result != .Ok {return result}
	text_x := left + (logo + ui.SPACE_2) * s
	room := max(0, receipt.x - ui.SPACE_2 * s - text_x)
	ink := quiet ? app.theme.muted : app.theme.text
	name := status_report_name(&app.settings.status, item, row.depth)
	terms := row.depth > 0 ? "" : status_report_terms(&app.settings.status, item, name)
	if terms == "" {return ui.draw_fading_text(&body, &w.list, name, text_x, baseline, ink, room)}
	place := min(ui.text_width(&body, name), room / 2)
	if result := ui.draw_fading_text(&body, &w.list, name, text_x, baseline, ink, place); result != .Ok {
		return result
	}
	gap := ui.SPACE_1 * s
	detail := fmt.tprintf("· %s", terms)
	return ui.draw_fading_text(&small, &w.list, detail, text_x + place + gap, baseline, app.theme.faint,
		max(0, room - place - gap))
}

status_panel_draw :: proc(app: ^App, w: ^Window) -> render.Build_Status {
	panel := status_panel_rect(app, w)
	if panel.width <= 0 || panel.height <= 0 {return .Ok}
	s := w.scale
	// The panel draws from the window's motion, as when its width resets or it slides out of view.
	region := pane_motion_region_begin(w, PANE_MOTION_PANEL, panel)
	defer pane_motion_region_end(w, &region)
	shown := region.shown
	if render.push_layer(&w.list, shown) != .None {return .Ok}
	if !status_panel_in_rail(app, w) {
		radius := f32(app.settings.pane.corner_radius) * s
		ui.draw_rect(&w.list, {rect = shown, color = app.theme.tab_bar, radius = radius})
	} else {
		ui.draw_rect(&w.list, {rect = shown, color = app.theme.tab_bar})
		ui.draw_rect(&w.list, {rect = {shown.x, shown.y, shown.width, s}, color = app.theme.border})
	}
	pane_motion_region_content(w, &region)
	rows, _ := status_panel_rows(app, w)
	small := ui.text_styled(&w.ui_text, .Detail)
	strong := ui.text_styled(&w.ui_text, .Strong)
	header := STATUS_PANEL_HEADER * s
	// The title fades out before the buttons in a narrow panel.
	title_x := panel.x + ui.SPACE_3 * s
	title_room := max(0, status_panel_button_rect(app, w, .Show).x - ui.SPACE_1 * s - title_x)
	title_y := panel.y + (header - strong.line_height) / 2 + strong.ascent
	if result := ui.draw_fading_text(&strong, &w.list, "Activity", title_x, title_y, app.theme.text, title_room);
	   result != .Ok {return result}
	view_icon: ui.Icon = app.settings.status.panel_view == .Comfy ? .View_Comfy : .View_Dense
	side_icon: ui.Icon = app.settings.status.panel_side == .Left ? .Layout_Left : .Layout_Right
	group_icon: ui.Icon = app.settings.status.group_by == .Status ? .Group_Status : .Group_Workspace
	for button in Status_Panel_Button {
		icon: ui.Icon
		menu: Maybe(Activity_Menu_Kind)
		switch button {
		case .None:
			continue
		case .Side:
			icon = side_icon
		case .View:
			icon = view_icon
		case .Group:
			icon, menu = group_icon, .Group
		case .Show:
			icon, menu = .More, .Show
		}
		hover := f32(int(w.status.panel_button_hover == button))
		_, has_menu := menu.?
		open := has_menu && activity_menu_shown(w, menu)
		press := f32(int(ui.armed_is(w.status.panel_button_armed, button) || open))
		rect := status_panel_button_rect(app, w, button)
		_ = ui.icon_button_draw(&w.list, app.theme, rect, icon, hover, press, s, w.pointer)
	}
	list := status_panel_list(w, panel)
	if render.push_layer(&w.list, list) != .None {return .Ok}
	if len(rows) == 0 {
		return ui.draw_fading_text(
			&small,
			&w.list,
			STATUS_EMPTY_TEXT,
			list.x + 8 * s,
			list.y + 8 * s + small.ascent,
			app.theme.faint,
			max(0, list.width - 16 * s),
		)
	}
	dense := app.settings.status.panel_view == .Dense
	hovered, any_hovered := w.status.panel_hover.?
	// Rows from the focused pane take the selected tab's look, so Next and Previous have a visible start.
	focused := focused_session(app, w)
	for row, i in rows {
		r := status_panel_row_rect(list, row, w.status.panel_scroll)
		if r.y + r.height < list.y || r.y > list.y + list.height {continue}
		result: render.Build_Status
		highlighted := any_hovered && hovered == i
		if row.report {
			box := status_panel_row_box(w, r, row)
			selected := status_panel_row_selected(focused, row)
			if ui.navigation_row_surface_draw(&w.list, app.theme, box,
				{selected = selected, hovered = highlighted}, s, w.pointer) != .None {return .Ok}
		}
		switch {
		case !row.report:
			result = status_label_draw(app, w, r, row)
		case dense:
			result = status_panel_dense_draw(app, w, r, row, highlighted)
		case:
			result = status_panel_comfy_draw(app, w, r, row, highlighted)
		}
		if result != .Ok {return result}
	}
	return .Ok
}

status_panel_hit :: proc(
	app: ^App,
	w: ^Window,
	rows: []Status_Row,
	x, y: f32,
) -> (
	index: int,
	rect: render.Rect,
) {
	list := status_panel_list(w, status_panel_rect(app, w))
	if !render.rect_contains(list, x, y) {return -1, {}}
	for row, i in rows {
		r := status_panel_row_rect(list, row, w.status.panel_scroll)
		if row.report && render.rect_contains(r, x, y) {return i, r}
	}
	return -1, {}
}

// Who reported, what it says, how long it has said it, when the pane was last read and exactly where,
// for rows too narrow or alike to tell apart.
status_panel_row_tooltip :: proc(app: ^App, w: ^Window, x, y: f32) -> string {
	rows, _ := status_panel_rows(app, w)
	index, rect := status_panel_hit(app, w, rows, x, y)
	if index < 0 {return ""}
	item := rows[index].item
	if term.program_status_finished(item.record.state) &&
	   render.rect_contains(status_panel_dismiss_rect(app, w, rect), x, y) {
		return "Dismiss"
	}
	if render.rect_contains(status_panel_receipt_rect(app, w, rect, rows[index]), x, y) {
		return status_receipt_tooltip(app, item)
	}
	// The row's name, then the report's own title and program where they differ from it.
	who := status_report_name(&app.settings.status, item, rows[index].depth)
	for other in ([2]string{item.record.title, item.record.app}) {
		if other != "" && !strings.contains(who, other) {who = fmt.tprintf("%s · %s", who, other)}
	}
	buffer: [8]u8
	state := status_headline(status_presentation(item.record).mark, buffer[:])
	read := status_read_words(app, item)
	times := fmt.tprintf("%s for %s · %s", state, status_state_age(app, item.record), read)
	if item.record.message != "" {
		// Half the tooltip at most, so a long message never pushes the location out of it.
		message := tooltip_clip(item.record.message, TOOLTIP_LIMIT / 2)
		return fmt.tprintf("%s\n%s: %s\n%s\n%s", who, state, message, times, item.pane.crumb)
	}
	return fmt.tprintf("%s\n%s\n%s", who, times, item.pane.crumb)
}

status_panel_button_at :: proc(app: ^App, w: ^Window, x, y: f32) -> Status_Panel_Button {
	for button in Status_Panel_Button {
		if button != .None && render.rect_contains(status_panel_button_rect(app, w, button), x, y) {return button}
	}
	return .None
}

status_panel_contains :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	return render.rect_contains(status_panel_rect(app, w), x, y)
}

// The pointer moved over the panel, which owns it.
status_panel_move :: proc(app: ^App, w: ^Window, x, y: f32) {
	button := status_panel_button_at(app, w, x, y)
	if button != w.status.panel_button_hover {w.status.panel_button_hover, w.dirty = button, true}
	// The divider on the panel's edge sets its own cursor and leaves the row hover as it was.
	if _, on_divider := divider_cursor(w, x, y); on_divider {return}
	hover: Maybe(int)
	rows, _ := status_panel_rows(app, w)
	if index, _ := status_panel_hit(app, w, rows, x, y); index >= 0 {hover = index}
	status_panel_hover_set(w, hover)
	_, on_row := hover.?
	pointer_set(app, w, on_row || button != .None ? .Hand : .Arrow)
}

// The pointer left the panel for another surface.
status_panel_leave :: proc(_: ^App, w: ^Window) {
	status_panel_hover_set(w, nil)
	if w.status.panel_button_hover != .None {w.status.panel_button_hover, w.dirty = .None, true}
}

@(private = "file")
status_panel_hover_set :: proc(w: ^Window, hover: Maybe(int)) {
	if hover == w.status.panel_hover {return}
	w.status.panel_hover = hover
	w.dirty = true
}

// Forgets the hovered row without a repaint, for an overlay cancelling every overview at once.
status_panel_hover_clear :: proc(w: ^Window) {
	w.status.panel_hover = nil
}

// Header buttons, then the row under the pointer.
status_panel_tooltip :: proc(app: ^App, w: ^Window, x, y: f32) -> string {
	switch status_panel_button_at(app, w, x, y) {
	case .Side:
		return "Move activity panel"
	case .View:
		return app.settings.status.panel_view == .Comfy ? "Switch to Dense" : "Switch to Comfy"
	case .Group:
		@(static, rodata)
		groups := settings.STATUS_GROUP_LABEL
		return fmt.tprintf("Group by: %s", groups[app.settings.status.group_by])
	case .Show:
		return "Show in rows"
	case .None:
	}
	return status_panel_row_tooltip(app, w, x, y)
}

// A press on the panel, which owns the pointer: header buttons arm, rows open the pane they came
// from, a finished row's Dismiss removes it, a receipt reads or unreads the pane, and a right click
// opens the row's menu.
status_panel_press :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) {
	if !e.pressed {return}
	x, y := f32(e.x), f32(e.y)
	gesture_swallow(w, e.button, .Status_Panel)
	if e.button != .Left && e.button != .Right {return}
	if e.button == .Left {
		if button := status_panel_button_at(app, w, x, y); button != .None {
			ui.armed_press(&w.status.panel_button_armed, button)
			return
		}
	}
	rows, _ := status_panel_rows(app, w)
	index, rect := status_panel_hit(app, w, rows, x, y)
	if index < 0 {return}
	item := rows[index].item
	if e.button == .Right {
		activity_row_menu_open(app, w, item, x, y)
		return
	}
	if term.program_status_finished(item.record.state) &&
	   render.rect_contains(status_panel_dismiss_rect(app, w, rect), x, y) {
		status_dismiss_item(app, item)
		w.dirty = true
		return
	}
	if status_item_markable(item) &&
	   render.rect_contains(status_panel_receipt_rect(app, w, rect, rows[index]), x, y) {
		status_receipt_toggle(app, item)
		return
	}
	status_open_item(app, w, item)
}

// Fires an armed header button when the release lands on it; reports whether the panel took it.
status_panel_release :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) -> bool {
	if e.button != .Left || !ui.armed_down(w.status.panel_button_armed) {return false}
	w.dirty = true
	button := status_panel_button_at(app, w, f32(e.x), f32(e.y))
	if fired, ok := ui.armed_release(&w.status.panel_button_armed, button); ok {
		status_panel_button_fire(app, w, fired)
	}
	return true
}

status_panel_cancel :: proc(_: ^App, w: ^Window) {
	ui.armed_cancel(&w.status.panel_button_armed)
}

status_panel_wheel :: proc(app: ^App, w: ^Window, x, y, delta: f32) -> bool {
	if !status_panel_contains(app, w, x, y) {return false}
	_, total := status_panel_rows(app, w)
	list := status_panel_list(w, status_panel_rect(app, w))
	step := f32(math.sign(delta)) * STATUS_PANEL_WHEEL * w.scale
	w.status.panel_scroll = clamp(w.status.panel_scroll - step, 0, max(0, total - list.height))
	w.dirty = true
	return true
}

when AIO_CONTROL {
	// The Activity panel's verification keys and its rows as the panel lists them.
	status_panel_state_report :: proc(r: ^State_Report, app: ^App, w: ^Window) {
		s := &app.settings.status
		area := status_panel_rect(app, w)
		state_rect(r, "activity.rect", area)
		state_rect(r, "activity.side_button", status_panel_button_rect(app, w, .Side))
		@(static, rodata)
		sides := settings.STATUS_PANEL_SIDE_NAME
		@(static, rodata)
		views := settings.STATUS_PANEL_VIEW_NAME
		@(static, rodata)
		groups := settings.STATUS_GROUP_NAME
		@(static, rodata)
		names := settings.STATUS_ROW_NAME_NAME
		state_text(r, "activity.side", sides[s.panel_side])
		state_rect(r, "activity.view_button", status_panel_button_rect(app, w, .View))
		state_text(r, "activity.view", views[s.panel_view])
		state_rect(r, "activity.group_button", status_panel_button_rect(app, w, .Group))
		state_text(r, "activity.group", groups[s.group_by])
		state_rect(r, "activity.show_button", status_panel_button_rect(app, w, .Show))
		state_text(r, "activity.row_name", names[s.row_name])
		state_text(r, "activity.row_terms", settings.set_text(settings.STATUS_ROW_TERM_NAMES,
			transmute(u32)s.row_terms))
		activity_menu_state_report(r, w)
		rows, _, scroll := status_panel_layout(app, w)
		list := status_panel_list(w, area)
		status_rows_state_report(r, app, "activity.row", rows, list, scroll)
		focused := focused_session(app, w)
		for row, i in rows {
			if !row.report {continue}
			rect := render.Rect{list.x, list.y + row.y - scroll, list.width, row.height}
			receipt := status_panel_receipt_rect(app, w, rect, row)
			state_rect(r, state_key("activity.row.%d.receipt_rect", i), receipt)
			state_value(r, state_key("activity.row.%d.selected", i), status_panel_row_selected(focused, row))
		}
	}
}

when AIO_CONTROL {
	// Rows under `prefix`: rect, whether a report, the text (a report's name or a label), the report's
	// terms, depth and whether a label is nested.
	status_rows_state_report :: proc(
		r: ^State_Report,
		app: ^App,
		prefix: string,
		rows: []Status_Row,
		list: render.Rect,
		scroll: f32,
	) {
		s := &app.settings.status
		for row, i in rows {
			rect := render.Rect{list.x, list.y + row.y - scroll, list.width, row.height}
			state_rect(r, state_key("%s.%d.rect", prefix, i), rect)
			state_value(r, state_key("%s.%d.report", prefix, i), row.report)
			text := row.label
			if row.report {
				text = status_report_name(s, row.item, row.depth)
				state_text(r, state_key("%s.%d.terms", prefix, i), status_report_terms(s, row.item, text))
				_, receipt := status_receipt(app, row.item)
				state_value(r, state_key("%s.%d.read", prefix, i), row.item.record.read)
				state_value(r, state_key("%s.%d.ended", prefix, i), row.item.record.ended)
				state_text(r, state_key("%s.%d.receipt", prefix, i), receipt)
				state_text(r, state_key("%s.%d.state_age", prefix, i), status_state_age(app, row.item.record))
			}
			state_text(r, state_key("%s.%d.text", prefix, i), text)
			state_value(r, state_key("%s.%d.depth", prefix, i), row.depth)
			state_value(r, state_key("%s.%d.nested", prefix, i), row.nested)
		}
	}
}

// Activity panel pointer surface

@(private)
status_panel_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	return status_panel_contains(app, w, x, y)
}

@(private)
status_panel_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: input.Mouse_Move_Event) {
	if owner == .Status_Panel {
		status_panel_move(app, w, f32(e.x), f32(e.y))
		return
	}
	status_panel_leave(app, w)
}
