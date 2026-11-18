package ui

import "aio:render"
import "aio:settings"
import "core:fmt"
import "core:math"

// The floating toolbar over a selection (Delete, Comment, Label) and the label menu under it, the way a
// press on the code text maps to a byte, and the colour a note marks its lines with. The pane places the
// toolbar after every layout (changes_selection_place), so hit tests, the draw and the harness read one
// answer.

// The diff width from which the toolbar's buttons carry words beside their icons.
@(private = "file")
CHANGES_BAR_WORDS :: f32(440)
// How far the toolbar sits from the selection's first line, or its last when it goes below.
@(private = "file")
CHANGES_BAR_LIFT :: f32(6)
// How much of the selection's first line the toolbar centres over.
@(private = "file")
CHANGES_BAR_SPAN :: f32(200)
@(private = "file")
CHANGES_MENU_WIDTH :: f32(224)
@(private = "file")
CHANGES_SWATCH :: f32(12)
// The labels that have an Alt+N key: the first nine.
@(private = "file")
CHANGES_MENU_KEYS :: 9

// Where the toolbar and the label menu are, in window pixels; empty while there is no toolbar. The menu's
// rows are the labels `first` on, `shown` of them, one under another in `rows`.
Changes_Selection_Bar :: struct {
	bar, delete, comment, label, divider: render.Rect,
	// Whether the buttons carry words beside their icons.
	words:                                bool,
	menu, edit, rule, rows:               render.Rect,
	row_height:                           f32,
	first, shown, labels:                 int,
}

// The colour a note marks its lines with: its label's, the error colour for a deletion, the accent for a
// comment.
@(require_results)
changes_note_color :: proc(theme: Theme, c: Changes_Comment_View) -> render.Color {
	switch c.kind {
	case .Comment:
		return theme.accent
	case .Delete:
		return theme.error
	case .Label:
		return quick_label_color(theme, c.label_colour)
	}
	return theme.accent
}

// How many labels the turns.quick_labels value `value` holds.
@(require_results)
changes_label_count :: proc(value: string) -> (count: int) {
	cursor := settings.quick_labels_scan(value)
	for _ in settings.quick_labels_next(&cursor) {count += 1}
	return
}

// Label `index` of `value`, as the setting lists them; false past the last.
@(require_results)
changes_label_at :: proc(value: string, index: int) -> (label: settings.Quick_Label, ok: bool) {
	if index < 0 {return}
	cursor := settings.quick_labels_scan(value)
	at := 0
	for next in settings.quick_labels_next(&cursor) {
		if at == index {return next, true}
		at += 1
	}
	return
}

// The text of flat line `line` of `file`; false when there is no such line.
@(private, require_results)
line_text :: proc(view: ^Changes_View, file, line: int) -> (text: string, ok: bool) {
	if file < 0 || file >= len(view.files) {return}
	return changes_line_text(view.files[file], line)
}

// What a press at `x` lands on in flat line `line` of `file`: the byte of the line's text whose boundary is
// nearest, and the cell the line is drawn in there, which is the half of a side-by-side row that `x` is in.
// Only the line under the pointer is measured. False when the line has no row.
@(require_results)
changes_text_point :: proc(
	g: Changes_Geometry, view: ^Changes_View, state: ^Changes_State, mono: ^Text, file, line: int, x: f32,
) -> (
	offset: int,
	cell: render.Rect,
	ok: bool,
) {
	column: Code_Column
	cell, column, ok = changes_line_code(g, view, state, mono, file, line, x)
	if !ok {return}
	text, _ := line_text(view, file, line)
	return code_offset_at(mono, text, column.width, x - column.text_x, column.scroll), cell, true
}

