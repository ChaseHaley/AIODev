package ui

import "aio:render"
import "core:fmt"
import "core:math"

// The turn strip and what goes with it: the step buttons around the strip (one bar per turn, oldest at the
// left), the range label that opens the turn list, the turn list, and the diff filter's bar and popover.
// changes_panel.odin lays the strip out in the panel.

// Terminal palette entries the All agents scope tints each agent's bars with, in agent order.
CHANGES_AGENT_PALETTE :: [6]int{4, 5, 6, 2, 3, 1}

// The most bars the strip shows; older and newer turns past them are counted in its "+N" markers.
CHANGES_STRIP_MAX_BARS :: 10

@(private = "file")
CHANGES_AGENT_ALPHA :: f32(0.7)
@(private = "file")
STRIP_BAR_WIDTH :: f32(8)
@(private = "file")
STRIP_BAR_GAP :: f32(3)
@(private = "file")
STRIP_BAR_MIN :: f32(6)
@(private = "file")
STRIP_BAR_MAX :: f32(20)
@(private = "file")
STRIP_BETWEEN_MAX :: f32(8)
// The room under the bars, and between a selected run and its outline.
@(private = "file")
STRIP_INSET :: f32(2)
@(private = "file")
TURN_LIST_WIDTH :: f32(320)
@(private = "file")
TURN_LIST_ROWS :: 10
@(private)
RANGE_LABEL_BYTES :: 64
@(private)
RANGE_TITLE_BYTES :: 96
@(private)
WORKING_MARK :: Status_Mark{glyph = .Working, progress = -1}
@(private = "file")
FILTER_POPOVER_WIDTH :: f32(360)
@(private = "file")
FILTER_PLACEHOLDER :: "Show files matching…"
@(private = "file")
FILTER_HINT :: "Space-separated regular expressions; !term hides; @ for saved"
@(private = "file")
FILTER_SAVE_HINT :: "Ctrl+S saves these terms as a filter"
@(private = "file")
FILTER_NAME_PLACEHOLDER :: "Name this filter"
@(private = "file")
FILTER_NAME_HINT :: "Enter saves, Escape cancels"
@(private = "file")
FILTER_MANAGE_LABEL :: "Edit filters…"
@(private = "file")
FILTER_PICK_ROWS :: 6
@(private = "file")
FILTER_CLEAR_LABEL :: "Clear"

// The range label's text. Turns are numbered from the oldest, which is 1.
changes_range_label :: proc(view: ^Changes_View, buf: []u8) -> string {
	count := len(view.turns)
	if count == 0 {return "No turns"}
	if view.first < 0 || view.last < view.first || view.first >= count {return "No turn selected"}
	last := min(view.last, count - 1)
	if view.first == last {
		if view.turns[last].live {return "Working…"}
		return fmt.bprintf(buf, "Turn %d", count - last)
	}
	return fmt.bprintf(buf, "Turns %d–%d", count - last, count - view.first)
}

// The range label for a row short of room: "T7" and "T7–11".
changes_range_label_short :: proc(view: ^Changes_View, buf: []u8) -> string {
	count := len(view.turns)
	if count == 0 {return "No turns"}
	if view.first < 0 || view.last < view.first || view.first >= count {return "No turn selected"}
	last := min(view.last, count - 1)
	if view.first == last {return fmt.bprintf(buf, "T%d", count - last)}
	return fmt.bprintf(buf, "T%d–%d", count - last, count - view.first)
}

// The line under the turn strip: the title of the one selected turn, or for a run "N turns · first–last",
// the oldest and newest turn's detail; "" without a selection.
changes_range_title :: proc(view: ^Changes_View, buf: []u8) -> string {
	count := len(view.turns)
	if count == 0 || view.first < 0 || view.last < view.first || view.first >= count {return ""}
	last := min(view.last, count - 1)
	if view.first == last {return turn_title(&view.turns[last])}
	run := last - view.first + 1
	oldest := clip_bytes(view.turns[last].detail, 24)
	newest := clip_bytes(view.turns[view.first].detail, 24)
	if oldest == "" || newest == "" {return fmt.bprintf(buf, "%d turns", run)}
	return fmt.bprintf(buf, "%d turns · %s–%s", run, oldest, newest)
}

// Whether ‹ (toward older turns) and › (toward newer turns) can step: not past either end.
changes_step_enabled :: proc(view: ^Changes_View) -> (back, forward: bool) {
	count := len(view.turns)
	if count == 0 {return false, false}
	if view.first < 0 || view.first >= count {return true, true}
	return max(view.first, view.last) < count - 1, view.first > 0
}

// Whether the file list has anything to list. It keeps the files the filter hides, so it opens while
// the diff has any file, shown or not.
@(private)
changes_files_listed :: proc(view: ^Changes_View) -> bool {
	return len(view.files) > 0 || view.hidden_count > 0
}

// The first live turn's row, or -1.
@(private)
changes_live_index :: proc(view: ^Changes_View) -> int {
	for &turn, i in view.turns {
		if turn.live {return i}
	}
	return -1
}

@(private = "file")
turn_title :: proc(turn: ^Changes_Turn) -> string {
	title := clip_bytes(turn.title, CHANGES_CLIP_BYTES)
	if title == "" {title = turn.between ? "Changes between turns" : "Agent turn"}
	return title
}

