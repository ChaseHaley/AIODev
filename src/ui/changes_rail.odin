package ui

import "aio:render"
import "core:fmt"
import "core:math"

// The rail: a pill centred in the band at the top of the Agent changes pane. Its summary names what the pane
// shows (source, turns, totals, file count) and opens the panel, as does the arrow at its end; between them
// sit the layout, fold and filter circles. The rail gives things up only when it runs out of room, one step
// at a time, measured with the text: nothing collapses on a fixed width. The ⋯ menu holds the circles'
// actions once they have become one circle.

@(private)
CHANGES_TOOLS_ROWS :: 3
@(private = "file")
RAIL_HEIGHT :: f32(34)
@(private = "file")
RAIL_PAD :: f32(4)
@(private = "file")
RAIL_GAP :: f32(4)
@(private = "file")
RAIL_CIRCLE :: f32(26)
@(private = "file")
RAIL_SUMMARY_HEIGHT :: f32(28)
@(private = "file")
RAIL_SUMMARY_PAD_LEFT :: f32(10)
@(private = "file")
RAIL_SUMMARY_PAD_RIGHT :: f32(8)
@(private = "file")
RAIL_DOT :: f32(8)
@(private = "file")
RAIL_DIVIDER_HEIGHT :: f32(16)
@(private = "file")
RAIL_SEPARATOR_HEIGHT :: f32(14)
@(private = "file")
RAIL_ARROW_MARGIN :: f32(2)
@(private = "file")
RAIL_STEPS :: 5
@(private = "file")
RAIL_FILTER_DOT :: f32(6)
@(private = "file")
TOOLS_ROW_HEIGHT :: HEIGHT_STANDARD

// What the rail's summary shows at a collapse step: the circles, the file count, the totals and the agent
// name stay until their step, and the range gets short at the last one.
@(private = "file")
Rail_Plan :: struct {
	circles, count, totals, name, short: bool,
}

@(private = "file")
rail_plan :: proc(steps: int, git: bool) -> Rail_Plan {
	return {
		circles = steps < 1,
		count   = steps < 2,
		totals  = steps < 3,
		name    = steps < 4 && !git,
		short   = steps >= 5,
	}
}

// The texts of the summary for a plan, with the width each takes; the strings point into the caller's
// buffers. `range` is the turn range, or in a git scope the scope's name.
@(private = "file")
Rail_Texts :: struct {
	plan:                                   Rail_Plan,
	name, range, count:                     string,
	totals, live:                           bool,
	name_width, range_width, totals_width:  f32,
	count_width:                            f32,
}

@(private = "file")
rail_totals_width :: proc(body: ^Text, view: ^Changes_View, scale: f32) -> f32 {
	plus_buf, minus_buf: [24]u8
	plus := fmt.bprintf(plus_buf[:], "+%d", view.shown_added)
	minus := fmt.bprintf(minus_buf[:], "−%d", view.shown_removed)
	return text_width(body, plus) + SPACE_1 * scale + text_width(body, minus)
}

@(private = "file")
rail_texts :: proc(
	view: ^Changes_View, text: ^Text, plan: Rail_Plan, scale: f32, range_buf, count_buf: []u8,
) -> (
	t: Rail_Texts,
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
		t.totals_width = math.ceil(rail_totals_width(&body, view, scale))
	}
	if plan.count {
		count := len(view.files)
		t.count = fmt.bprintf(count_buf, "%d %s", count, count == 1 ? "file" : "files")
		t.count_width = math.ceil(text_width(&body, t.count))
	}
	return
}

// The summary's natural width: the dot, then each part behind a divider, inside the pill's padding.
@(private = "file")
rail_summary_width :: proc(t: Rail_Texts, scale: f32) -> f32 {
	gap := SPACE_2 * scale
	width := (RAIL_SUMMARY_PAD_LEFT + RAIL_DOT + RAIL_SUMMARY_PAD_RIGHT) * scale
	width += gap + t.range_width
	if t.name_width > 0 {width += 2 * gap + scale + t.name_width}
	if t.totals {width += 2 * gap + scale + t.totals_width}
	if t.count != "" {width += 2 * gap + scale + t.count_width}
	return width
}

// The rail's width at `steps`, and the summary's part of it.
@(private = "file")
rail_width :: proc(
	view: ^Changes_View, text: ^Text, steps: int, scale: f32, range_buf, count_buf: []u8,
) -> (
	width, summary: f32,
) {
	plan := rail_plan(steps, !changes_scope_turns(view.scope))
	t := rail_texts(view, text, plan, scale, range_buf, count_buf)
	summary = math.ceil(rail_summary_width(t, scale))
	circles := plan.circles ? 3 : 1
	width = 2 * RAIL_PAD * scale + summary + 2 * RAIL_GAP * scale + math.round(scale)
	width += f32(circles) * (RAIL_CIRCLE + RAIL_GAP) * scale + RAIL_ARROW_MARGIN * scale + RAIL_CIRCLE * scale
	return
}

