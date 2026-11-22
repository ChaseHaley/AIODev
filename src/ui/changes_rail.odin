package ui

import "cosmos:render"
import "core:fmt"
import "core:math"

// The header row: the first row of the Agent changes pane, `HEIGHT_STANDARD` tall and as wide as the pane,
// with a hairline under it. A ghost summary button at the left names what the pane shows (source, turns,
// totals, file count) and opens the panel. At the right are the layout, fold, filter, select lines and
// wrap icon buttons, as small as the pane header's, followed by the files button. The row gives things
// up only when it runs out of room, one step at a time, measured with the text: nothing collapses on a
// fixed width. The ⋯ menu holds the buttons' actions once they have become one button.

// The view buttons of the row, left to right. Each is also the ⋯ menu row it becomes once the buttons are
// one, in the same order, so the row's width, placement, hit testing and drawing and the menu all follow
// this list: a new button is an entry here, its part, its rect in Row_Button_Names and its case in
// changes_row_button_entry.
Row_Button :: enum u8 {
	Layout,
	Fold,
	Filter,
	Select_Lines,
	Wrap,
}

@(private)
CHANGES_TOOLS_ROWS :: len(Row_Button)

// The part each button is hit as.
CHANGES_ROW_BUTTON_PARTS :: [Row_Button]Changes_Part {
	.Layout       = .Layout_Button,
	.Fold         = .Fold_Button,
	.Filter       = .Filter_Button,
	.Select_Lines = .Select_Lines_Button,
	.Wrap         = .Wrap_Button,
}

// The buttons' rects, by name and by button. Both views are the same memory, so a button added to the list
// needs its name here, which the assert below checks.
Row_Button_Names :: struct {
	layout_button, fold_button, filter_button, select_lines_button: render.Rect,
	wrap_button: render.Rect,
}

Row_Button_Rects :: struct #raw_union {
	using named: Row_Button_Names,
	by_button:   [Row_Button]render.Rect,
}

#assert(size_of(Row_Button_Names) == size_of([Row_Button]render.Rect))

// The button `part` stands for.
changes_row_button_of :: proc(part: Changes_Part) -> (button: Row_Button, ok: bool) {
	parts := CHANGES_ROW_BUTTON_PARTS
	for p, b in parts {
		if p == part {return b, true}
	}
	return
}

// What a button shows and does for the view: its icon, its ⋯ menu label and its tooltip, whether it works,
// and its looks. `lit` is the "on" look of a toggle that is set; `checked` puts a check on its menu row;
// `dot` marks a set filter; `warn` inks it as a warning; `popover` keeps it lit while the filter popover
// it opens is.
Row_Button_Entry :: struct {
	icon:                                     Icon,
	label, tooltip:                           string,
	enabled, lit, checked, dot, warn, popover: bool,
}

changes_row_button_entry :: proc(view: ^Changes_View, button: Row_Button) -> Row_Button_Entry {
	switch button {
	case .Layout:
		return {
			icon    = .Side_By_Side,
			label   = "Side-by-side",
			tooltip = view.side_by_side ? "Unified view" : "Side-by-side view",
			enabled = true,
			lit     = view.side_by_side,
			checked = view.side_by_side,
		}
	case .Fold:
		label := view.any_expanded ? "Collapse all files" : "Expand all files"
		// Folding needs files.
		return {
			icon = view.any_expanded ? .Collapse_All : .Expand_All,
			label = label,
			tooltip = label,
			enabled = len(view.files) > 0,
		}
	case .Filter:
		set := changes_filter_set(view)
		return {
			icon    = .Filter,
			label   = "Filter files…",
			tooltip = "Filter files",
			enabled = true,
			lit     = set,
			dot     = set,
			warn    = view.filter_invalid,
			popover = true,
		}
	case .Select_Lines:
		return {
			icon    = .Select_Lines,
			label   = "Select lines",
			tooltip = view.select_lines ? "Select text" : "Select lines",
			enabled = true,
			lit     = view.select_lines,
			checked = view.select_lines,
		}
	case .Wrap:
		return {
			icon    = .Wrap_Lines,
			label   = "Wrap lines",
			tooltip = view.wrap ? "Scroll long lines horizontally" : "Wrap long lines",
			enabled = true,
			lit     = view.wrap,
			checked = view.wrap,
		}
	}
	return {}
}

