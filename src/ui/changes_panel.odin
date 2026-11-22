package ui

import "cosmos:render"
import "core:math"

// The panel under the row's summary: the source as chips, the worktree as chips in git scopes, the hooks
// button when offered, and the turn strip with the title of the selected turns in turn scopes. It opens
// from the row's summary and from Ctrl+K. It is laid out whether or not it is open, so the strip's keys
// and offsets never depend on it; only drawing and hit testing do. The file list is the files button's.

@(private = "file")
CHANGES_PANEL_WIDTH :: f32(560)
@(private = "file")
CHIP_HEIGHT :: HEIGHT_COMPACT
@(private = "file")
CHIP_PAD :: f32(8)
@(private = "file")
CHIP_DOT :: f32(8)
@(private = "file")
CHIP_GAP :: f32(6)
@(private = "file")
SOURCE_CAPTION :: "Source"
@(private = "file")
WORKTREE_CAPTION :: "Worktree"
@(private = "file")
TURNS_CAPTION :: "Turns"
@(private = "file")
FOLLOWING_LABEL :: "Following the agent"

// The scopes the source chips list after the agents, in order; the pane's source list ends with them.
CHANGES_SOURCE_SCOPES :: [?]Changes_Scope{.Repository, .Uncommitted, .Staged, .Unstaged}

@(private = "file")
chip_width :: proc(text: ^Text, label: string, scale: f32) -> f32 {
	label_width := text_width(text, clip_bytes(label, CHANGES_CLIP_BYTES))
	return math.ceil(2 * CHIP_PAD * scale + (CHIP_DOT + CHIP_GAP) * scale + label_width)
}

// Flows `labels` as chips from (`x`, `y`), wrapping at `width`; returns each chip's rectangle, in temporary
// memory, and the bottom of the last row (`y` when there are none).
@(private = "file")
chips_place :: proc(
	labels: []string, text: ^Text, x, y, width, scale: f32,
) -> (
	rects: []render.Rect,
	bottom: f32,
) {
	bottom = y
	if len(labels) == 0 {return}
	made, err := make([]render.Rect, len(labels), context.temp_allocator)
	if err != nil {return}
	height, gap := math.round(CHIP_HEIGHT * scale), SPACE_1 * scale
	cx, cy := x, y
	for label, i in labels {
		w := min(chip_width(text, label, scale), width)
		if cx > x && cx + w > x + width {cx, cy = x, cy + height + gap}
		made[i] = {cx, cy, w, height}
		cx += w + gap
	}
	return made, cy + height
}

// Places the panel under the summary, from its left edge, its sections top to bottom, and the turn strip
// inside it.
@(private)
panel_place :: proc(
	g: ^Changes_Geometry, view: ^Changes_View, text, body: ^Text, state: ^Changes_State,
) {
	s := g.scale
	area := g.area
	margin, inset := SPACE_2 * s, SPACE_3 * s
	width := math.round(min(CHANGES_PANEL_WIDTH * s, max(0, area.width - 2 * margin)))
	if width <= 2 * inset + 8 * s {return}
	right := area.x + area.width - margin - width
	x := clamp(math.round(g.summary.x), area.x + margin, max(area.x + margin, right))
	top := g.row.y + g.row.height + SPACE_1 * s
	limit := area.y + area.height - margin
	if limit <= top {return}
	left, inner := x + inset, width - 2 * inset
	small := text_styled(text, .Detail)
	caption := small.line_height
	y := top + SPACE_2 * s
	g.source_caption = {left, y, inner, caption}
	y += caption + SPACE_1 * s
	chips, bottom := chips_place(view.sources, body, left, y, inner, s)
	g.source_chips = chips
	y = bottom
	if view.hooks_offer {
		y += SPACE_2 * s
		wide := min(math.ceil(text_width(body, CHANGES_HOOKS_LABEL) + 2 * SPACE_3 * s), inner)
		height := math.round(HEIGHT_COMPACT * s)
		g.hooks = {left, y, wide, height}
		y += height
	}
	if changes_scope_turns(view.scope) {
		y += SPACE_3 * s
		g.turns_caption = {left, y, inner, caption}
		y += caption + SPACE_1 * s
		control := math.round(HEIGHT_COMPACT * s)
		strip_place(g, view, body, left, left + inner, y, control, state != nil ? state.strip_offset : 0)
		y += control
		title: [RANGE_TITLE_BYTES]u8
		if changes_range_title(view, title[:]) != "" {
			y += SPACE_1 * s
			g.turn_title = {left, y, inner, body.line_height}
			y += body.line_height
		}
	} else if len(view.worktree_labels) > 0 {
		y += SPACE_3 * s
		g.worktree_caption = {left, y, inner, caption}
		y += caption + SPACE_1 * s
		g.worktree_chips, bottom = chips_place(view.worktree_labels, body, left, y, inner, s)
		y = bottom
	}
	y += SPACE_2 * s
	g.panel = {x, top, width, min(y - top, limit - top)}
}

