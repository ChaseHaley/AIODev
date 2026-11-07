package main

import "aio:glyphs"
import "aio:layout"
import "aio:platform"
import "aio:render"
import "aio:settings"
import "aio:term"
import "aio:ui"
import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"

// Sizes in DIPs. The logos sit left and the state mark right in both views.
@(private) STATUS_PANEL_LABEL_HEIGHT :: f32(28)
@(private) STATUS_PANEL_GROUP_GAP :: f32(8)
@(private) STATUS_PANEL_COMFY_ROW :: f32(56)
@(private) STATUS_PANEL_COMFY_LOGO :: f32(20)
@(private) STATUS_PANEL_COMFY_CHILD_LOGO :: f32(16)
@(private) STATUS_PANEL_DENSE_ROW :: f32(32)
@(private) STATUS_PANEL_DENSE_CHILD :: f32(28)
@(private) STATUS_PANEL_DENSE_LOGO :: f32(16)
@(private) STATUS_PANEL_DENSE_CHILD_LOGO :: f32(14)
@(private) STATUS_PANEL_INDENT :: f32(12)
@(private) STATUS_PANEL_DEPTH_MAX :: 3

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

status_panel_side_rect :: proc(app: ^App, w: ^Window) -> render.Rect {
	r := status_panel_rect(app, w)
	if r.width <= 0 {return {}}
	size := ui.HEIGHT_COMPACT * w.scale
	top := (STATUS_PANEL_HEADER * w.scale - size) / 2
	return {r.x + r.width - ui.SPACE_1 * w.scale - size, r.y + top, size, size}
}

status_panel_view_rect :: proc(app: ^App, w: ^Window) -> render.Rect {
	r := status_panel_side_rect(app, w)
	if r.width <= 0 {return {}}
	r.x -= r.width + ui.SPACE_1 * w.scale
	return r
}

// One preference in the settings file, so Settings and every window follow it.
status_panel_view_toggle :: proc(app: ^App) {
	dense := app.settings.status.panel_view == .Comfy
	value := dense ? "dense" : "comfy"
	if _, has_file := settings_save_value(app, "status.panel_view", value, "Could not save Activity view.");
	   !has_file {
		app.settings.status.panel_view = dense ? .Dense : .Comfy
		for window in app.windows {window.dirty = true}
	}
}

// Runs a header button after a press and release both landed on it.
status_panel_button_fire :: proc(app: ^App, button: Status_Panel_Button) {
	switch button {
	case .None:
	case .Side:
		status_panel_side_toggle(app)
	case .View:
		status_panel_view_toggle(app)
	}
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
	header, pad := STATUS_PANEL_HEADER * s, ui.OVERLAY_PADDING * s
	return {panel.x + pad, panel.y + header, max(0, panel.width - 2 * pad), max(0, panel.height - header - pad)}
}

// A report and how deep it sits under other reports shown from its pane.
Status_Panel_Report :: struct {
	item:  Status_Item,
	depth: int,
}

Status_Panel_Section :: enum {
	Needs_You,
	Working,
	Finished,
	Idle,
}

@(private, rodata)
status_panel_section_names := [Status_Panel_Section]string {
	.Needs_You = "Needs you",
	.Working   = "Working",
	.Finished  = "Finished",
	.Idle      = "Idle",
}

// One row of the panel as this frame or event lays it out: a report, or a label above reports.
// Drawing, hit testing and tooltips read the same rows, so they cannot disagree about where a row
// is. Rows borrow from the reports they were projected from.
Status_Panel_Row :: struct {
	item:      Status_Item,
	depth:     int,
	report:    bool,
	label:     string,
	// Dense sections count the trees under them; zero shows no count.
	count:     int,
	attention: bool,
	y, height: f32,
}

// Ids in tree order: a report is followed by its descendants, whatever bytes their siblings hold.
status_panel_id_less :: proc(a, b: term.Program_Status) -> bool {
	for i in 0 ..< min(len(a.id), len(b.id)) {
		if a.id[i] == b.id[i] {continue}
		if a.id[i] == '/' {return true}
		if b.id[i] == '/' {return false}
		return a.id[i] < b.id[i]
	}
	return len(a.id) < len(b.id)
}

@(private)
status_panel_id_within :: proc(id, ancestor: string) -> bool {
	if ancestor == "" {return true}
	return len(id) > len(ancestor) && strings.has_prefix(id, ancestor) && id[len(ancestor)] == '/'
}