// The view button whose rect holds the point, shown or not enabled.
changes_row_button_at :: proc(g: Changes_Geometry, x, y: f32) -> (button: Row_Button, ok: bool) {
	for rect, b in g.by_button {
		if render.rect_contains(rect, x, y) {return b, true}
	}
	return
}

@(private = "file")
ROW_PAD_LEFT :: f32(4)
@(private = "file")
ROW_PAD_RIGHT :: f32(4)
@(private = "file")
ROW_SUMMARY_GAP :: f32(4)
@(private = "file")
ROW_BUTTON :: f32(22)
@(private = "file")
ROW_BUTTON_GAP :: f32(2)
@(private = "file")
ROW_FILES_MARGIN :: f32(8)
@(private = "file")
ROW_FILES_PAD :: f32(8)
@(private = "file")
ROW_FILES_GAP :: f32(6)
@(private = "file")
ROW_SUMMARY_PAD_LEFT :: f32(7)
@(private = "file")
ROW_SUMMARY_PAD_RIGHT :: f32(6)
@(private = "file")
ROW_DOT :: f32(8)
@(private = "file")
ROW_SEPARATOR_HEIGHT :: f32(14)
@(private = "file")
ROW_STEPS :: 5
@(private = "file")
ROW_FILTER_DOT :: f32(6)
@(private = "file")
TOOLS_ROW_HEIGHT :: HEIGHT_STANDARD

// What the row shows at a collapse step: the view buttons, the word "files", the totals and the agent
// name stay until their step, and the range gets short at the last one.
@(private = "file")
Row_Plan :: struct {
	buttons, word, totals, name, short: bool,
}

@(private = "file")
row_plan :: proc(steps: int, git: bool) -> Row_Plan {
	return {
		buttons = steps < 1,
		word    = steps < 2,
		totals  = steps < 3,
		name    = steps < 4 && !git,
		short   = steps >= 5,
	}
}

// The texts of the row for a plan, with the width each takes; the strings point into the caller's
// buffers. `range` is the turn range, or in a git scope the scope's name; `files` is the files button's
// label.
@(private = "file")
Row_Texts :: struct {
	plan:                                   Row_Plan,
	name, range, files:                     string,
	totals, live:                           bool,
	name_width, range_width, totals_width:  f32,
	files_width:                            f32,
}

// How many files the list holds: the files the filter hides count too.
@(private = "file")
files_count :: proc(view: ^Changes_View) -> int {
	return max(len(view.files), view.total_files)
}

@(private = "file")
row_totals_width :: proc(body: ^Text, view: ^Changes_View, scale: f32) -> f32 {
	plus_buf, minus_buf: [24]u8
	plus := fmt.bprintf(plus_buf[:], "+%d", view.shown_added)
	minus := fmt.bprintf(minus_buf[:], "−%d", view.shown_removed)
	return text_width(body, plus) + SPACE_1 * scale + text_width(body, minus)
}

@(private = "file")
row_texts :: proc(
	view: ^Changes_View, text: ^Text, plan: Row_Plan, scale: f32, range_buf, count_buf: []u8,
) -> (
	t: Row_Texts,
) {
	body := text_styled(text, .Body)
	strong := text_styled(text, .Strong)
	t.plan = plan
	turns := changes_scope_turns(view.scope)
	if plan.name && turns {
		t.name = clip_bytes(view.source_label, CHANGES_CLIP_BYTES)
		t.name_width = math.ceil(text_width(&strong, t.name))
	}
	if turns {
		t.range = plan.short ? changes_range_label_short(view, range_buf) : changes_range_label(view, range_buf)
		t.live = changes_live_index(view) >= 0 && view.first == view.last
	} else {
		labels := CHANGES_SCOPE_LABELS
		t.range = clip_bytes(view.source_label, CHANGES_CLIP_BYTES)
		if t.range == "" {t.range = labels[view.scope]}
		if plan.short {
			for r, i in t.range {
				if r == ' ' {
					t.range = t.range[:i]
					break
				}
			}
		}
	}
	t.range_width = math.ceil(text_width(&body, t.range))
	if t.live {t.range_width += (ICON_INDICATOR + SPACE_1) * scale}
	if plan.totals && (view.shown_added > 0 || view.shown_removed > 0) {
		t.totals = true
		t.totals_width = math.ceil(row_totals_width(&body, view, scale))
	}
	count := files_count(view)
	if plan.word {
		t.files = fmt.bprintf(count_buf, "%d %s", count, count == 1 ? "file" : "files")
	} else {
		t.files = fmt.bprintf(count_buf, "%d", count)
	}
	t.files_width = math.ceil(text_width(&body, t.files))
	return
}