// Places the toolbar over the selection and, while the label menu is open, the menu under it. The toolbar
// sits above the selection's first line, centred over its start, or below its last line when there is no
// room above, and it is empty while that part of the selection is scrolled out of view, while a drag is
// in progress and while a note is being written. Needs the rows of the latest changes_layout.
changes_selection_place :: proc(
	g: Changes_Geometry, view: ^Changes_View, state: ^Changes_State, text, mono: ^Text,
) -> (
	bar: Changes_Selection_Bar,
) {
	s := view.selection
	rows := &state.rows
	if !s.active || view.editing >= 0 || view.selecting || view.notice != .None || !rows.valid {return}
	if s.file < 0 || s.file >= len(view.files) || g.diff.width <= 0 || g.diff.height <= 0 {return}
	first_row := min(line_row(rows, s.file, s.first), line_row(rows, s.file, s.last))
	last_row := rows.pairs.selection_row
	if first_row < 0 || last_row < 0 {return}
	top, top_ok := row_top(rows, view, s.file, first_row)
	bottom, bottom_ok := row_top(rows, view, s.file, last_row)
	// A context line side by side is in both halves; the toolbar centres over the one the selection is in.
	half := f32(-1)
	if rows.pairs.side_by_side {
		left, right, _ := row_halves(diff_band(g))
		half = s.half == .Right ? right.x : left.x
	}
	_, column, found := changes_line_code(g, view, state, mono, s.file, s.first, half)
	if !top_ok || !bottom_ok || !found {return}
	scale := g.scale
	origin := g.diff.y - f32(state.diff_scroll)
	first_y, last_y := origin + f32(top), origin + f32(bottom + rows.line)
	visible, limit := g.diff.y, g.diff.y + g.diff.height
	if sticky, header := changes_sticky_header(state, view, g); sticky >= 0 {
		visible = max(visible, header.y + header.height)
	}
	if last_y <= visible || first_y >= limit {return}

	// Over the first line's selected start, as much of it as the toolbar is wide.
	line, _ := line_text(view, s.file, s.first)
	start, span := column.text_x, column.width
	if s.partial {
		stop := s.first == s.last ? s.last_offset : len(line)
		begin := code_x_of(mono, line, column.width, s.first_offset, column.scroll)
		start += begin
		span = code_x_of(mono, line, column.width, stop, column.scroll) - begin
	}
	centre := start + min(span, CHANGES_BAR_SPAN * scale) / 2

	body := text_styled(text, .Body)
	pad, inset, gap := OVERLAY_PADDING * scale, CONTROL_INSET * scale, SPACE_1 * scale
	icon, chevron := ICON_BUTTON * scale, ICON_INDICATOR * scale
	bar.words = g.diff.width >= CHANGES_BAR_WORDS * scale
	word :: proc(t: ^Text, s: string, on: bool, gap: f32) -> f32 {return on ? gap + text_width(t, s) : 0}
	delete_width := math.round(2 * inset + icon + word(&body, "Delete", bar.words, gap))
	comment_width := math.round(2 * inset + icon + word(&body, "Comment", bar.words, gap))
	label_width := math.round(2 * inset + icon + word(&body, "Label", bar.words, gap) + gap + chevron)
	divider_width := SPACE_2 * scale
	height := math.round(HEIGHT_COMPACT * scale)
	width := 2 * pad + delete_width + comment_width + divider_width + label_width
	margin := SPACE_2 * scale
	low := g.diff.x + margin
	x := clamp(math.round(centre - width / 2), low, max(low, g.diff.x + g.diff.width - margin - width))
	lift := CHANGES_BAR_LIFT * scale
	y := first_y - lift - (height + 2 * pad)
	if y < visible {y = last_y + lift}
	y = math.round(clamp(y, visible, max(visible, limit - (height + 2 * pad))))
	bar.bar = {x, y, width, height + 2 * pad}
	cursor := x + pad
	bar.delete = {cursor, y + pad, delete_width, height}
	cursor += delete_width
	bar.comment = {cursor, y + pad, comment_width, height}
	cursor += comment_width
	bar.divider = {cursor, y + pad, divider_width, height}
	cursor += divider_width
	bar.label = {cursor, y + pad, label_width, height}
	if view.label_menu {menu_place(&bar, g, view, text, visible, limit)}
	return
}