// The tooltip of turn `index`'s bar: "<title> · <detail> · +A −R · N files", led by "Working…" for a
// live turn.
changes_turn_tooltip :: proc(view: ^Changes_View, index: int, allocator := context.allocator) -> string {
	if index < 0 || index >= len(view.turns) {return ""}
	turn := &view.turns[index]
	title := turn_title(turn)
	noun := turn.files == 1 ? "file" : "files"
	detail := clip_bytes(turn.detail, CHANGES_CLIP_BYTES)
	if turn.live {
		return fmt.aprintf(
			"Working… · %s · +%d −%d · %d %s", title, turn.added, turn.removed, turn.files, noun,
			allocator = allocator,
		)
	}
	if detail == "" {
		return fmt.aprintf(
			"%s · +%d −%d · %d %s", title, turn.added, turn.removed, turn.files, noun, allocator = allocator,
		)
	}
	return fmt.aprintf(
		"%s · %s · +%d −%d · %d %s", title, detail, turn.added, turn.removed, turn.files, noun,
		allocator = allocator,
	)
}

@(private = "file")
strip_metrics :: proc(scale: f32) -> (bar, pitch: f32) {
	bar = math.round(STRIP_BAR_WIDTH * scale)
	return bar, bar + math.round(STRIP_BAR_GAP * scale)
}

@(private = "file")
toolbar_take :: proc(x: ^f32, right, width, top, height, gap: f32) -> render.Rect {
	w := min(width, max(0, right - x^))
	if w <= 0 {return {}}
	r := render.Rect{x^, top, w, height}
	x^ += w + gap
	return r
}

@(private = "file")
range_label_width :: proc(view: ^Changes_View, body: ^Text, scale: f32) -> f32 {
	buf: [RANGE_LABEL_BYTES]u8
	width := text_width(body, changes_range_label(view, buf[:]))
	width += 2 * CONTROL_INSET * scale + (SPACE_1 + ICON_INDICATOR) * scale
	if changes_live_index(view) >= 0 {width += (ICON_INDICATOR + SPACE_1) * scale}
	return math.ceil(width)
}

// Lays out a turn scope's strip row from `left` to `right`: ‹, the strip with as many bars as fit (at most
// CHANGES_STRIP_MAX_BARS; bars never shrink), ›, and the range label. A side that hides turns at the
// strip's `offset` gets a slot for its "+N" marker, and the bars are fitted again in what is left; fewer
// bars can only hide more, so a side never loses its slot and the fit settles within a few passes.
@(private)
strip_place :: proc(
	g: ^Changes_Geometry, view: ^Changes_View, body: ^Text, left, right, top, control: f32, offset: int,
) {
	s := g.scale
	near := SPACE_1 * s
	count := len(view.turns)
	label := range_label_width(view, body, s)
	bar, pitch := strip_metrics(s)
	room := right - left - 2 * control - label - 3 * near
	g.strip_room = room
	first := strip_fit(room, bar, pitch, count)
	g.strip_bars = first
	marker: f32
	if g.strip_bars < count {
		small := text_styled(body, .Detail)
		buf: [24]u8
		marker = math.ceil(text_width(&small, fmt.bprintf(buf[:], "+%d", count)) + 2 * SPACE_1 * s)
	}
	older, newer: bool
	for _ in 0 ..< 3 {
		if g.strip_bars >= count {break}
		shift := clamp(offset, 0, count - g.strip_bars)
		now_older, now_newer := older || shift > 0, newer || count - g.strip_bars - shift > 0
		if now_older == older && now_newer == newer {break}
		older, newer = now_older, now_newer
		slots := f32(int(older) + int(newer)) * (marker + near)
		// A strip that had room for a bar keeps one beside its markers: an empty strip could not show the
		// selection. What it takes past `right` comes off the range label.
		g.strip_bars = max(min(1, first), strip_fit(room - slots, bar, pitch, count))
	}
	x := left
	g.step_back = toolbar_take(&x, right, control, top, control, near)
	// A kept bar and its markers may run past `right`; without a bar nothing does.
	reach := g.strip_bars > 0 ? max(right, x + 2 * (marker + near) + f32(g.strip_bars) * pitch) : right
	if older {g.strip_older = toolbar_take(&x, reach, marker, top, control, near)}
	if g.strip_bars > 0 {
		width := f32(g.strip_bars) * pitch - (pitch - bar)
		g.strip = toolbar_take(&x, reach, width, top, control, near)
	}
	if newer {g.strip_newer = toolbar_take(&x, reach, marker, top, control, near)}
	g.step_forward = toolbar_take(&x, right, control, top, control, near)
	g.range_label = toolbar_take(&x, right, label, top, control, SPACE_2 * s)
}

// How many bars fit in `room`, at most CHANGES_STRIP_MAX_BARS and the turn count.
@(private = "file")
strip_fit :: proc(room, bar, pitch: f32, count: int) -> int {
	return clamp(int((room + pitch - bar) / pitch), 0, min(CHANGES_STRIP_MAX_BARS, count))
}

// The turns the strip can't show: older ones scrolled off its left, newer ones off its right.
changes_strip_hidden :: proc(
	g: Changes_Geometry, state: ^Changes_State, view: ^Changes_View,
) -> (
	older, newer: int,
) {
	offset := strip_offset(g, state, view)
	return offset, max(0, len(view.turns) - g.strip_bars - offset)
}