// What lies at the point inside the open panel: its chips, hooks button and turn strip; nothing on its
// padding or on a disabled step button.
@(private)
panel_hit :: proc(g: Changes_Geometry, view: ^Changes_View, state: ^Changes_State, x, y: f32) -> Changes_Hit {
	if render.rect_contains(g.hooks, x, y) {return {.Hooks, 0, 0}}
	for chip, i in g.source_chips {
		if render.rect_contains(chip, x, y) {return {.Source_Chip, i, 0}}
	}
	for chip, i in g.worktree_chips {
		if render.rect_contains(chip, x, y) {return {.Worktree_Chip, i, 0}}
	}
	back, forward := changes_step_enabled(view)
	if render.rect_contains(g.step_back, x, y) {return back ? {.Step_Back, 0, 0} : {}}
	if render.rect_contains(g.step_forward, x, y) {return forward ? {.Step_Forward, 0, 0} : {}}
	older := changes_strip_marker_rect(g, state, view, false)
	newer := changes_strip_marker_rect(g, state, view, true)
	if render.rect_contains(older, x, y) {return {.Strip_Older, 0, 0}}
	if render.rect_contains(newer, x, y) {return {.Strip_Newer, 0, 0}}
	if render.rect_contains(g.strip, x, y) {
		if bar := strip_bar_at(g, state, view, x); bar >= 0 {return {.Strip_Bar, bar, 0}}
		return {}
	}
	if render.rect_contains(g.range_label, x, y) {return {.Range_Label, 0, 0}}
	return {}
}

// A section's caption: faint sentence case at the left and an optional note at the right.
@(private = "file")
caption_draw :: proc(
	list: ^render.Draw_List, small: ^Text, theme: Theme, rect: render.Rect, label, note: string, scale: f32,
) -> render.Build_Status {
	if rect.width <= 0 {return .Ok}
	note_width := note != "" ? text_width(small, note) : 0
	room := rect.width - (note_width > 0 ? note_width + SPACE_2 * scale : 0)
	if status := draw_fading_text(small, list, label, rect.x, rect.y + small.ascent, theme.faint, room);
	   status != .Ok {return status}
	if note_width <= 0 {return .Ok}
	return draw_text(small, list, note, rect.x + rect.width - note_width, rect.y + small.ascent, theme.faint)
}

// One chip: its dot and label on a faint fill that deepens under the pointer; the current one has the
// selection fill and full-strength text.
@(private = "file")
chip_draw :: proc(
	list: ^render.Draw_List,
	body: ^Text,
	theme: Theme,
	rect: render.Rect,
	label: string,
	tint: render.Color,
	current: bool,
	hit: Changes_Hit,
	state: ^Changes_State,
	scale: f32,
	pointer: [2]f32,
) -> render.Build_Status {
	if rect.width <= 0 {return .Ok}
	hover, press := changes_lit(state, hit)
	radius := RADIUS_CONTROL * scale
	if !current {
		draw_rect(list, {rect = rect, color = theme.hover, radius = radius})
		fill := theme.pressed
		fill.a *= clamp(hover, 0, 1)
		draw_rect(list, {rect = rect, color = fill, radius = radius})
	}
	b := Button {
		rect     = rect,
		hover    = hover,
		press    = press,
		radius   = RADIUS_CONTROL,
		surface  = .Flat_Unfilled,
		selected = current,
	}
	face, ink, err := button_draw(list, theme, b, scale, pointer)
	if err != .None {return .Ok}
	mark := CHIP_DOT * scale
	dot := render.Rect{face.x + CHIP_PAD * scale, face.y + (face.height - mark) / 2, mark, mark}
	draw_rect(list, {rect = dot, color = tint, radius = dot.width / 2})
	x := dot.x + dot.width + CHIP_GAP * scale
	return draw_fading_text(
		body, list, clip_bytes(label, CHANGES_CLIP_BYTES), x, baseline_in(face.y, face.height, body), ink,
		face.x + face.width - CHIP_PAD * scale - x,
	)
}