// Places the band's rail: the whole summary and circles while they fit, else the first collapse step that
// does. `lane` is the overview strip's width, which the rail is centred clear of.
@(private)
rail_place :: proc(g: ^Changes_Geometry, view: ^Changes_View, text: ^Text, lane: f32) {
	s := g.scale
	band := g.band
	height := min(math.round(RAIL_HEIGHT * s), band.height)
	if height <= 0 {return}
	margin := SPACE_2 * s
	most := max(0, band.width - lane - 2 * margin)
	range_buf, count_buf: [RANGE_LABEL_BYTES]u8
	git := !changes_scope_turns(view.scope)
	steps := 0
	width, summary := rail_width(view, text, steps, s, range_buf[:], count_buf[:])
	for steps < RAIL_STEPS && width > most {
		steps += 1
		if steps == 4 && git {steps += 1}
		width, summary = rail_width(view, text, steps, s, range_buf[:], count_buf[:])
	}
	g.rail_steps = steps
	if width > most {
		summary = max(0, summary - (width - most))
		width = most
	}
	if width <= 0 {return}
	centre := band.x + (band.width - lane) / 2
	x := math.round(centre - width / 2)
	y := math.round(band.y + (band.height - height) / 2)
	g.rail = {x, y, width, height}
	pad, gap, circle := RAIL_PAD * s, RAIL_GAP * s, math.round(RAIL_CIRCLE * s)
	inside := math.round((height - circle) / 2)
	sum_height := min(math.round(RAIL_SUMMARY_HEIGHT * s), height)
	g.rail_summary = {x + pad, y + math.round((height - sum_height) / 2), summary, sum_height}
	cursor := x + pad + summary + gap
	rule := max(1, math.round(s))
	divider := min(math.round(RAIL_DIVIDER_HEIGHT * s), height)
	g.rail_divider = {cursor, y + math.round((height - divider) / 2), rule, divider}
	cursor += rule + gap
	if steps < 1 {
		g.layout_button = {cursor, y + inside, circle, circle}
		cursor += circle + gap
		g.fold_button = {cursor, y + inside, circle, circle}
		cursor += circle + gap
		g.filter_button = {cursor, y + inside, circle, circle}
		cursor += circle + gap
	} else {
		g.tools_button = {cursor, y + inside, circle, circle}
		cursor += circle + gap
	}
	cursor += RAIL_ARROW_MARGIN * s
	g.panel_button = {cursor, y + inside, circle, circle}
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
	y := g.rail.y + g.rail.height + SPACE_1 * s
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
rail_dot_color :: proc(theme: Theme, view: ^Changes_View) -> render.Color {
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
rail_separator_draw :: proc(list: ^render.Draw_List, theme: Theme, sum: render.Rect, x, scale: f32) {
	height := math.round(RAIL_SEPARATOR_HEIGHT * scale)
	y := sum.y + math.round((sum.height - height) / 2)
	draw_rect(list, {rect = {x, y, max(1, math.round(scale)), height}, color = theme.border})
}

// The summary's content: the dot, then the name, the range (behind the working spinner while a turn is
// live), the totals and the file count, each after a divider and clipped to the room the summary has.
@(private = "file")
rail_summary_draw :: proc(
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
	sum := g.rail_summary
	range_buf, count_buf: [RANGE_LABEL_BYTES]u8
	plan := rail_plan(g.rail_steps, !changes_scope_turns(view.scope))
	t := rail_texts(view, text, plan, s, range_buf[:], count_buf[:])
	body := text_styled(text, .Body)
	strong := text_styled(text, .Strong)
	gap := SPACE_2 * s
	x := sum.x + RAIL_SUMMARY_PAD_LEFT * s
	limit := sum.x + sum.width - RAIL_SUMMARY_PAD_RIGHT * s
	dot := render.Rect{x, sum.y + (sum.height - RAIL_DOT * s) / 2, RAIL_DOT * s, RAIL_DOT * s}
	draw_rect(list, {rect = dot, color = rail_dot_color(theme, view), radius = dot.width / 2})
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
		rail_separator_draw(list, theme, sum, x, s)
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
		rail_separator_draw(list, theme, sum, x, s)
		x += s + gap
		baseline := baseline_in(sum.y, sum.height, &body)
		right := x + t.totals_width
		if _, status = stats_draw(list, &body, theme, right, baseline, view.shown_added, view.shown_removed, s);
		   status != .Ok {return}
		x += t.totals_width + gap
	}
	if t.count != "" && x < limit {
		rail_separator_draw(list, theme, sum, x, s)
		x += s + gap
		status = draw_fading_text(
			&body, list, t.count, x, baseline_in(sum.y, sum.height, &body), theme.muted, min(t.count_width, limit - x),
		)
	}
	return
}

// One round button: its rest fill, then the shared button surface. `lit` is the selected look (selection
// fill, accent ink and a focus outline); `dot` marks a set filter at the top right.
@(private = "file")
circle_draw :: proc(
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
	radius := rect.width / 2
	if !lit {draw_rect(list, {rect = rect, color = theme.hover, radius = radius})}
	b := Button {
		rect     = rect,
		hover    = hover,
		press    = press,
		radius   = RAIL_CIRCLE / 2,
		surface  = .Flat,
		selected = lit,
		disabled = disabled,
	}
	face, ink, err := button_draw(list, theme, b, scale, pointer)
	if err != .None {return err}
	switch {
	case disabled:
		ink = theme.muted
		ink.a *= DISABLED_ALPHA
	case lit:
		ink = theme.accent
	}
	if colour, set := ink_override.?; set && !disabled {ink = colour}
	if lit {draw_rect(list, {rect = rect, color = theme.focus, radius = radius, stroke = scale})}
	icon_draw(list, icon, face, ink, ICON_BUTTON, scale)
	if dot {
		size := RAIL_FILTER_DOT * scale
		mark := render.Rect{rect.x + rect.width - 3 * scale - size, rect.y + 3 * scale, size, size}
		ring := render.Rect{mark.x - 1.5 * scale, mark.y - 1.5 * scale, size + 3 * scale, size + 3 * scale}
		draw_rect(list, {rect = ring, color = theme.surface, radius = ring.width / 2})
		draw_rect(list, {rect = mark, color = theme.accent, radius = size / 2})
	}
	return .None
}

// Whether a filter text is set, valid or not.
@(private)
changes_filter_set :: proc(view: ^Changes_View) -> bool {
	return view.filter_active || view.filter_invalid
}

// Draws the rail: its pill, the summary, and the circles or the one ⋯ circle, then the arrow. `spinning`
// reports a working spinner in the summary.
@(private)
rail_draw :: proc(
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
	if g.rail.width <= 0 || g.rail.height <= 0 {return .Ok, false}
	s := g.scale
	scope, opened := clip_scope_open(list, g.area)
	if !opened {return .Ok, false}
	defer clip_scope_close(list, scope)
	pill := Panel {
		rect     = g.rail,
		radius   = g.rail.height / 2,
		scale    = s,
		shadow_y = 3,
		softness = 10,
		border   = .Stroked,
	}
	if panel_draw(list, pill, theme) != .None {return .Ok, false}
	hover, press := changes_lit(state, {.Rail_Summary, 0, 0})
	b := Button {
		rect    = g.rail_summary,
		hover   = hover,
		press   = press,
		radius  = RAIL_SUMMARY_HEIGHT / 2,
		surface = .Flat,
	}
	if _, _, err := button_draw(list, theme, b, s, pointer); err != .None {return .Ok, false}
	draw_rect(list, {rect = g.rail_divider, color = theme.border})
	filter_set := changes_filter_set(view)
	filter_ink: Maybe(render.Color)
	if view.filter_invalid {filter_ink = theme.warning}
	enabled := len(view.files) > 0
	err := circle_draw(
		list, theme, g.layout_button, .Side_By_Side, .Layout_Button, view.side_by_side, false, false, nil, state, s,
		pointer,
	)
	if err == .None {
		err = circle_draw(
			list, theme, g.fold_button, view.any_expanded ? .Collapse_All : .Expand_All, .Fold_Button, false, !enabled,
			false, nil, state, s, pointer,
		)
	}
	if err == .None {
		err = circle_draw(
			list, theme, g.filter_button, .Filter, .Filter_Button, state.filter_open || filter_set, false, filter_set,
			filter_ink, state, s, pointer,
		)
	}
	if err == .None {
		err = circle_draw(
			list, theme, g.tools_button, .More, .Tools_Button, state.tools_open || state.filter_open, false,
			filter_set, filter_ink, state, s, pointer,
		)
	}
	if err == .None {
		err = circle_draw(
			list, theme, g.panel_button, .Chevron_Down, .Panel_Button, state.panel_open, false, false, nil, state, s,
			pointer,
		)
	}
	if err != .None {return .Ok, false}
	return rail_summary_draw(list, text, theme, g, view, phase)
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
