package ui

import "aio:render"
import "core:fmt"
import "core:math"

// The header row: the first row of the Agent changes pane, `HEIGHT_STANDARD` tall and as wide as the pane,
// with a hairline under it. A ghost summary button at the left names what the pane shows (source, turns,
// totals, file count) and opens the panel, as does the chevron button at the right end; beside that sit the
// layout, fold and filter icon buttons, as small as the pane header's. The row gives things up only when it
// runs out of room, one step at a time, measured with the text: nothing collapses on a fixed width. The ⋯
// menu holds the buttons' actions once they have become one button.

@(private)
CHANGES_TOOLS_ROWS :: 3
@(private = "file")
ROW_PAD_LEFT :: f32(4)
@(private = "file")
ROW_PAD_RIGHT :: f32(5)
@(private = "file")
ROW_SUMMARY_GAP :: f32(4)
@(private = "file")
ROW_BUTTON :: f32(22)
@(private = "file")
ROW_BUTTON_GAP :: f32(2)
@(private = "file")
ROW_DIVIDER_MARGIN :: f32(4)
@(private = "file")
ROW_DIVIDER_HEIGHT :: f32(14)
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

// What the row shows at a collapse step: the three buttons, the file count, the totals and the agent
// name stay until their step, and the range gets short at the last one.
@(private = "file")
Row_Plan :: struct {
	buttons, count, totals, name, short: bool,
}

@(private = "file")
row_plan :: proc(steps: int, git: bool) -> Row_Plan {
	return {
		buttons = steps < 1,
		count   = steps < 2,
		totals  = steps < 3,
		name    = steps < 4 && !git,
		short   = steps >= 5,
	}
}

// The texts of the summary for a plan, with the width each takes; the strings point into the caller's
// buffers. `range` is the turn range, or in a git scope the scope's name.
@(private = "file")
Row_Texts :: struct {
	plan:                                   Row_Plan,
	name, range, count:                     string,
	totals, live:                           bool,
	name_width, range_width, totals_width:  f32,
	count_width:                            f32,
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
	if plan.count {
		count := len(view.files)
		t.count = fmt.bprintf(count_buf, "%d %s", count, count == 1 ? "file" : "files")
		t.count_width = math.ceil(text_width(&body, t.count))
	}
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
	if t.count != "" {width += 2 * gap + scale + t.count_width}
	return width
}

// The row's width at `steps`, and the summary's part of it: both paddings, the buttons and the divider.
@(private = "file")
row_width :: proc(
	view: ^Changes_View, text: ^Text, steps: int, scale: f32, range_buf, count_buf: []u8,
) -> (
	width, summary: f32,
) {
	plan := row_plan(steps, !changes_scope_turns(view.scope))
	t := row_texts(view, text, plan, scale, range_buf, count_buf)
	summary = math.ceil(summary_width(t, scale))
	buttons := plan.buttons ? 3 : 1
	button := math.round(ROW_BUTTON * scale)
	width = (ROW_PAD_LEFT + ROW_SUMMARY_GAP + ROW_PAD_RIGHT + 2 * ROW_DIVIDER_MARGIN) * scale + summary
	width += math.round(scale) + f32(buttons) * button + f32(buttons - 1) * ROW_BUTTON_GAP * scale + button
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
	width, summary := row_width(view, text, steps, s, range_buf[:], count_buf[:])
	for steps < ROW_STEPS && width > most {
		steps += 1
		if steps == 4 && git {steps += 1}
		width, summary = row_width(view, text, steps, s, range_buf[:], count_buf[:])
	}
	g.row_steps = steps
	if width > most {summary = max(0, summary - (width - most))}
	button := math.round(ROW_BUTTON * s)
	rule := max(1, math.round(s))
	sum_height := min(math.round(HEIGHT_COMPACT * s), row.height)
	sum_top := row.y + math.round((row.height - sum_height) / 2)
	g.summary = {row.x + ROW_PAD_LEFT * s, sum_top, summary, sum_height}
	top := row.y + math.round((row.height - button) / 2)
	cursor := row.x + row.width - ROW_PAD_RIGHT * s - button
	g.panel_button = {cursor, top, button, button}
	divider := min(math.round(ROW_DIVIDER_HEIGHT * s), row.height)
	cursor -= ROW_DIVIDER_MARGIN * s + rule
	g.buttons_divider = {cursor, row.y + math.round((row.height - divider) / 2), rule, divider}
	cursor -= ROW_DIVIDER_MARGIN * s + button
	gap := ROW_BUTTON_GAP * s
	if steps < 1 {
		g.filter_button = {cursor, top, button, button}
		cursor -= gap + button
		g.fold_button = {cursor, top, button, button}
		cursor -= gap + button
		g.layout_button = {cursor, top, button, button}
	} else {
		g.tools_button = {cursor, top, button, button}
	}
	if g.tools_button.width > 0 {tools_place(g, view, text)}
}