// The "Install turn hooks" button.
@(private = "file")
hooks_draw :: proc(
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	g: Changes_Geometry,
	state: ^Changes_State,
	pointer: [2]f32,
) -> render.Build_Status {
	if g.hooks.width <= 0 {return .Ok}
	s := g.scale
	radius := RADIUS_CONTROL * s
	draw_rect(list, {rect = g.hooks, color = theme.surface, radius = radius})
	draw_rect(list, {rect = g.hooks, color = theme.border, radius = radius, stroke = s})
	hover, press := changes_lit(state, {.Hooks, 0, 0})
	b := Button{rect = g.hooks, hover = hover, press = press, radius = RADIUS_CONTROL, surface = .Flat_Unfilled}
	face, _, err := button_draw(list, theme, b, s, pointer)
	if err != .None {return .Ok}
	body := text_styled(text, .Body)
	inset := CONTROL_INSET * s
	width := min(text_width(&body, CHANGES_HOOKS_LABEL), max(0, face.width - 2 * inset))
	baseline := baseline_in(face.y, face.height, &body)
	return draw_text(
		&body, list, CHANGES_HOOKS_LABEL, face.x + (face.width - width) / 2, baseline, theme.text,
		max(1, face.width - 2 * inset),
	)
}

// Draws the open panel over the pane, clipped to it.
@(private)
changes_panel_draw :: proc(
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
	if !state.panel_open || g.panel.width <= 0 || g.panel.height <= 0 {return .Ok, false}
	s := g.scale
	outer, opened := clip_scope_open(list, g.area)
	if !opened {return .Ok, false}
	defer clip_scope_close(list, outer)
	if panel_draw(list, popover_panel(g.panel, s), theme) != .None {return .Ok, false}
	inner, held := clip_scope_open(list, g.panel, RADIUS_OVERLAY * s)
	if !held {return .Ok, false}
	defer clip_scope_close(list, inner)
	small := text_styled(text, .Detail)
	body := text_styled(text, .Body)
	status = caption_draw(list, &small, theme, g.source_caption, SOURCE_CAPTION, "", s)
	if status != .Ok {return}
	agents := len(view.sources) - len(CHANGES_SOURCE_SCOPES)
	for chip, i in g.source_chips {
		tint := theme.muted
		if i < agents {
			tint = source_tint(theme, i)
		} else if i == agents {
			tint = theme.accent
		}
		status = chip_draw(
			list, &body, theme, chip, view.sources[i], tint, i == view.source_current, {.Source_Chip, i, 0}, state,
			s, pointer,
		)
		if status != .Ok {return}
	}
	if status = hooks_draw(list, text, theme, g, state, pointer); status != .Ok {return}
	if g.worktree_caption.width > 0 {
		note := view.following ? FOLLOWING_LABEL : ""
		status = caption_draw(list, &small, theme, g.worktree_caption, WORKTREE_CAPTION, note, s)
		if status != .Ok {return}
		for chip, i in g.worktree_chips {
			status = chip_draw(
				list, &body, theme, chip, view.worktree_labels[i], theme.muted, i == view.worktree_current,
				{.Worktree_Chip, i, 0}, state, s, pointer,
			)
			if status != .Ok {return}
		}
	}
	if g.turns_caption.width > 0 {
		if status = caption_draw(list, &small, theme, g.turns_caption, TURNS_CAPTION, "Shift+click for a run", s);
		   status != .Ok {return}
		status, spinning = strip_row_draw(list, text, theme, g, view, state, pointer, phase)
		if status != .Ok {return}
		title_buf: [RANGE_TITLE_BYTES]u8
		title := changes_range_title(view, title_buf[:])
		if title != "" && g.turn_title.width > 0 {
			status = draw_fading_text(
				&body, list, title, g.turn_title.x, baseline_in(g.turn_title.y, g.turn_title.height, &body), theme.muted,
				g.turn_title.width,
			)
			if status != .Ok {return}
		}
	}
	return
}