// The label menu under the toolbar, aligned to its Label button, or above it when the room below is too
// small and the room above is not. Too many labels for the room show a run of them around the one the keys
// are on.
@(private = "file")
menu_place :: proc(
	bar: ^Changes_Selection_Bar, g: Changes_Geometry, view: ^Changes_View, text: ^Text, visible, limit: f32,
) {
	scale := g.scale
	body := text_styled(text, .Body)
	detail := text_styled(text, .Detail)
	pad, row, band := OVERLAY_PADDING * scale, math.round(HEIGHT_STANDARD * scale), math.round(SPACE_1 * scale)
	bar.labels = 0
	widest: f32
	cursor := settings.quick_labels_scan(view.quick_labels)
	for label in settings.quick_labels_next(&cursor) {
		bar.labels += 1
		widest = max(widest, text_width(&body, label.name))
	}
	keys := keycap_width(&detail, "Alt+9", scale)
	width := 2 * pad + 2 * SPACE_3 * scale + (CHANGES_SWATCH + SPACE_2) * scale + widest
	width += SPACE_2 * scale + keys
	margin := SPACE_2 * scale
	width = min(math.ceil(max(width, CHANGES_MENU_WIDTH * scale)), max(0, g.diff.width - 2 * margin))

	gap := SPACE_1 * scale
	below := bar.bar.y + bar.bar.height + gap
	room_below, room_above := limit - below, bar.bar.y - gap - visible
	extra := 2 * pad + row
	if bar.labels > 0 {extra += band}
	full := extra + f32(bar.labels) * row
	flip := full > room_below && room_above > room_below
	room := flip ? room_above : room_below
	bar.shown = bar.labels
	if full > room {bar.shown = clamp(int((room - extra) / row), min(bar.labels, 1), bar.labels)}
	height := extra + f32(bar.shown) * row
	y := flip ? bar.bar.y - gap - height : below
	y = math.round(clamp(y, g.diff.y, max(g.diff.y, limit - height)))
	low := g.diff.x + margin
	x := math.round(clamp(bar.label.x, low, max(low, g.diff.x + g.diff.width - margin - width)))
	bar.first = clamp(view.label_row - bar.shown / 2, 0, max(0, bar.labels - bar.shown))
	bar.row_height = row
	bar.menu = {x, y, width, height}
	bar.rows = {x + pad, y + pad, width - 2 * pad, f32(bar.shown) * row}
	end := bar.rows.y + bar.rows.height
	if bar.labels > 0 {
		rule := max(1, math.round(scale))
		bar.rule = {x + pad, end + math.floor((band - rule) / 2), width - 2 * pad, rule}
		end += band
	}
	bar.edit = {x + pad, end, width - 2 * pad, row}
}

// The rect of the label menu's `shown`th visible row.
changes_label_row_rect :: proc(bar: Changes_Selection_Bar, shown: int) -> render.Rect {
	return {bar.rows.x, bar.rows.y + f32(shown) * bar.row_height, bar.rows.width, bar.row_height}
}

// What lies at the point on the label menu and the toolbar; the menu is above the toolbar.
@(private)
selection_bar_hit :: proc(g: Changes_Geometry, x, y: f32) -> Changes_Hit {
	bar := g.selection_bar
	if bar.bar.width <= 0 {return {}}
	if bar.menu.width > 0 && render.rect_contains(bar.menu, x, y) {
		if render.rect_contains(bar.edit, x, y) {return {.Label_Edit, 0, 0}}
		if render.rect_contains(bar.rows, x, y) && bar.shown > 0 {
			shown := clamp(int((y - bar.rows.y) / bar.row_height), 0, bar.shown - 1)
			return {.Label_Row, bar.first + shown, 0}
		}
		return {.Label_Menu, -1, 0}
	}
	switch {
	case render.rect_contains(bar.delete, x, y):
		return {.Toolbar_Delete, 0, 0}
	case render.rect_contains(bar.comment, x, y):
		return {.Toolbar_Comment, 0, 0}
	case render.rect_contains(bar.label, x, y):
		return {.Toolbar_Label, 0, 0}
	case render.rect_contains(bar.bar, x, y):
		return {.Toolbar, -1, 0}
	}
	return {}
}