// Sorts one pane's shown records into tree order and appends them with their depth. Depth counts
// ancestors among these records, so a report whose parent is not shown is a root.
status_panel_tree_append :: proc(
	reports: ^[dynamic]Status_Panel_Report,
	records: []term.Program_Status,
	session: u32,
	crumb, workspace: string,
) {
	slice.sort_by(records, status_panel_id_less)
	ancestors := make([dynamic]string, 0, 8, context.temp_allocator)
	for record in records {
		for len(ancestors) > 0 && !status_panel_id_within(record.id, ancestors[len(ancestors) - 1]) {
			pop(&ancestors)
		}
		item := Status_Item{session = session, record = record, crumb = crumb, workspace = workspace}
		append(reports, Status_Panel_Report{item, len(ancestors)})
		append(&ancestors, record.id)
	}
}

@(private)
status_panel_reports :: proc(app: ^App, w: ^Window) -> []Status_Panel_Report {
	reports := make([dynamic]Status_Panel_Report, context.temp_allocator)
	if !app.settings.status.enabled {return reports[:]}
	for workspace in app.workspaces {
		if !workspace_eligible(app, workspace) || !status_in_scope(app, w, workspace) {continue}
		walk := workspace_session_panes(app, workspace)
		for pane, ok := workspace_pane_next(&walk); ok; pane, ok = workspace_pane_next(&walk) {
			entry := pane.session
			if entry == nil || len(entry.statuses) == 0 {continue}
			records := make([dynamic]term.Program_Status, 0, len(entry.statuses), context.temp_allocator)
			for record in entry.statuses {
				if status_shown(app, record) {append(&records, record)}
			}
			if len(records) == 0 {continue}
			crumb := status_crumb_at(workspace, pane.tab, entry)
			status_panel_tree_append(&reports, records[:], entry.id, crumb, workspace.name)
		}
	}
	return reports[:]
}

@(private)
status_panel_section :: proc(record: term.Program_Status) -> Status_Panel_Section {
	switch record.state {
	case .Blocked, .Error:
		return .Needs_You
	case .Done, .Done_Seen, .Error_Seen:
		return .Finished
	case .Working:
		return .Working
	case .Idle:
		return .Idle
	}
	return .Idle
}

// Lays reports out for a view at `scale`. Comfy keeps their order under workspace labels. Dense
// sorts whole trees into sections by the most urgent report in each, so a blocked child is never
// hidden under Working, and keeps their order within a section so rows do not jump as ages change.
status_panel_project :: proc(
	view: settings.Status_Panel_View,
	reports: []Status_Panel_Report,
	scale: f32,
) -> (
	rows: []Status_Panel_Row,
	total: f32,
) {
	if len(reports) == 0 {return}
	out := make([dynamic]Status_Panel_Row, 0, len(reports) + 8, context.temp_allocator)
	label :: proc(
		out: ^[dynamic]Status_Panel_Row,
		text: string,
		count: int,
		attention: bool,
		total: ^f32,
		s: f32,
	) {
		if len(out) > 0 {total^ += STATUS_PANEL_GROUP_GAP * s}
		height := STATUS_PANEL_LABEL_HEIGHT * s
		row := Status_Panel_Row {
			label     = text,
			count     = count,
			attention = attention,
			y         = total^,
			height    = height,
		}
		append(out, row)
		total^ += height
	}
	report :: proc(out: ^[dynamic]Status_Panel_Row, r: Status_Panel_Report, height: f32, total: ^f32) {
		row := Status_Panel_Row {
			item   = r.item,
			depth  = r.depth,
			report = true,
			y      = total^,
			height = height,
		}
		append(out, row)
		total^ += height
	}
	total = ui.SPACE_1 * scale
	switch view {
	case .Comfy:
		for r, i in reports {
			if i == 0 || r.item.workspace != reports[i - 1].item.workspace {
				label(&out, r.item.workspace, 0, false, &total, scale)
			}
			report(&out, r, STATUS_PANEL_COMFY_ROW * scale, &total)
		}
	case .Dense:
		Tree :: struct {
			first, end: int,
		}
		trees: [Status_Panel_Section][dynamic]Tree
		for section in Status_Panel_Section {trees[section].allocator = context.temp_allocator}
		for first := 0; first < len(reports); {
			end := first + 1
			section := status_panel_section(reports[first].item.record)
			for end < len(reports) && reports[end].depth > 0 {
				section = min(section, status_panel_section(reports[end].item.record))
				end += 1
			}
			append(&trees[section], Tree{first, end})
			first = end
		}
		for section in Status_Panel_Section {
			if len(trees[section]) == 0 {continue}
			name := status_panel_section_names[section]
			label(&out, name, len(trees[section]), section == .Needs_You, &total, scale)
			for tree in trees[section] {
				for r in reports[tree.first:tree.end] {
					height := r.depth > 0 ? STATUS_PANEL_DENSE_CHILD : STATUS_PANEL_DENSE_ROW
					report(&out, r, height * scale, &total)
				}
			}
		}
	}
	return out[:], total + ui.SPACE_1 * scale
}