// The summary's natural width: the dot, then each part behind a divider, then the chevron,
// inside the button's padding.
@(private = "file")
summary_width :: proc(t: Row_Texts, scale: f32) -> f32 {
	gap := SPACE_2 * scale
	width := (ROW_SUMMARY_PAD_LEFT + ROW_DOT + ICON_INDICATOR + ROW_SUMMARY_PAD_RIGHT) * scale
	width += 2 * gap + t.range_width
	if t.name_width > 0 {width += 2 * gap + scale + t.name_width}
	if t.totals {width += 2 * gap + scale + t.totals_width}
	return width
}

// The row's width at `steps`, the summary's part of it and the files button's: the paddings, the summary,
// the view buttons and the files button.
@(private = "file")
row_width :: proc(
	view: ^Changes_View, text: ^Text, steps: int, scale: f32, range_buf, count_buf: []u8,
) -> (
	width, summary, files: f32,
) {
	plan := row_plan(steps, !changes_scope_turns(view.scope))
	t := row_texts(view, text, plan, scale, range_buf, count_buf)
	summary = math.ceil(summary_width(t, scale))
	files = math.ceil((2 * ROW_FILES_PAD + ICON_BUTTON + ROW_FILES_GAP) * scale + t.files_width)
	buttons := plan.buttons ? len(Row_Button) : 1
	button := math.round(ROW_BUTTON * scale)
	width = (ROW_PAD_LEFT + ROW_SUMMARY_GAP + ROW_FILES_MARGIN + ROW_PAD_RIGHT) * scale + summary + files
	width += f32(buttons) * button + f32(buttons - 1) * ROW_BUTTON_GAP * scale
	return
}

// Places the header row's summary and buttons: the whole summary and every button while they fit, else the
// first collapse step that does. The room is the row's width; the summary sits at the left, the buttons at
// the right end, and the space between them stays empty.
@(private)
row_place :: proc(g: ^Changes_Geometry, view: ^Changes_View, text: ^Text) {
	s := g.scale
	row := g.row
	if row.height <= 0 || row.width <= 0 {return}
	most := row.width
	range_buf, count_buf: [RANGE_LABEL_BYTES]u8
	git := !changes_scope_turns(view.scope)
	steps := 0
	width, summary, files := row_width(view, text, steps, s, range_buf[:], count_buf[:])
	for steps < ROW_STEPS && width > most {
		steps += 1
		if steps == 4 && git {steps += 1}
		width, summary, files = row_width(view, text, steps, s, range_buf[:], count_buf[:])
	}
	g.row_steps = steps
	if width > most {summary = max(0, summary - (width - most))}
	button := math.round(ROW_BUTTON * s)
	height := min(math.round(HEIGHT_COMPACT * s), row.height)
	top := row.y + math.round((row.height - height) / 2)
	g.summary = {row.x + ROW_PAD_LEFT * s, top, summary, height}
	g.files_button = {row.x + row.width - ROW_PAD_RIGHT * s - files, top, files, height}
	top = row.y + math.round((row.height - button) / 2)
	cursor := g.files_button.x - ROW_FILES_MARGIN * s - button
	gap := ROW_BUTTON_GAP * s
	if steps < 1 {
		for i := len(Row_Button) - 1; i >= 0; i -= 1 {
			g.by_button[Row_Button(i)] = {cursor, top, button, button}
			cursor -= gap + button
		}
	} else {
		g.tools_button = {cursor, top, button, button}
	}
	if g.tools_button.width > 0 {tools_place(g, view, text)}
}

// The ⋯ menu under the tools button, right-aligned to it and kept inside the pane.
@(private = "file")
tools_place :: proc(g: ^Changes_Geometry, view: ^Changes_View, text: ^Text) {
	s := g.scale
	body := text_styled(text, .Body)
	widest: f32
	for row in 0 ..< CHANGES_TOOLS_ROWS {
		label := changes_row_button_entry(view, Row_Button(row)).label
		widest = max(widest, text_width(&body, label))
	}
	pad := OVERLAY_PADDING * s
	width := math.ceil(widest + 2 * SPACE_3 * s + (ICON_INDICATOR + SPACE_2) * s + 2 * pad)
	row := math.round(TOOLS_ROW_HEIGHT * s)
	area := g.area
	width = min(width, max(0, area.width - 2 * SPACE_2 * s))
	right := g.tools_button.x + g.tools_button.width
	left := area.x + SPACE_2 * s
	x := clamp(right - width, left, max(left, area.x + area.width - SPACE_2 * s - width))
	y := g.row.y + g.row.height + SPACE_1 * s
	g.tools_menu = {x, y, width, f32(CHANGES_TOOLS_ROWS) * row + 2 * pad}
	for i in 0 ..< CHANGES_TOOLS_ROWS {
		g.tools_rows[i] = {x + pad, y + pad + f32(i) * row, width - 2 * pad, row}
	}
}