// The "+N" marker of the older (left) or newer (right) side as drawn; empty when that side hides no turn.
changes_strip_marker_rect :: proc(
	g: Changes_Geometry, state: ^Changes_State, view: ^Changes_View, newer: bool,
) -> render.Rect {
	older_count, newer_count := changes_strip_hidden(g, state, view)
	if newer {return newer_count > 0 ? g.strip_newer : {}}
	return older_count > 0 ? g.strip_older : {}
}

// Places the turn list under the range label, inside the pane.
@(private)
turn_list_place :: proc(g: ^Changes_Geometry, view: ^Changes_View) {
	count := len(view.turns)
	if count == 0 || g.range_label.width <= 0 || g.turn_row <= 0 {return}
	s := g.scale
	pad := SPACE_2 * s
	area := g.area
	width := min(math.round(TURN_LIST_WIDTH * s), max(0, area.width - 2 * pad))
	x := clamp(g.range_label.x, area.x + pad, max(area.x + pad, area.x + area.width - pad - width))
	y := g.range_label.y + g.range_label.height + SPACE_1 * s
	rows := f32(min(count, TURN_LIST_ROWS))
	height := min(rows * g.turn_row + 2 * OVERLAY_PADDING * s, max(0, area.y + area.height - pad - y))
	if width <= 0 || height <= 0 {return}
	g.turn_list = {x, y, width, height}
}

// The scrolling rows inside the turn list.
@(private = "file")
turn_list_rows :: proc(g: Changes_Geometry) -> render.Rect {
	pad := OVERLAY_PADDING * g.scale
	r := g.turn_list
	return {r.x + pad, r.y + pad, max(0, r.width - 2 * pad), max(0, r.height - 2 * pad)}
}

@(private)
turn_list_limit :: proc(g: Changes_Geometry, view: ^Changes_View) -> int {
	return max(0, len(view.turns) * int(g.turn_row) - int(turn_list_rows(g).height))
}

// The turn list row at `y`, or -1 on the list's padding.
@(private)
turn_list_row_at :: proc(g: Changes_Geometry, state: ^Changes_State, view: ^Changes_View, y: f32) -> int {
	rows := turn_list_rows(g)
	if g.turn_row <= 0 || y < rows.y || y >= rows.y + rows.height {return -1}
	row := int((y - rows.y + f32(state.turn_list_scroll)) / g.turn_row)
	return row < len(view.turns) ? row : -1
}

// The turn list's own scrollbar in `bar_state`'s look; `visible` is false when the rows fit.
changes_turn_list_scrollbar :: proc(
	state: ^Changes_State, g: Changes_Geometry, view: ^Changes_View, bar_state := Scrollbar_State.Collapsed,
) -> (bar: Scrollbar, visible: bool) {
	rows := turn_list_rows(g)
	extent := Scroll_Extent {
		total   = len(view.turns) * int(g.turn_row),
		visible = int(rows.height),
		offset  = state.turn_list_scroll,
	}
	return scrollbar_layout(rows, extent, bar_state, g.scale)
}

// One page of a held track press toward (x, y) on the turn list's scrollbar; see scrollbar_page.
changes_turn_list_page :: proc(
	state: ^Changes_State, g: Changes_Geometry, view: ^Changes_View, x, y: f32, side: Scroll_Side,
) -> Scroll_Page {
	bar, visible := changes_turn_list_scrollbar(state, g, view)
	if !visible {return .Off_Track}
	offset, result := scrollbar_page(bar, x, y, side)
	if result == .Paged {state.turn_list_scroll = offset}
	return result
}

// Scrolls the turn list by `delta` pixels, positive toward older turns; true when it moved.
changes_scroll_turn_list :: proc(
	state: ^Changes_State, g: Changes_Geometry, view: ^Changes_View, delta: int,
) -> bool {
	before := state.turn_list_scroll
	state.turn_list_scroll = clamp(before + delta, 0, turn_list_limit(g, view))
	return state.turn_list_scroll != before
}

// Scrolls the turn list just far enough to show row `index` whole; true when it moved.
changes_turn_list_reveal :: proc(
	state: ^Changes_State, g: Changes_Geometry, view: ^Changes_View, index: int,
) -> bool {
	if index < 0 || index >= len(view.turns) || g.turn_row <= 0 {return false}
	row, visible := int(g.turn_row), int(turn_list_rows(g).height)
	top := index * row
	target := state.turn_list_scroll
	if top < target {
		target = top
	} else if top + row > target + visible {
		target = top + row - visible
	}
	target = clamp(target, 0, turn_list_limit(g, view))
	moved := target != state.turn_list_scroll
	state.turn_list_scroll = target
	return moved
}

// The strip's offset, clamped to the bars there are.
@(private)
strip_offset :: proc(g: Changes_Geometry, state: ^Changes_State, view: ^Changes_View) -> int {
	return clamp(state.strip_offset, 0, max(0, len(view.turns) - g.strip_bars))
}

@(private = "file")
strip_bottom :: proc(g: Changes_Geometry) -> f32 {
	return g.strip.y + g.strip.height - math.round(STRIP_INSET * g.scale)
}