status_panel_rows :: proc(app: ^App, w: ^Window) -> (rows: []Status_Panel_Row, total: f32) {
	return status_panel_project(app.settings.status.panel_view, status_panel_reports(app, w), w.scale)
}

@(private)
status_panel_row_rect :: proc(w: ^Window, list: render.Rect, row: Status_Panel_Row) -> render.Rect {
	return {list.x, list.y + row.y - w.status.panel_scroll, list.width, row.height}
}

@(private)
status_panel_row_box :: proc(w: ^Window, r: render.Rect, row: Status_Panel_Row) -> render.Rect {
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
) -> glyphs.Result {
	s := w.scale
	extent := math.round(size * s)
	area := render.Rect{math.round(x), math.round(middle - extent / 2), extent, extent}
	atlas, pending, result := report_icon(app, session_find(app, item.session), item.record.app, extent)
	if result != .Ok {return result}
	if atlas.width > 0 {return ui.shell_badge_draw(&w.list, &w.ui_text, app.theme, area, "", s, atlas)}
	if !pending {ui.icon_draw(&w.list, .Terminal, area, app.theme.muted, ui.ICON_BUTTON, s)}
	return .Ok
}

// The right end every row shares: the state mark, or Dismiss while a finished row is hovered.
@(private)
status_panel_end_draw :: proc(
	app: ^App,
	w: ^Window,
	r: render.Rect,
	middle, right: f32,
	item: Status_Item,
	mark: ui.Status_Mark,
	highlighted: bool,
) -> glyphs.Result {
	if highlighted && term.program_status_finished(item.record.state) {
		close := status_panel_dismiss_rect(app, w, r)
		ui.icon_draw(&w.list, .Close, close, app.theme.muted, ui.ICON_INDICATOR, w.scale)
		return .Ok
	}
	size := ui.ICON_INDICATOR * w.scale
	return status_mark_draw(app, w, {right - size, math.round(middle - size / 2), size, size}, mark)
}

// Comfy: logo, title and state; then the message or state and the age; then any progress.
@(private)
status_panel_comfy_draw :: proc(
	app: ^App,
	w: ^Window,
	r: render.Rect,
	row: Status_Panel_Row,
	highlighted: bool,
) -> glyphs.Result {
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
	title_room := max(0, right - (ui.ICON_INDICATOR + ui.SPACE_2) * s - text_x)
	quiet := term.program_status_seen(item.record.state)
	if result := ui.draw_fading_text(&strong, &w.list, status_item_name(app, item), text_x, line_one,
		quiet ? app.theme.muted : app.theme.text, title_room); result != .Ok {return result}
	mark := status_mark(item.record)
	if result := status_panel_end_draw(app, w, r, middle, right, item, mark, highlighted); result != .Ok {
		return result
	}
	age := status_age(item.record.updated_at)
	age_width := ui.text_width(&small, age)
	if result := ui.draw_text(&small, &w.list, age, right - age_width, line_two, app.theme.faint);
	   result != .Ok {return result}
	buffer: [8]u8
	detail := item.record.message != "" ? item.record.message : ui.status_headline(mark, buffer[:])
	if result := ui.draw_fading_text(&small, &w.list, detail, text_x, line_two, app.theme.faint,
		max(0, right - age_width - ui.SPACE_2 * s - text_x)); result != .Ok {return result}
	bar := render.Rect{text_x, r.y, max(0, right - text_x), r.height - ui.SPACE_1 * s}
	ui.status_progress_draw(&w.list, app.theme, bar, mark, s)
	return .Ok
}