// The colour of the source's dot: the agent's tint as the turn strip gives it, the accent for All agents,
// the muted colour for a git scope.
@(private)
source_tint :: proc(theme: Theme, agent: int) -> render.Color {
	if agent < 0 {return theme.muted}
	palette := CHANGES_AGENT_PALETTE
	return theme.palette[palette[agent % len(palette)]]
}

@(private = "file")
summary_dot_color :: proc(theme: Theme, view: ^Changes_View) -> render.Color {
	switch {
	case !changes_scope_turns(view.scope):
		return theme.muted
	case view.scope == .Repository:
		return theme.accent
	}
	return source_tint(theme, view.source_agent)
}

// A divider between the summary's parts, centred on the summary.
@(private = "file")
summary_separator_draw :: proc(list: ^render.Draw_List, theme: Theme, sum: render.Rect, x, scale: f32) {
	height := math.round(ROW_SEPARATOR_HEIGHT * scale)
	y := sum.y + math.round((sum.height - height) / 2)
	draw_rect(list, {rect = {x, y, max(1, math.round(scale)), height}, color = theme.border})
}

// The summary's content: the dot, then the name, the range (behind the working spinner while a turn is
// live) and the totals, each after a divider and clipped to the room the summary has.
@(private = "file")
summary_draw :: proc(
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	g: Changes_Geometry,
	view: ^Changes_View,
	phase: f32,
) -> (
	status: render.Build_Status,
	spinning: bool,
) {
	s := g.scale
	sum := g.summary
	range_buf, count_buf: [RANGE_LABEL_BYTES]u8
	plan := row_plan(g.row_steps, !changes_scope_turns(view.scope))
	t := row_texts(view, text, plan, s, range_buf[:], count_buf[:])
	body := text_styled(text, .Body)
	strong := text_styled(text, .Strong)
	gap := SPACE_2 * s
	chevron := render.Rect {
		sum.x + sum.width - ROW_SUMMARY_PAD_RIGHT * s - ICON_INDICATOR * s, sum.y, ICON_INDICATOR * s, sum.height,
	}
	icon_draw(list, .Chevron_Down, chevron, theme.muted, ICON_INDICATOR, s)
	x := sum.x + ROW_SUMMARY_PAD_LEFT * s
	limit := chevron.x - gap
	dot := render.Rect{x, sum.y + (sum.height - ROW_DOT * s) / 2, ROW_DOT * s, ROW_DOT * s}
	draw_rect(list, {rect = dot, color = summary_dot_color(theme, view), radius = dot.width / 2})
	x += dot.width + gap
	first := true
	// One part: a divider unless it is the first, then its text in `width`, then the gap to the next.
	if t.name != "" {
		room := min(t.name_width, limit - x)
		if status = draw_fading_text(
			&strong, list, t.name, x, baseline_in(sum.y, sum.height, &strong), theme.text, room,
		); status != .Ok {return}
		x += t.name_width + gap
		first = false
	}
	if !first {
		summary_separator_draw(list, theme, sum, x, s)
		x += s + gap
	}
	start := x
	if t.live {
		mark := render.Rect{x, sum.y, ICON_INDICATOR * s, sum.height}
		if x + mark.width <= limit {
			if status = status_glyph_draw(list, text, theme, mark, WORKING_MARK, phase, s); status != .Ok {return}
			spinning = true
		}
		x += (ICON_INDICATOR + SPACE_1) * s
	}
	room := min(t.range_width - (x - start), limit - x)
	if status = draw_fading_text(
		&body, list, t.range, x, baseline_in(sum.y, sum.height, &body), theme.text, room,
	); status != .Ok {return}
	x = start + t.range_width + gap
	if t.totals && x + s + gap + t.totals_width <= limit {
		summary_separator_draw(list, theme, sum, x, s)
		x += s + gap
		baseline := baseline_in(sum.y, sum.height, &body)
		right := x + t.totals_width
		if _, status = stats_draw(list, &body, theme, right, baseline, view.shown_added, view.shown_removed, s);
		   status != .Ok {return}
		x += t.totals_width + gap
	}
	return
}