// One toolbar button: its surface, its icon, then its word and a chevron when it has them.
@(private = "file")
bar_button_draw :: proc(
	list: ^render.Draw_List,
	body: ^Text,
	theme: Theme,
	state: ^Changes_State,
	pointer: [2]f32,
	rect: render.Rect,
	part: Changes_Part,
	icon: Icon,
	icon_ink: render.Color,
	label: string,
	words, chevron, lit: bool,
	scale: f32,
) -> render.Build_Status {
	hover, press := changes_lit(state, {part, 0, 0})
	if lit {draw_rect(list, {rect = rect, color = theme.pressed, radius = RADIUS_CONTROL * scale})}
	b := Button {
		rect    = rect,
		hover   = hover,
		press   = press,
		radius  = RADIUS_CONTROL,
		surface = .Flat,
	}
	face, ink, err := button_draw(list, theme, b, scale, pointer)
	if err != .None {return .Ok}
	if lit {ink = theme.text}
	x := face.x + CONTROL_INSET * scale
	icon_draw(list, icon, {x, face.y, ICON_BUTTON * scale, face.height}, icon_ink, ICON_BUTTON, scale)
	x += ICON_BUTTON * scale
	if words {
		x += SPACE_1 * scale
		baseline := baseline_in(face.y, face.height, body)
		if r := draw_text(body, list, label, x, baseline, ink); r != .Ok {return r}
		x += text_width(body, label)
	}
	if chevron {
		x += SPACE_1 * scale
		icon_draw(
			list, .Chevron_Down, {x, face.y, ICON_INDICATOR * scale, face.height}, theme.muted, ICON_INDICATOR,
			scale,
		)
	}
	return .Ok
}

// A menu row's surface: the pointer's hover and press, or the lighter fill of the row the keys are on.
@(private = "file")
menu_row_surface_draw :: proc(
	list: ^render.Draw_List, theme: Theme, state: ^Changes_State, rect: render.Rect, hit: Changes_Hit,
	keyed: bool, scale: f32, pointer: [2]f32,
) -> render.Error {
	hovered := state.hover == hit
	pressed := hovered && state.press == hit
	if hovered || pressed {
		row := Navigation_Row {
			hovered = hovered,
			pressed = pressed,
		}
		return navigation_row_surface_draw(list, theme, rect, row, scale, pointer)
	}
	if keyed {
		tile := render.Rect{rect.x, rect.y + scale, rect.width, max(0, rect.height - 2 * scale)}
		draw_rect(list, {rect = tile, color = theme.hover, radius = RADIUS_CONTROL * scale})
	}
	return .None
}

