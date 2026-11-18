package ui

import "aio:render"
import "core:math"

// The overview strip at the right edge of the diff: the whole stream squeezed into the lane's height, each
// file's span as a faint segment under a hairline, and added and removed runs and comment cards as ticks.
// It replaces the pane scrollbar, so it is one: the visible part is the shared scrollbar's thumb (its
// layout, colours, hover and drag states, and its track press that pages) laid over the map. The map
// outside the thumb is dimmed, so the thumb reads whatever lies under it: green, red or an empty lane.
// The ticks come from the cached rows (changes_ticks_build), so drawing allocates nothing and never walks
// the diff.

@(private = "file")
OVERVIEW_TICK_INSET :: f32(3)
@(private = "file")
OVERVIEW_COMMENT_INSET :: f32(2)
@(private = "file")
OVERVIEW_TICK_MINIMUM :: f32(2)
@(private = "file")
OVERVIEW_COMMENT_MINIMUM :: f32(4)
@(private = "file")
OVERVIEW_SEGMENT_ALPHA :: f32(0.5)
// How much of a tick's strength remains outside the thumb.
@(private = "file")
OVERVIEW_DIM_ALPHA :: f32(0.45)
// The thumb's outline, by state: at rest, under the pointer, held.
@(private = "file")
@(rodata)
OVERVIEW_OUTLINE_ALPHA := [Scrollbar_State]f32{.Collapsed = 0.55, .Hovered = 0.75, .Active = 0.95}
// The thumb leaves the hairline at the lane's left edge and one more DIP clear, and the lane's right edge.
@(private = "file")
OVERVIEW_THUMB_LEFT :: f32(2)
@(private = "file")
OVERVIEW_THUMB_RIGHT :: f32(1)

// The strip as a scrollbar over the whole diff stream: the lane is its track, and the thumb is the visible
// part. It is as wide at rest as the shared bar is under the pointer, because the lane is always a map
// and a thin thumb would vanish in it. Nothing is shown while the stream fits the diff area.
changes_overview_bar :: proc(state: ^Changes_State, g: Changes_Geometry) -> (bar: Scrollbar, visible: bool) {
	lane := g.overview
	if lane.width <= 0 || lane.height <= 0 {return}
	extent := Scroll_Extent{state.rows.total, int(g.diff.height), state.diff_scroll}
	bar, visible = scrollbar_layout(lane, extent, .Hovered, g.scale)
	if !visible {return}
	left, right := OVERVIEW_THUMB_LEFT * g.scale, OVERVIEW_THUMB_RIGHT * g.scale
	bar.track = lane
	bar.thumb.x, bar.thumb.width = lane.x + left, max(0, lane.width - left - right)
	return bar, true
}

// The thumb over the part of the diff on screen; empty while the stream fits.
changes_overview_thumb :: proc(state: ^Changes_State, g: Changes_Geometry) -> render.Rect {
	bar, visible := changes_overview_bar(state, g)
	return visible ? bar.thumb : {}
}

// What the strip's thumb shows: at rest, under the pointer, or held.
changes_overview_state :: proc(
	state: ^Changes_State,
	g: Changes_Geometry,
	pointer: [2]f32,
) -> Scrollbar_State {
	return scrollbar_state(render.rect_contains(g.overview, pointer.x, pointer.y), state.overview_drag)
}

// A press on the lane at `y`: a press on the thumb holds it where it was grabbed, and one on the track
// pages toward the pointer. Returns the diff scroll.
changes_overview_press :: proc(state: ^Changes_State, g: Changes_Geometry, y: f32) -> int {
	bar, visible := changes_overview_bar(state, g)
	if !visible {return state.diff_scroll}
	return scrollbar_press(&state.overview_drag, bar, y)
}

// The diff scroll while the held thumb is dragged to `y`.
changes_overview_drag :: proc(state: ^Changes_State, g: Changes_Geometry, y: f32) -> int {
	bar, visible := changes_overview_bar(state, g)
	if !visible {return state.diff_scroll}
	return scrollbar_drag(state.overview_drag, bar, y)
}

// One page of a held track press toward (x, y) on the strip; see scrollbar_page.
changes_overview_page :: proc(state: ^Changes_State, g: Changes_Geometry, x, y: f32) -> Scroll_Page {
	bar, visible := changes_overview_bar(state, g)
	if !visible {return .Off_Track}
	offset, result := scrollbar_page(bar, x, y)
	if result == .Paged {state.diff_scroll = offset}
	return result
}

// Draws a tick at full strength where the thumb covers it and dimmed above and below, so a run as long as
// a file still shows where the thumb is. Without a thumb the tick is drawn whole.
@(private = "file")
overview_tick_draw :: proc(list: ^render.Draw_List, tick: render.Rect, color: render.Color, thumb: render.Rect) {
	if thumb.height <= 0 {
		draw_rect(list, {rect = tick, color = color})
		return
	}
	dim := color
	dim.a *= OVERVIEW_DIM_ALPHA
	top, end := tick.y, tick.y + tick.height
	inner_top, inner_end := clamp(thumb.y, top, end), clamp(thumb.y + thumb.height, top, end)
	if inner_top > top {draw_rect(list, {rect = {tick.x, top, tick.width, inner_top - top}, color = dim})}
	if inner_end > inner_top {
		draw_rect(list, {rect = {tick.x, inner_top, tick.width, inner_end - inner_top}, color = color})
	}
	if end > inner_end {draw_rect(list, {rect = {tick.x, inner_end, tick.width, end - inner_end}, color = dim})}
}

// Draws the strip: its lane, each file's segment, the ticks and the thumb.
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
	look := changes_overview_state(state, g, pointer)
	draw_rect(list, {rect = lane, color = theme.window})
	if look != .Collapsed {draw_rect(list, {rect = lane, color = theme.scrollbar_track})}
	draw_rect(list, {rect = {lane.x, lane.y, rule, lane.height}, color = theme.border})
	total := max(rows.total, int(g.diff.height))
	if total <= 0 {return}
	k := lane.height / f32(total)
	thumb := changes_overview_thumb(state, g)
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
		overview_tick_draw(list, {lane.x + inset, y, lane.width - 2 * inset, height}, color, thumb)
	}
	if thumb.height <= 0 {return}
	fill := theme.scrollbar
	switch look {
	case .Collapsed:
	case .Hovered:
		fill = theme.scrollbar_hover
	case .Active:
		fill = theme.scrollbar_active
	}
	radius := pill_radius(thumb)
	draw_rect(list, {rect = thumb, color = fill, radius = radius})
	outline := theme.text
	outline.a *= OVERVIEW_OUTLINE_ALPHA[look]
	draw_rect(list, {rect = thumb, color = outline, radius = radius, stroke = rule})
}