// The ⋯ menu's label for row `row`.
@(private)
tools_row_label :: proc(view: ^Changes_View, row: int) -> string {
	switch row {
	case 0:
		return "Side-by-side"
	case 1:
		return view.any_expanded ? "Collapse all files" : "Expand all files"
	case 2:
		return "Filter files…"
	}
	return ""
}

// Folding needs files; the other rows always work.
@(private)
tools_row_enabled :: proc(view: ^Changes_View, row: int) -> bool {
	return row != 1 || len(view.files) > 0
}

// The ⋯ menu under the tools button, right-aligned to it and kept inside the pane.
@(private = "file")
tools_place :: proc(g: ^Changes_Geometry, view: ^Changes_View, text: ^Text) {
	s := g.scale
	body := text_styled(text, .Body)
	widest: f32
	for row in 0 ..< CHANGES_TOOLS_ROWS {widest = max(widest, text_width(&body, tools_row_label(view, row)))}
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
// live), the totals and the file count, each after a divider and clipped to the room the summary has.
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
	if t.count != "" && x < limit {
		summary_separator_draw(list, theme, sum, x, s)
		x += s + gap
		status = draw_fading_text(
			&body, list, t.count, x, baseline_in(sum.y, sum.height, &body), theme.muted, min(t.count_width, limit - x),
		)
	}
	return
}

// One 22 DIP header-style icon button: the shared button surface with the muted icon and the raised hover.
// `lit` is the "on" look, the pressed fill under the surface and the full-strength ink, never an accent;
// `dot` marks a set filter at the top right.
@(private = "file")
row_button_draw :: proc(
	list: ^render.Draw_List,
	theme: Theme,
	rect: render.Rect,
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
	icon_draw(list, icon, face, ink, ICON_BUTTON, scale)
	if dot {
		size := ROW_FILTER_DOT * scale
		mark := render.Rect{face.x + face.width - 2 * scale - size, face.y + 2 * scale, size, size}
		draw_rect(list, {rect = mark, color = theme.accent, radius = size / 2})
	}
	return .None
}

// Whether a filter text is set, valid or not.
@(private)
changes_filter_set :: proc(view: ^Changes_View) -> bool {
	return view.filter_active || view.filter_invalid
}

// Draws the header row: the summary, and the icon buttons (or the one ⋯ button), the divider and the
// chevron button. `spinning` reports a working spinner in the summary.
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
	b := Button {
		rect    = g.summary,
		hover   = hover,
		press   = press,
		radius  = RADIUS_CONTROL,
		surface = .Flat,
	}
	if _, _, err := button_draw(list, theme, b, s, pointer); err != .None {return .Ok, false}
	draw_rect(list, {rect = g.buttons_divider, color = theme.border})
	filter_set := changes_filter_set(view)
	filter_ink: Maybe(render.Color)
	if view.filter_invalid {filter_ink = theme.warning}
	enabled := len(view.files) > 0
	err := row_button_draw(
		list, theme, g.layout_button, .Side_By_Side, .Layout_Button, view.side_by_side, false, false, nil, state, s,
		pointer,
	)
	if err == .None {
		err = row_button_draw(
			list, theme, g.fold_button, view.any_expanded ? .Collapse_All : .Expand_All, .Fold_Button, false, !enabled,
			false, nil, state, s, pointer,
		)
	}
	if err == .None {
		err = row_button_draw(
			list, theme, g.filter_button, .Filter, .Filter_Button, state.filter_open || filter_set, false, filter_set,
			filter_ink, state, s, pointer,
		)
	}
	if err == .None {
		err = row_button_draw(
			list, theme, g.tools_button, .More, .Tools_Button, state.tools_open || state.filter_open, false,
			filter_set, filter_ink, state, s, pointer,
		)
	}
	if err == .None {
		err = row_button_draw(
			list, theme, g.panel_button, .Chevron_Down, .Panel_Button, state.panel_open, false, false, nil, state, s,
			pointer,
		)
	}
	if err != .None {return .Ok, false}
	return summary_draw(list, text, theme, g, view, phase)
}

// The open ⋯ menu: Side-by-side (checked while on), the fold row and Filter files….
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
		enabled := tools_row_enabled(view, row)
		hit := Changes_Hit{.Tools_Row, row, 0}
		hovered, pressed := enabled && state.hover == hit, enabled && state.press == hit && state.hover == hit
		if hovered || pressed {
			nav := Navigation_Row {
				hovered = hovered,
				pressed = pressed,
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
			&body, list, tools_row_label(view, row), x, baseline_in(rect.y, rect.height, &body), ink,
			right - check - SPACE_2 * s - x,
		); status != .Ok {return status}
		if row == 0 && view.side_by_side {
			mark := render.Rect{right - check, rect.y, check, rect.height}
			icon_draw(list, .Check, mark, theme.accent, ICON_INDICATOR, s)
		}
	}
	return .Ok
}