// A bar grows with the log of the lines a turn changed, so one huge turn leaves the others readable.
@(private = "file")
strip_bar_place :: proc(g: Changes_Geometry, turn: ^Changes_Turn, column: int) -> render.Rect {
	s := g.scale
	bar, pitch := strip_metrics(s)
	height := STRIP_BAR_MAX
	if !turn.live {
		lines := f32(turn.added + turn.removed + 1)
		height = clamp(STRIP_BAR_MIN + 3 * math.log2(lines), STRIP_BAR_MIN, STRIP_BAR_MAX)
		if turn.between {height = min(height, STRIP_BETWEEN_MAX)}
	}
	bottom := strip_bottom(g)
	h := min(math.round(height * s), max(0, bottom - g.strip.y))
	return {g.strip.x + f32(column) * pitch, bottom - h, bar, h}
}

// Turn `index`'s bar as drawn; empty when it is scrolled out of the strip or there is no strip.
changes_strip_bar_rect :: proc(
	g: Changes_Geometry, state: ^Changes_State, view: ^Changes_View, index: int,
) -> render.Rect {
	count := len(view.turns)
	if index < 0 || index >= count {return {}}
	column := count - 1 - index - strip_offset(g, state, view)
	if column < 0 || column >= g.strip_bars {return {}}
	return strip_bar_place(g, &view.turns[index], column)
}

// The turn whose bar column holds `x`, or -1.
@(private)
strip_bar_at :: proc(g: Changes_Geometry, state: ^Changes_State, view: ^Changes_View, x: f32) -> int {
	if g.strip_bars <= 0 || x < g.strip.x {return -1}
	_, pitch := strip_metrics(g.scale)
	column := int((x - g.strip.x) / pitch)
	if column >= g.strip_bars {return -1}
	index := len(view.turns) - 1 - strip_offset(g, state, view) - column
	return index >= 0 ? index : -1
}

// Scrolls the strip just far enough to show the selection's newest end, so it follows the newest bar
// while that is selected; true when it moved. changes_draw calls it when the strip's room, the turns or
// the selection changed; calling it on a selection change keeps hit tests right until the next draw.
changes_strip_reveal :: proc(state: ^Changes_State, g: Changes_Geometry, view: ^Changes_View) -> bool {
	count := len(view.turns)
	before := state.strip_offset
	offset := strip_offset(g, state, view)
	if view.first >= 0 && view.first < count && g.strip_bars > 0 {
		column := count - 1 - view.first
		if column < offset {
			offset = column
		} else if column >= offset + g.strip_bars {
			offset = column - g.strip_bars + 1
		}
	}
	state.strip_offset = offset
	return offset != before
}

// Reveals the selection when the strip's room, the turn count or the selection changed since the last
// draw, and reports whether that moved the strip; otherwise only clamps, so a paged or wheel-scrolled
// strip stays where it was put.
@(private)
strip_follow :: proc(state: ^Changes_State, g: Changes_Geometry, view: ^Changes_View) -> (moved: bool) {
	count := len(view.turns)
	if g.strip_room == state.strip_seen_room && count == state.strip_seen_turns &&
	   view.first == state.strip_seen_first {
		state.strip_offset = strip_offset(g, state, view)
		return false
	}
	moved = changes_strip_reveal(state, g, view)
	state.strip_seen_room, state.strip_seen_turns, state.strip_seen_first = g.strip_room, count, view.first
	return
}

// Moves the strip by `delta` bars, positive toward newer turns; true when it moved.
changes_scroll_strip :: proc(
	state: ^Changes_State, g: Changes_Geometry, view: ^Changes_View, delta: int,
) -> bool {
	before := strip_offset(g, state, view)
	state.strip_offset = clamp(before + delta, 0, max(0, len(view.turns) - g.strip_bars))
	return state.strip_offset != before
}

@(private = "file")
strip_draw :: proc(
	list: ^render.Draw_List, theme: Theme, g: Changes_Geometry, view: ^Changes_View, state: ^Changes_State,
) {
	if g.strip_bars <= 0 {return}
	s := g.scale
	count := len(view.turns)
	offset := strip_offset(g, state, view)
	bar, pitch := strip_metrics(s)
	pad := math.round(STRIP_INSET * s)
	bottom := strip_bottom(g)
	band_top := max(g.strip.y, bottom - math.round(STRIP_BAR_MAX * s)) - pad
	band_height := bottom + pad - band_top
	if state.hover.part == .Strip_Bar {
		if r := changes_strip_bar_rect(g, state, view, state.hover.index); r.width > 0 {
			column := render.Rect{r.x - pad, band_top, r.width + 2 * pad, band_height}
			draw_rect(list, {rect = column, color = theme.hover, radius = RADIUS_CONTROL * s})
		}
	}
	agents := CHANGES_AGENT_PALETTE
	for column in 0 ..< g.strip_bars {
		index := count - 1 - offset - column
		if index < 0 {break}
		turn := &view.turns[index]
		color := theme.muted
		switch {
		case turn.live:
			color = theme.info
		case index >= view.first && index <= view.last:
			color = theme.accent
		case turn.between:
			color = theme.faint
		case turn.agent >= 0:
			color = theme.palette[agents[turn.agent % len(agents)]]
			color.a *= CHANGES_AGENT_ALPHA
		}
		r := strip_bar_place(g, turn, column)
		draw_rect(list, {rect = r, color = color, radius = pill_radius(r)})
	}
	if view.first < 0 || view.last < view.first || view.first >= count {return}
	first := max(count - 1 - min(view.last, count - 1) - offset, 0)
	last := min(count - 1 - view.first - offset, g.strip_bars - 1)
	if first > last {return}
	run := render.Rect {
		g.strip.x + f32(first) * pitch - pad,
		band_top,
		f32(last - first) * pitch + bar + 2 * pad,
		band_height,
	}
	draw_rect(list, {rect = run, color = theme.accent, radius = RADIUS_CONTROL * s, stroke = s})
}