// Dense: logo, then workspace and title, or a child's title, then age or progress and state.
@(private)
status_panel_dense_draw :: proc(
	app: ^App,
	w: ^Window,
	r: render.Rect,
	row: Status_Panel_Row,
	highlighted: bool,
) -> glyphs.Result {
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
	mark := status_mark(item.record)
	if result := status_panel_end_draw(app, w, r, middle, right, item, mark, highlighted); result != .Ok {
		return result
	}
	progress_or_age := status_age(item.record.updated_at)
	if mark.progress >= 0 {progress_or_age = fmt.tprintf("%d%%", mark.progress)}
	age_x := right - (ui.ICON_INDICATOR + ui.SPACE_2) * s - ui.text_width(&small, progress_or_age)
	if result := ui.draw_text(&small, &w.list, progress_or_age, age_x, baseline, app.theme.faint);
	   result != .Ok {return result}
	text_x := left + (logo + ui.SPACE_2) * s
	room := max(0, age_x - ui.SPACE_2 * s - text_x)
	quiet := term.program_status_seen(item.record.state) || item.record.state == .Idle
	ink := quiet ? app.theme.muted : app.theme.text
	name := status_item_name(app, item)
	if row.depth > 0 {return ui.draw_fading_text(&body, &w.list, name, text_x, baseline, ink, room)}
	place := min(ui.text_width(&body, item.workspace), room / 2)
	if result := ui.draw_fading_text(&body, &w.list, item.workspace, text_x, baseline, ink, place);
	   result != .Ok {return result}
	gap := ui.SPACE_1 * s
	detail := fmt.tprintf("· %s", name)
	return ui.draw_fading_text(&small, &w.list, detail, text_x + place + gap, baseline, app.theme.faint,
		max(0, room - place - gap))
}

@(private)
status_panel_label_draw :: proc(
	app: ^App,
	w: ^Window,
	r: render.Rect,
	row: Status_Panel_Row,
) -> glyphs.Result {
	s := w.scale
	small := ui.text_styled(&w.ui_text, .Detail)
	ink := row.attention ? ui.status_color(app.theme, .Blocked) : app.theme.faint
	baseline := r.y + ui.SPACE_1 * s + (r.height - ui.SPACE_1 * s - small.line_height) / 2 + small.ascent
	x, right := r.x + ui.CONTROL_INSET * s, r.x + r.width - ui.CONTROL_INSET * s
	if row.count > 0 {
		count := fmt.tprintf("%d", row.count)
		right -= ui.text_width(&small, count)
		if result := ui.draw_text(&small, &w.list, count, right, baseline, ink); result != .Ok {return result}
		right -= ui.SPACE_2 * s
	}
	return ui.draw_fading_text(&small, &w.list, row.label, x, baseline, ink, max(0, right - x))
}