// The 16 DIP box every icon of the row is drawn in: centred vertically on the row and snapped to whole
// pixels, so the icons of the 22 DIP buttons and of the files button line up at every scale. The caller
// sets `x`.
@(private = "file")
row_icon_box :: proc(row: render.Rect, scale: f32) -> render.Rect {
	extent := ICON_BUTTON * scale
	return {0, math.round(row.y + (row.height - extent) / 2), extent, extent}
}

// One 22 DIP header-style icon button: the shared button surface with the muted icon and the raised hover.
// `lit` is the "on" look, the pressed fill under the surface and the full-strength ink, never an accent;
// `dot` marks a set filter at the top right.
@(private = "file")
row_button_draw :: proc(
	list: ^render.Draw_List,
	theme: Theme,
	row, rect: render.Rect,
	icon: Icon,
	part: Changes_Part,
	lit, disabled, dot: bool,
	ink_override: Maybe(render.Color),
	state: ^Changes_State,
	scale: f32,
	pointer: [2]f32,
) -> render.Error {
	if rect.width <= 0 {return .None}
	hover, press := changes_lit(state, {part, 0, 0})
	if lit {draw_rect(list, {rect = rect, color = theme.pressed, radius = RADIUS_BUTTON * scale})}
	b := Button {
		rect     = rect,
		hover    = hover,
		press    = press,
		disabled = disabled,
	}
	face, ink, err := button_draw(list, theme, b, scale, pointer)
	if err != .None {return err}
	if lit && !disabled {ink = theme.text}
	if colour, set := ink_override.?; set && !disabled {ink = colour}
	// The icon sits on the row's centre line, as the files button's does, however the rects round.
	box := row_icon_box(row, scale)
	box.x = face.x + (face.width - box.width) / 2
	box.y += face.y - rect.y
	icon_draw(list, icon, box, ink, ICON_BUTTON, scale)
	if dot {
		size := ROW_FILTER_DOT * scale
		mark := render.Rect{face.x + face.width - 2 * scale - size, face.y + 2 * scale, size, size}
		draw_rect(list, {rect = mark, color = theme.accent, radius = size / 2})
	}
	return .None
}

// The files button: the file icon and the count ("N files", or just "N" once the word is given up), a
// ghost button like the summary that stays pressed while its list is open and is disabled without files.
@(private = "file")
files_button_draw :: proc(
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	g: Changes_Geometry,
	view: ^Changes_View,
	state: ^Changes_State,
	scale: f32,
	pointer: [2]f32,
) -> render.Build_Status {
	rect := g.files_button
	if rect.width <= 0 {return .Ok}
	enabled := changes_files_listed(view)
	hover, press := changes_lit(state, {.Files_Button, 0, 0})
	if state.files_open {draw_rect(list, {rect = rect, color = theme.pressed, radius = RADIUS_CONTROL * scale})}
	b := Button {
		rect     = rect,
		hover    = hover,
		press    = press,
		radius   = RADIUS_CONTROL,
		surface  = .Flat,
		disabled = !enabled,
	}
	face, ink, err := button_draw(list, theme, b, scale, pointer)
	if err != .None {return .Ok}
	if state.files_open && enabled {ink = theme.text}
	range_buf, count_buf: [RANGE_LABEL_BYTES]u8
	plan := row_plan(g.row_steps, !changes_scope_turns(view.scope))
	t := row_texts(view, text, plan, scale, range_buf[:], count_buf[:])
	body := text_styled(text, .Body)
	// The icon is in the same box as the icons of the buttons beside it; the label's capitals are centred on
	// that box's centre line.
	box := row_icon_box(g.row, scale)
	box.x = face.x + ROW_FILES_PAD * scale
	icon_draw(list, .Files, box, ink, ICON_BUTTON, scale)
	x := box.x + box.width + ROW_FILES_GAP * scale
	return draw_fading_text(
		&body, list, t.files, x, baseline_caps(box.y, box.height, &body), ink,
		face.x + face.width - ROW_FILES_PAD * scale - x,
	)
}

// Whether a filter text is set, valid or not.
@(private)
changes_filter_set :: proc(view: ^Changes_View) -> bool {
	return view.filter_active || view.filter_invalid
}