@(private = "file")
step_draw :: proc(
	list: ^render.Draw_List,
	theme: Theme,
	rect: render.Rect,
	icon: Icon,
	part: Changes_Part,
	enabled: bool,
	state: ^Changes_State,
	scale: f32,
	pointer: [2]f32,
) -> render.Error {
	if rect.width <= 0 {return .None}
	hover, press := changes_lit(state, {part, 0, 0})
	b := Button {
		rect     = rect,
		hover    = hover,
		press    = press,
		disabled = !enabled,
	}
	face, ink, err := button_draw(list, theme, b, scale, pointer)
	if err != .None {return err}
	icon_draw(list, icon, face, ink, ICON_BUTTON, scale)
	return .None
}

// The range label with its chevron, led by the working spinner while a turn is live.
@(private = "file")
range_label_draw :: proc(
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
	if g.range_label.width <= 0 {return .Ok, false}
	s := g.scale
	hover, press := changes_lit(state, {.Range_Label, 0, 0})
	b := Button {
		rect     = g.range_label,
		hover    = hover,
		press    = press,
		radius   = RADIUS_CONTROL,
		selected = state.turn_list_open,
	}
	face, ink, err := button_draw(list, theme, b, s, pointer)
	if err != .None {return .Ok, false}
	inset := CONTROL_INSET * s
	icon := ICON_INDICATOR * s
	x := face.x + inset
	chevron := render.Rect{face.x + face.width - inset - icon, face.y, icon, face.height}
	if changes_live_index(view) >= 0 {
		mark := render.Rect{x, face.y, icon, face.height}
		if status = status_glyph_draw(list, text, theme, mark, WORKING_MARK, phase, s); status != .Ok {return}
		spinning = true
		x += icon + SPACE_1 * s
	}
	body := text_styled(text, .Body)
	buf: [RANGE_LABEL_BYTES]u8
	label := changes_range_label(view, buf[:])
	status = draw_fading_text(
		&body, list, label, x, baseline_in(face.y, face.height, &body), theme.text,
		max(0, chevron.x - SPACE_1 * s - x),
	)
	if status != .Ok {return}
	icon_draw(list, .Chevron_Down, chevron, ink, ICON_INDICATOR, s)
	return .Ok, spinning
}

// The filter bar under the row: its row and the Clear button at the right.
@(private)
filter_bar_place :: proc(g: ^Changes_Geometry, text: ^Text, y: f32) {
	s := g.scale
	area := g.area
	height := min(math.round(HEIGHT_COMPACT * s), max(0, area.y + area.height - y))
	if height <= 0 {return}
	g.filter_bar = {area.x, y, area.width, height}
	small := text_styled(text, .Detail)
	width := math.ceil(text_width(&small, FILTER_CLEAR_LABEL) + 2 * CONTROL_INSET * s)
	button := max(0, height - 2 * math.round(2 * s))
	g.filter_bar_clear = {area.x + area.width - SPACE_2 * s - width, y + (height - button) / 2, width, button}
}

// The filter popover under the filter circle, or under ⋯ while the circles are collapsed, right-aligned
// to it inside the pane: the field, with its clear button while it has text, and below it a hint line, the
// rows of the saved filters an `@` can complete to, or the name field of a filter being saved.
@(private)
filter_popover_place :: proc(g: ^Changes_Geometry, view: ^Changes_View, text: ^Text) {
	s := g.scale
	area := g.area
	pad, inset := SPACE_2 * s, SPACE_3 * s
	width := min(math.round(FILTER_POPOVER_WIDTH * s), max(0, area.width - 2 * pad))
	if width <= 2 * inset {return}
	anchor := g.filter_button.width > 0 ? g.filter_button : g.tools_button
	right := anchor.x + anchor.width
	x := clamp(right - width, area.x + pad, max(area.x + pad, area.x + area.width - pad - width))
	y := g.row.y + g.row.height + SPACE_1 * s
	small := text_styled(text, .Detail)
	field := math.round(HEIGHT_STANDARD * s)
	g.filter_field = {x + inset, y + inset, width - 2 * inset, field}
	height := 2 * inset + field + SPACE_2 * s + small.line_height
	below := g.filter_field.y + field
	switch {
	case view.filter_naming:
		g.filter_name = {g.filter_field.x, below + SPACE_2 * s, g.filter_field.width, field}
		height += field + SPACE_2 * s
	case view.filter_pick_open:
		place_picks(g, view, x, below + SPACE_1 * s, width)
		height = inset + field + SPACE_1 * s + f32(len(g.filter_picks)) * math.round(HEIGHT_STANDARD * s) +
			OVERLAY_PADDING * s
	}
	g.filter_popover = {x, y, width, math.round(height)}
	if view.filter_editor != nil && len(view.filter_editor.bytes) > 0 {
		size := HEIGHT_COMPACT * s
		f := g.filter_field
		g.filter_clear = {f.x + f.width - SPACE_1 * s - size, f.y + (f.height - size) / 2, size, size}
	}
}

