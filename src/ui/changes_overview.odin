package ui

import "aio:render"
import "core:math"

// The overview strip at the right edge of the diff: the whole stream squeezed into the lane's height, each
// file's span as a faint segment under a hairline, added and removed runs and comment cards as ticks, and
// the part on screen as a translucent box. It replaces the pane scrollbar: a press or drag on it scrolls
// as a scrollbar does. The ticks come from the cached rows (changes_ticks_build), so drawing allocates
// nothing and never walks the diff.

@(private = "file")
OVERVIEW_TICK_INSET :: f32(3)
@(private = "file")
OVERVIEW_COMMENT_INSET :: f32(2)
@(private = "file")
OVERVIEW_TICK_MINIMUM :: f32(2)
@(private = "file")
OVERVIEW_COMMENT_MINIMUM :: f32(4)
@(private = "file")
OVERVIEW_BOX_MINIMUM :: f32(8)
@(private = "file")
OVERVIEW_SEGMENT_ALPHA :: f32(0.5)
@(private = "file")
OVERVIEW_BOX_ALPHA :: f32(0.09)
@(private = "file")
OVERVIEW_BOX_ACTIVE_ALPHA :: f32(0.14)
@(private = "file")
OVERVIEW_OUTLINE_ALPHA :: f32(0.2)

// The stream height the strip maps: the whole stream, or the visible height when that is shorter.
@(private = "file")
overview_total :: proc(state: ^Changes_State, g: Changes_Geometry) -> int {
	return max(state.rows.total, int(g.diff.height))
}

// The box over the part of the diff on screen, across the lane's width; empty without a lane.
changes_overview_box :: proc(state: ^Changes_State, g: Changes_Geometry) -> render.Rect {
	lane := g.overview
	total := overview_total(state, g)
	if lane.width <= 0 || lane.height <= 0 || total <= 0 {return {}}
	k := lane.height / f32(total)
	height := min(lane.height, max(g.diff.height * k, OVERVIEW_BOX_MINIMUM * g.scale))
	scroll := clamp(state.diff_scroll, 0, max(0, state.rows.total - int(g.diff.height)))
	y := min(lane.y + f32(scroll) * k, lane.y + lane.height - height)
	return {lane.x, y, lane.width, height}
}

// The diff scroll that puts the box's top at `top`, a y in the window, kept inside the lane.
@(private = "file")
overview_scroll_for :: proc(state: ^Changes_State, g: Changes_Geometry, top: f32) -> int {
	lane := g.overview
	total := overview_total(state, g)
	if lane.height <= 0 || total <= 0 {return state.diff_scroll}
	k := lane.height / f32(total)
	height := changes_overview_box(state, g).height
	offset := clamp(top, lane.y, max(lane.y, lane.y + lane.height - height)) - lane.y
	return clamp(int(math.round(offset / k)), 0, max(0, state.rows.total - int(g.diff.height)))
}

// A press on the lane at `y`: holds the strip, and returns the diff scroll that puts the point at the
// centre of the view, or keeps where the box was grabbed when the press lands inside the box.
changes_overview_press :: proc(state: ^Changes_State, g: Changes_Geometry, y: f32) -> int {
	box := changes_overview_box(state, g)
	state.overview_held = true
	state.overview_grab = y >= box.y && y < box.y + box.height ? y - box.y : box.height / 2
	return overview_scroll_for(state, g, y - state.overview_grab)
}

// The diff scroll while the held strip is dragged to `y`.
changes_overview_drag :: proc(state: ^Changes_State, g: Changes_Geometry, y: f32) -> int {
	return overview_scroll_for(state, g, y - state.overview_grab)
}

// Draws the strip: its lane, each file's segment, the ticks and the box.
@(private)
overview_draw :: proc(
	list: ^render.Draw_List,
	theme: Theme,
	g: Changes_Geometry,
	view: ^Changes_View,
	state: ^Changes_State,
	pointer: [2]f32,
) {
	lane := g.overview
	rows := &state.rows
	if lane.width <= 0 || lane.height <= 0 || !rows.valid {return}
	scope, opened := clip_scope_open(list, lane)
	if !opened {return}
	defer clip_scope_close(list, scope)
	s := g.scale
	rule := max(1, math.round(s))
	draw_rect(list, {rect = lane, color = theme.window})
	draw_rect(list, {rect = {lane.x, lane.y, rule, lane.height}, color = theme.border})
	total := overview_total(state, g)
	if total <= 0 {return}
	k := lane.height / f32(total)
	body := render.Rect{lane.x + rule, lane.y, lane.width - rule, lane.height}
	if view.notice == .None && len(rows.tops) == len(view.files) + 1 {
		fill := theme.hover
		fill.a *= OVERVIEW_SEGMENT_ALPHA
		for i in 0 ..< len(view.files) {
			top := lane.y + math.round(f32(rows.tops[i]) * k)
			end := lane.y + math.round(f32(rows.tops[i + 1] - rows.gap) * k)
			if end > top {draw_rect(list, {rect = {body.x, top, body.width, end - top}, color = fill})}
			draw_rect(list, {rect = {body.x, top, body.width, rule}, color = theme.border})
		}
	}
	for tick in rows.ticks {
		inset, least := OVERVIEW_TICK_INSET * s, OVERVIEW_TICK_MINIMUM * s
		color := theme.success
		switch tick.kind {
		case .Added:
		case .Removed:
			color = theme.error
		case .Comment:
			inset, least = OVERVIEW_COMMENT_INSET * s, OVERVIEW_COMMENT_MINIMUM * s
			color = theme.accent
			if card := int(tick.card); card >= 0 && card < len(view.comments) {
				color = changes_note_color(theme, view.comments[card])
			}
		}
		y := lane.y + math.round(f32(tick.y) * k)
		height := max(least, math.round(f32(tick.height) * k))
		if y >= lane.y + lane.height {continue}
		draw_rect(list, {rect = {lane.x + inset, y, lane.width - 2 * inset, height}, color = color})
	}
	box := changes_overview_box(state, g)
	if box.height <= 0 {return}
	active := state.overview_held || render.rect_contains(lane, pointer.x, pointer.y)
	fill, outline := theme.text, theme.text
	fill.a *= active ? OVERVIEW_BOX_ACTIVE_ALPHA : OVERVIEW_BOX_ALPHA
	outline.a *= OVERVIEW_OUTLINE_ALPHA
	shown := render.Rect{box.x + s, box.y, box.width - 2 * s, box.height}
	radius := RADIUS_CONTROL * s
	draw_rect(list, {rect = shown, color = fill, radius = radius})
	draw_rect(list, {rect = shown, color = outline, radius = radius, stroke = s})
}