// Draws the header row: the summary, and the icon buttons (or the one ⋯ button), then the files button.
// `spinning` reports a working spinner in the summary.
@(private)
row_draw :: proc(
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	g: Changes_Geometry,
	view: ^Changes_View,
	state: ^Changes_State,
	pointer: [2]f32,
	phase: f32,
) -> (
	status: render.Build_Status,
	spinning: bool,
) {
	if g.row.width <= 0 || g.row.height <= 0 {return .Ok, false}
	s := g.scale
	scope, opened := clip_scope_open(list, g.area)
	if !opened {return .Ok, false}
	defer clip_scope_close(list, scope)
	hover, press := changes_lit(state, {.Summary, 0, 0})
	if state.panel_open {draw_rect(list, {rect = g.summary, color = theme.pressed, radius = RADIUS_CONTROL * s})}
	b := Button {
		rect    = g.summary,
		hover   = hover,
		press   = press,
		radius  = RADIUS_CONTROL,
		surface = .Flat,
	}
	if _, _, err := button_draw(list, theme, b, s, pointer); err != .None {return .Ok, false}
	filter_set := changes_filter_set(view)
	filter_ink: Maybe(render.Color)
	if view.filter_invalid {filter_ink = theme.warning}
	err := render.Error.None
	parts := CHANGES_ROW_BUTTON_PARTS
	for button in Row_Button {
		e := changes_row_button_entry(view, button)
		ink: Maybe(render.Color)
		if e.warn {ink = theme.warning}
		lit := e.lit || (e.popover && state.filter_open)
		err = row_button_draw(
			list, theme, g.row, g.by_button[button], e.icon, parts[button], lit, !e.enabled, e.dot, ink, state, s,
			pointer,
		)
		if err != .None {break}
	}
	if err == .None {
		err = row_button_draw(
			list, theme, g.row, g.tools_button, .More, .Tools_Button, state.tools_open || state.filter_open, false,
			filter_set, filter_ink, state, s, pointer,
		)
	}
	if err != .None {return .Ok, false}
	if status = files_button_draw(list, text, theme, g, view, state, s, pointer); status != .Ok {return}
	return summary_draw(list, text, theme, g, view, phase)
}

// The open ⋯ menu, with a row for every view button.
@(private)
tools_menu_draw :: proc(
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	g: Changes_Geometry,
	view: ^Changes_View,
	state: ^Changes_State,
	pointer: [2]f32,
) -> render.Build_Status {
	if !state.tools_open || g.tools_menu.width <= 0 {return .Ok}
	s := g.scale
	scope, opened := clip_scope_open(list, g.area)
	if !opened {return .Ok}
	defer clip_scope_close(list, scope)
	if panel_draw(list, popover_panel(g.tools_menu, s), theme) != .None {return .Ok}
	body := text_styled(text, .Body)
	for row in 0 ..< CHANGES_TOOLS_ROWS {
		rect := g.tools_rows[row]
		entry := changes_row_button_entry(view, Row_Button(row))
		enabled := entry.enabled
		hit := Changes_Hit{.Tools_Row, row, 0}
		hovered, pressed := enabled && state.hover == hit, enabled && state.press == hit && state.hover == hit
		on := entry.checked || entry.dot
		if on || hovered || pressed {
			nav := Navigation_Row {
				selected = on,
				hovered  = hovered,
				pressed  = pressed,
			}
			if navigation_row_surface_draw(list, theme, rect, nav, s, pointer) != .None {return .Ok}
		}
		ink := theme.text
		if !enabled {
			ink = theme.muted
			ink.a *= DISABLED_ALPHA
		}
		x := rect.x + SPACE_3 * s
		check := ICON_INDICATOR * s
		right := rect.x + rect.width - SPACE_3 * s
		if status := draw_fading_text(
			&body, list, entry.label, x, baseline_in(rect.y, rect.height, &body), ink,
			right - check - SPACE_2 * s - x,
		); status != .Ok {return status}
		if entry.checked {
			mark := render.Rect{right - check, rect.y, check, rect.height}
			icon_draw(list, .Check, mark, theme.accent, ICON_INDICATOR, s)
		}
		// A set filter shows the dot its ⋯ button wears, in the check's place.
		if entry.dot {
			size := ROW_FILTER_DOT * s
			dot := render.Rect{right - (check + size) / 2, rect.y + (rect.height - size) / 2, size, size}
			draw_rect(list, {rect = dot, color = theme.accent, radius = size / 2})
		}
	}
	return .Ok
}