// Lays out the rows of the saved filters an `@` can complete to under the field, at most
// FILTER_PICK_ROWS of them, scrolled so the row the keys are on shows; the last row is Edit filters….
@(private = "file")
place_picks :: proc(g: ^Changes_Geometry, view: ^Changes_View, x, top, width: f32) {
	s := g.scale
	total := len(view.filter_picks) + 1
	count := min(total, FILTER_PICK_ROWS)
	rects, err := make([]render.Rect, count, context.temp_allocator)
	if err != nil {return}
	g.filter_pick_first = clamp(view.filter_pick_row - count + 1, 0, total - count)
	height := math.round(HEIGHT_STANDARD * s)
	for i in 0 ..< count {
		rects[i] = {x + OVERLAY_PADDING * s, top + f32(i) * height, width - 2 * OVERLAY_PADDING * s, height}
	}
	g.filter_picks = rects
}

// The filter field's editing box, short of the clear button; false without an editor or a field.
changes_filter_box :: proc(
	g: Changes_Geometry, view: ^Changes_View, text: ^Text,
) -> (
	box: Field_Box,
	shown: bool,
) {
	if view.filter_editor == nil || g.filter_field.width <= 0 {return}
	rect := g.filter_field
	if g.filter_clear.width > 0 {rect.width = max(0, g.filter_clear.x - rect.x)}
	return field_box_standard(view.filter_editor, text, rect, g.scale), true
}

// "N of M files hidden · showing +A −R of +A −R", the counts in the added and removed colours as the
// file headers show them, fading before the Clear button, which always stays.
@(private)
filter_bar_draw :: proc(
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	g: Changes_Geometry,
	view: ^Changes_View,
	state: ^Changes_State,
	pointer: [2]f32,
) -> render.Build_Status {
	bar := g.filter_bar
	if bar.height <= 0 || bar.width <= 0 {return .Ok}
	s := g.scale
	draw_rect(list, {rect = {bar.x, bar.y + bar.height - s, bar.width, s}, color = theme.border})
	small := text_styled(text, .Detail)
	head_buf: [96]u8
	count_bufs: [4][24]u8
	noun := view.total_files == 1 ? "file" : "files"
	Run :: struct {
		s:     string,
		color: render.Color,
	}
	runs: [8]Run
	count := 1
	stats := view.total_added > 0 || view.total_removed > 0
	head := stats ? "%d of %d %s hidden · showing " : "%d of %d %s hidden"
	runs[0] = {fmt.bprintf(head_buf[:], head, view.hidden_count, view.total_files, noun), theme.muted}
	if stats {
		runs[1] = {fmt.bprintf(count_bufs[0][:], "+%d", view.shown_added), theme.success}
		runs[2] = {" ", theme.muted}
		runs[3] = {fmt.bprintf(count_bufs[1][:], "−%d", view.shown_removed), theme.error}
		runs[4] = {" of ", theme.muted}
		runs[5] = {fmt.bprintf(count_bufs[2][:], "+%d", view.total_added), theme.success}
		runs[6] = {" ", theme.muted}
		runs[7] = {fmt.bprintf(count_bufs[3][:], "−%d", view.total_removed), theme.error}
		count = len(runs)
	}
	clear := g.filter_bar_clear
	x := bar.x + SPACE_3 * s
	limit := clear.width > 0 ? clear.x - SPACE_2 * s : bar.x + bar.width - SPACE_3 * s
	baseline := baseline_in(bar.y, bar.height, &small)
	for run in runs[:count] {
		if x >= limit {break}
		if status := draw_fading_text(&small, list, run.s, x, baseline, run.color, limit - x); status != .Ok {
			return status
		}
		x += text_width(&small, run.s)
	}
	if clear.width <= 0 {return .Ok}
	hover, press := changes_lit(state, {.Filter_Bar_Clear, 0, 0})
	b := Button {
		rect    = clear,
		hover   = hover,
		press   = press,
		radius  = RADIUS_CONTROL,
		surface = .Flat,
	}
	face, ink, err := button_draw(list, theme, b, s, pointer)
	if err != .None {return .Ok}
	width := min(text_width(&small, FILTER_CLEAR_LABEL), face.width)
	return draw_text(
		&small, list, FILTER_CLEAR_LABEL, face.x + (face.width - width) / 2,
		baseline_in(face.y, face.height, &small), ink, face.width,
	)
}

// The rows of the saved filters offered for an `@` being typed: the highlighted one has the hover fill, each
// shows its name and, fading, its pattern; the row past the last filter opens Settings on them.
@(private = "file")
filter_picks_draw :: proc(
	list: ^render.Draw_List, text: ^Text, theme: Theme, g: Changes_Geometry, view: ^Changes_View,
) -> render.Build_Status {
	s := g.scale
	body, small := text_styled(text, .Body), text_styled(text, .Detail)
	for rect, i in g.filter_picks {
		index := g.filter_pick_first + i
		if index == view.filter_pick_row {
			draw_rect(list, {rect = rect, color = theme.hover, radius = RADIUS_CONTROL * s})
		}
		x, right := rect.x + SPACE_2 * s, rect.x + rect.width - SPACE_2 * s
		baseline := baseline_in(rect.y, rect.height, &body)
		if index >= len(view.filter_picks) {
			status := draw_fading_text(&body, list, FILTER_MANAGE_LABEL, x, baseline, theme.muted, right - x)
			if status != .Ok {return status}
			continue
		}
		pick := view.filter_picks[index]
		name := min(text_width(&body, pick.name), right - x)
		if status := draw_text(&body, list, pick.name, x, baseline, theme.text, name); status != .Ok {return status}
		pattern := x + name + SPACE_2 * s
		if pattern >= right {continue}
		pattern_baseline := baseline_in(rect.y, rect.height, &small)
		status := draw_fading_text(
			&small, list, pick.pattern, pattern, pattern_baseline, theme.faint, right - pattern,
		)
		if status != .Ok {return status}
	}
	return .Ok
}