status_panel_draw :: proc(app: ^App, w: ^Window) -> glyphs.Result {
	panel := status_panel_rect(app, w)
	if panel.width <= 0 || panel.height <= 0 {return .Ok}
	s := w.scale
	if render.push_layer(&w.list, panel) != .None {return .Ok}
	if !status_panel_in_rail(app, w) {
		radius := f32(app.settings.pane.corner_radius) * s
		ui.draw_rect(&w.list, {rect = panel, color = app.theme.tab_bar, radius = radius})
	} else {
		ui.draw_rect(&w.list, {rect = panel, color = app.theme.tab_bar})
		ui.draw_rect(&w.list, {rect = {panel.x, panel.y, panel.width, s}, color = app.theme.border})
	}
	rows, total := status_panel_rows(app, w)
	small := ui.text_styled(&w.ui_text, .Detail)
	strong := ui.text_styled(&w.ui_text, .Strong)
	header := STATUS_PANEL_HEADER * s
	if result := ui.draw_text(
		&strong,
		&w.list,
		"Activity",
		panel.x + ui.SPACE_3 * s,
		panel.y + (header - strong.line_height) / 2 + strong.ascent,
		app.theme.text,
	); result != .Ok {return result}
	view_icon: ui.Icon = app.settings.status.panel_view == .Comfy ? .View_Comfy : .View_Dense
	side_icon: ui.Icon = app.settings.status.panel_side == .Left ? .Layout_Left : .Layout_Right
	buttons := [?]struct {
		button: Status_Panel_Button,
		rect:   render.Rect,
		icon:   ui.Icon,
	} {
		{.View, status_panel_view_rect(app, w), view_icon},
		{.Side, status_panel_side_rect(app, w), side_icon},
	}
	for b in buttons {
		hover := f32(int(w.status.panel_button_hover == b.button))
		press := f32(int(ui.armed_is(w.status.panel_button_armed, b.button)))
		_ = ui.icon_button_draw(&w.list, app.theme, b.rect, b.icon, hover, press, s, w.pointer)
	}
	list := status_panel_list(app, w, panel)
	if render.push_layer(&w.list, list) != .None {return .Ok}
	if len(rows) == 0 {
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
	w.status.panel_scroll = clamp(w.status.panel_scroll, 0, max(0, total - list.height))
	dense := app.settings.status.panel_view == .Dense
	hovered, any_hovered := w.status.panel_hover.?
	for row, i in rows {
		r := status_panel_row_rect(w, list, row)
		if r.y + r.height < list.y || r.y > list.y + list.height {continue}
		result: glyphs.Result
		highlighted := any_hovered && hovered == i
		if row.report {
			box := status_panel_row_box(w, r, row)
			if ui.navigation_row_surface_draw(&w.list, app.theme, box, {hovered = highlighted}, s,
				w.pointer) != .None {return .Ok}
		}
		switch {
		case !row.report:
			result = status_panel_label_draw(app, w, r, row)
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
	rows: []Status_Panel_Row,
	x, y: f32,
) -> (
	index: int,
	rect: render.Rect,
) {
	list := status_panel_list(app, w, status_panel_rect(app, w))
	if !status_rect_contains(list, x, y) {return -1, {}}
	for row, i in rows {
		r := status_panel_row_rect(w, list, row)
		if row.report && status_rect_contains(r, x, y) {return i, r}
	}
	return -1, {}
}

// Who reported, what it says and exactly where, for rows too narrow or alike to tell apart.
status_panel_row_tooltip :: proc(app: ^App, w: ^Window, x, y: f32) -> string {
	rows, _ := status_panel_rows(app, w)
	index, rect := status_panel_hit(app, w, rows, x, y)
	if index < 0 {return ""}
	item := rows[index].item
	if term.program_status_finished(item.record.state) &&
	   status_rect_contains(status_panel_dismiss_rect(app, w, rect), x, y) {
		return "Dismiss"
	}
	name := status_item_name(app, item)
	who := name
	if item.record.app != "" && item.record.app != name {who = fmt.tprintf("%s · %s", item.record.app, name)}
	buffer: [8]u8
	state := ui.status_headline(status_mark(item.record), buffer[:])
	if item.record.message != "" {
		// Half the tooltip at most, so a long message never pushes the location out of it.
		message := tooltip_clip(item.record.message, TOOLTIP_LIMIT / 2)
		return fmt.tprintf("%s\n%s: %s\n%s", who, state, message, item.crumb)
	}
	return fmt.tprintf("%s\n%s\n%s", who, state, item.crumb)
}

status_panel_button_at :: proc(app: ^App, w: ^Window, x, y: f32) -> Status_Panel_Button {
	if status_rect_contains(status_panel_side_rect(app, w), x, y) {return .Side}
	return status_rect_contains(status_panel_view_rect(app, w), x, y) ? .View : .None
}

status_panel_contains :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	return status_rect_contains(status_panel_rect(app, w), x, y)
}

// Panel clicks open the pane a row came from; the panel takes every press inside it.
status_panel_button :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) -> bool {
	x, y := f32(e.x), f32(e.y)
	if !e.pressed || !status_panel_contains(app, w, x, y) {return false}
	gesture_swallow(w, e.button, .Status_Panel)
	if e.button != .Left {return true}
	if button := status_panel_button_at(app, w, x, y); button != .None {
		ui.armed_press(&w.status.panel_button_armed, button)
		return true
	}
	rows, _ := status_panel_rows(app, w)
	index, rect := status_panel_hit(app, w, rows, x, y)
	if index < 0 {return true}
	item := rows[index].item
	if term.program_status_finished(item.record.state) &&
	   status_rect_contains(status_panel_dismiss_rect(app, w, rect), x, y) {
		status_dismiss_item(app, item)
		w.dirty = true
		return true
	}
	status_open_item(app, w, item)
	return true
}

status_panel_wheel :: proc(app: ^App, w: ^Window, x, y, delta: f32) -> bool {
	if !status_panel_contains(app, w, x, y) {return false}
	step := f32(math.sign(delta)) * 2 * STATUS_ROW_HEIGHT * w.scale
	w.status.panel_scroll = max(0, w.status.panel_scroll - step)
	w.dirty = true
	return true
}