// Draws the toolbar and the label menu in a layer of their own over the diff, above the pinned file header,
// so no text shows through them.
@(private)
selection_bar_draw :: proc(
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	g: Changes_Geometry,
	view: ^Changes_View,
	state: ^Changes_State,
	pointer: [2]f32,
) -> render.Build_Status {
	bar := g.selection_bar
	if bar.bar.width <= 0 || render.push_layer(list, g.diff) != .None {return .Ok}
	s := g.scale
	if panel_draw(list, popover_panel(bar.bar, s), theme) != .None {return .Ok}
	body := text_styled(text, .Body)
	if r := bar_button_draw(
		list, &body, theme, state, pointer, bar.delete, .Toolbar_Delete, .Delete_Key, theme.error, "Delete",
		bar.words, false, false, s,
	); r != .Ok {return r}
	if r := bar_button_draw(
		list, &body, theme, state, pointer, bar.comment, .Toolbar_Comment, .Comment, theme.muted, "Comment",
		bar.words, false, false, s,
	); r != .Ok {return r}
	height := math.round(ICON_BUTTON * s)
	rule := max(1, math.round(s))
	draw_rect(
		list,
		{
			rect = {
				math.round(bar.divider.x + (bar.divider.width - rule) / 2),
				math.round(bar.divider.y + (bar.divider.height - height) / 2),
				rule,
				height,
			},
			color = theme.border,
		},
	)
	if r := bar_button_draw(
		list, &body, theme, state, pointer, bar.label, .Toolbar_Label, .Bolt, theme.warning, "Label", bar.words,
		true, view.label_menu, s,
	); r != .Ok {return r}
	if bar.menu.width <= 0 {return .Ok}
	return label_menu_draw(list, text, theme, g, view, state, pointer)
}

@(private = "file")
label_menu_draw :: proc(
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	g: Changes_Geometry,
	view: ^Changes_View,
	state: ^Changes_State,
	pointer: [2]f32,
) -> render.Build_Status {
	bar := g.selection_bar
	s := g.scale
	if panel_draw(list, popover_panel(bar.menu, s), theme) != .None {return .Ok}
	body := text_styled(text, .Body)
	detail := text_styled(text, .Detail)
	cursor := settings.quick_labels_scan(view.quick_labels)
	for _ in 0 ..< bar.first {
		if _, more := settings.quick_labels_next(&cursor); !more {break}
	}
	swatch, inset := CHANGES_SWATCH * s, SPACE_3 * s
	for k in 0 ..< bar.shown {
		label, more := settings.quick_labels_next(&cursor)
		if !more {break}
		index := bar.first + k
		rect := changes_label_row_rect(bar, k)
		hit := Changes_Hit{.Label_Row, index, 0}
		if menu_row_surface_draw(list, theme, state, rect, hit, index == view.label_row, s, pointer) != .None {
			return .Ok
		}
		mark := render.Rect{rect.x + inset, rect.y + (rect.height - swatch) / 2, swatch, swatch}
		draw_rect(list, {rect = mark, color = quick_label_color(theme, label.colour), radius = RADIUS_CONTROL * s})
		x := mark.x + swatch + SPACE_2 * s
		right := rect.x + rect.width - inset
		if index < CHANGES_MENU_KEYS {
			buf: [8]u8
			key := fmt.bprintf(buf[:], "Alt+%d", index + 1)
			width := keycap_width(&detail, key, s)
			if r := keycap_draw(list, &detail, theme, key, right - width, rect.y, rect.height, s); r != .Ok {
				return r
			}
			right -= width + SPACE_2 * s
		}
		baseline := baseline_in(rect.y, rect.height, &body)
		if r := draw_fading_text(&body, list, label.name, x, baseline, theme.text, right - x); r != .Ok {
			return r
		}
	}
	if bar.labels > 0 {draw_rect(list, {rect = bar.rule, color = theme.border})}
	hit := Changes_Hit{.Label_Edit, 0, 0}
	if menu_row_surface_draw(list, theme, state, bar.edit, hit, false, s, pointer) != .None {return .Ok}
	icon := render.Rect{bar.edit.x + inset, bar.edit.y, swatch, bar.edit.height}
	icon_draw(list, .Pencil, icon, theme.muted, ICON_INDICATOR, s)
	x := icon.x + swatch + SPACE_2 * s
	baseline := baseline_in(bar.edit.y, bar.edit.height, &body)
	return draw_fading_text(
		&body, list, "Edit labels…", x, baseline, theme.muted, bar.edit.x + bar.edit.width - inset - x,
	)
}