// The open filter popover: the field (outlined in the error colour while the filter is invalid) with the
// saved filters in it as tokens, its clear button, and below it the hint or the error, the saved filters an
// `@` can complete to, or the name field of a filter being saved.
@(private)
filter_popover_draw :: proc(
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	g: Changes_Geometry,
	view: ^Changes_View,
	state: ^Changes_State,
	pointer: [2]f32,
) -> render.Build_Status {
	if !state.filter_open || g.filter_popover.width <= 0 {return .Ok}
	s := g.scale
	scope, opened := clip_scope_open(list, g.area)
	if !opened {return .Ok}
	defer clip_scope_close(list, scope)
	if panel_draw(list, popover_panel(g.filter_popover, s), theme) != .None {return .Ok}
	field := g.filter_field
	box_draw(list, field, theme, !view.filter_invalid && !view.filter_naming, s)
	if view.filter_invalid {
		ring := render.Rect{field.x - 2 * s, field.y - 2 * s, field.width + 4 * s, field.height + 4 * s}
		draw_rect(list, {rect = ring, color = theme.error, radius = (RADIUS_CONTROL + 2) * s, stroke = 2 * s})
	}
	if box, shown := changes_filter_box(g, view, text); shown {
		baseline := field_box_baseline(box)
		status := filter_field_draw(
			box, view.filter_tokens, list, theme, baseline, !view.filter_naming, FILTER_PLACEHOLDER, pointer,
		)
		if status != .Ok {return status}
	}
	if g.filter_clear.width > 0 {
		hover, press := changes_lit(state, {.Filter_Clear, 0, 0})
		err := icon_button_draw(
			list, theme, g.filter_clear, .Close, hover, press, s, pointer, ICON_INDICATOR, RADIUS_CONTROL,
		)
		if err != .None {return .Ok}
	}
	if len(g.filter_picks) > 0 {return filter_picks_draw(list, text, theme, g, view)}
	small := text_styled(text, .Detail)
	hint, ink := FILTER_HINT, theme.muted
	hint_y := field.y + field.height + SPACE_2 * s
	notice: [96]u8
	switch {
	case view.filter_naming:
		name := g.filter_name
		box_draw(list, name, theme, view.filter_notice == "", s)
		box := field_box_standard(view.filter_name, text, name, s)
		status := field_box_draw(box, list, theme, field_box_baseline(box), true, FILTER_NAME_PLACEHOLDER)
		if status != .Ok {return status}
		hint, ink = FILTER_NAME_HINT, theme.muted
		if view.filter_notice != "" {hint, ink = clip_bytes(view.filter_notice, CHANGES_CLIP_BYTES), theme.error}
		hint_y = name.y + name.height + SPACE_2 * s
	case view.filter_invalid:
		hint, ink = clip_bytes(view.filter_error, CHANGES_CLIP_BYTES), theme.error
	case view.filter_unknown != "":
		hint, ink = fmt.bprintf(notice[:], "No saved filter named %s", view.filter_unknown), theme.warning
	case view.filter_savable:
		hint = FILTER_SAVE_HINT
	}
	return draw_fading_text(&small, list, hint, field.x, hint_y + small.ascent, ink, field.width)
}

// A "+N" marker beside the strip for the `hidden` turns it can't show on that side; nothing when none.
@(private = "file")
strip_marker_draw :: proc(
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	rect: render.Rect,
	part: Changes_Part,
	hidden: int,
	state: ^Changes_State,
	scale: f32,
	pointer: [2]f32,
) -> render.Build_Status {
	if hidden <= 0 || rect.width <= 0 {return .Ok}
	hover, press := changes_lit(state, {part, 0, 0})
	b := Button {
		rect    = rect,
		hover   = hover,
		press   = press,
		radius  = RADIUS_CONTROL,
		surface = .Flat,
	}
	face, ink, err := button_draw(list, theme, b, scale, pointer)
	if err != .None {return .Ok}
	small := text_styled(text, .Detail)
	buf: [24]u8
	label := fmt.bprintf(buf[:], "+%d", hidden)
	width := min(text_width(&small, label), face.width)
	return draw_text(
		&small, list, label, face.x + (face.width - width) / 2, baseline_in(face.y, face.height, &small), ink,
		face.width,
	)
}

// The turn strip's row in the panel: ‹, the strip with its "+N" markers, ›, and the range label, led by
// the working spinner while a turn is live.
@(private)
strip_row_draw :: proc(
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
	s := g.scale
	back, forward := changes_step_enabled(view)
	if step_draw(list, theme, g.step_back, .Chevron_Left, .Step_Back, back, state, s, pointer) != .None {
		return .Ok, false
	}
	strip_draw(list, theme, g, view, state)
	older, newer := changes_strip_hidden(g, state, view)
	if status = strip_marker_draw(list, text, theme, g.strip_older, .Strip_Older, older, state, s, pointer);
	   status != .Ok {return}
	if status = strip_marker_draw(list, text, theme, g.strip_newer, .Strip_Newer, newer, state, s, pointer);
	   status != .Ok {return}
	ahead := step_draw(list, theme, g.step_forward, .Chevron_Right, .Step_Forward, forward, state, s, pointer)
	if ahead != .None {return .Ok, false}
	return range_label_draw(list, text, theme, g, view, state, pointer, phase)
}

// A turn list row: the title (after the spinner when live) and "+A −R" on the first line, the detail
// and the file count on the second.
@(private = "file")
turn_row_draw :: proc(
	list: ^render.Draw_List,
	body, small: ^Text,
	theme: Theme,
	row: render.Rect,
	turn: ^Changes_Turn,
	phase: f32,
	scale: f32,
) -> (
	status: render.Build_Status,
	spinning: bool,
) {
	s := scale
	x := row.x + SPACE_3 * s
	right := row.x + row.width - SPACE_3 * s
	top := row.y + (row.height - body.line_height - small.line_height) / 2
	title_baseline := top + body.ascent
	detail_baseline := top + body.line_height + small.ascent
	stats_baseline := top + (body.line_height - small.line_height) / 2 + small.ascent
	left: f32
	left, status = stats_draw(list, small, theme, right, stats_baseline, turn.added, turn.removed, s)
	if status != .Ok {return}
	title_x := x
	if turn.live {
		mark := render.Rect{x, top, ICON_INDICATOR * s, body.line_height}
		if status = status_glyph_draw(list, body, theme, mark, WORKING_MARK, phase, s); status != .Ok {return}
		spinning = true
		title_x += (ICON_INDICATOR + SPACE_1) * s
	}
	if status = draw_fading_text(
		body, list, turn_title(turn), title_x, title_baseline, turn.between ? theme.muted : theme.text,
		left - SPACE_2 * s - title_x,
	); status != .Ok {return}
	detail := clip_bytes(turn.detail, CHANGES_CLIP_BYTES)
	count_buf: [32]u8
	files := ""
	if turn.files > 0 {
		files = fmt.bprintf(count_buf[:], "%d %s", turn.files, turn.files == 1 ? "file" : "files")
	}
	files_x := right - text_width(small, files)
	if files != "" {
		if status = draw_text(small, list, files, files_x, detail_baseline, theme.faint); status != .Ok {return}
		files_x -= SPACE_2 * s
	} else {
		files_x = right
	}
	status = draw_fading_text(small, list, detail, x, detail_baseline, theme.muted, files_x - x)
	return
}

// The open turn list over the diff: one row per turn, newest first, the selected run tinted with the
// accent mark beside it.
@(private)
turn_list_draw :: proc(
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
	if !state.turn_list_open || g.turn_list.width <= 0 || g.turn_list.height <= 0 || g.turn_row <= 0 {
		return .Ok, false
	}
	s := g.scale
	scope, opened := clip_scope_open(list, g.area)
	if !opened {return .Ok, false}
	defer clip_scope_close(list, scope)
	if panel_draw(list, popover_panel(g.turn_list, s), theme) != .None {return .Ok, false}
	rows := turn_list_rows(g)
	if render.push_layer(list, rows) != .None {return .Ok, false}
	body := text_styled(text, .Body)
	small := text_styled(text, .Detail)
	scroll := f32(state.turn_list_scroll)
	origin := rows.y - scroll
	count := len(view.turns)
	if view.first >= 0 && view.last >= view.first && view.first < count {
		last := min(view.last, count - 1)
		run := render.Rect {
			rows.x,
			origin + f32(view.first) * g.turn_row,
			rows.width,
			f32(last - view.first + 1) * g.turn_row,
		}
		tile := render.Rect{run.x, run.y + s, run.width, max(0, run.height - 2 * s)}
		draw_rect(list, {rect = tile, color = theme.selection, radius = RADIUS_CONTROL * s})
		mark := navigation_row_mark_rect(run, s)
		draw_rect(list, {rect = mark, color = theme.accent, radius = pill_radius(mark)})
	}
	first := max(0, int(scroll / g.turn_row))
	last := min(count - 1, int((scroll + rows.height) / g.turn_row))
	for i := first; i <= last; i += 1 {
		row := render.Rect{rows.x, origin + f32(i) * g.turn_row, rows.width, g.turn_row}
		selected := i >= view.first && i <= view.last
		hit := Changes_Hit{.Turn_List_Row, i, 0}
		hovered, pressed := state.hover == hit, state.press == hit && state.hover == hit
		if !selected && (hovered || pressed) {
			nav := Navigation_Row {
				hovered = hovered,
				pressed = pressed,
			}
			if navigation_row_surface_draw(list, theme, row, nav, s, pointer) != .None {return .Ok, spinning}
		}
		spun: bool
		status, spun = turn_row_draw(list, &body, &small, theme, row, &view.turns[i], phase, s)
		spinning = spinning || spun
		if status != .Ok {return}
	}
	if track, shown := changes_turn_list_scrollbar(state, g, view); shown {
		over := render.rect_contains(track.track, pointer.x, pointer.y)
		bar_state := scrollbar_state(over, state.turn_list_bar)
		if bar, drawn := changes_turn_list_scrollbar(state, g, view, bar_state); drawn {
			scrollbar_draw(list, theme, bar, bar_state)
		}
	}
	return .Ok, spinning
}
