package ui

import "aio:render"
import "core:fmt"

@(private = "file")
CHANGES_FOLLOWING_LABEL :: "Following the agent"

// The turn list's own scrollbar, laid out in `state`'s look; `visible` is false when the rows fit.
changes_turn_scrollbar :: proc(
	state: ^Changes_State, g: Changes_Geometry, view: ^Changes_View, bar_state := Scrollbar_State.Collapsed,
) -> (bar: Scrollbar, visible: bool) {
	extent := Scroll_Extent {
		total   = len(view.turns) * int(g.turn_row),
		visible = int(g.turns.height),
		offset  = state.turn_scroll,
	}
	return scrollbar_layout(g.turns, extent, bar_state, g.scale)
}

// The on-screen rect of turn row `index` given the scroll, cut to the turn list; empty when it is outside.
changes_turn_rect :: proc(g: Changes_Geometry, state: ^Changes_State, index: int) -> render.Rect {
	if index < 0 || g.turn_row <= 0 {return {}}
	y := g.turns.y + f32(index) * g.turn_row - f32(state.turn_scroll)
	top, bottom := max(y, g.turns.y), min(y + g.turn_row, g.turns.y + g.turns.height)
	if bottom <= top {return {}}
	return {g.turns.x, top, g.turns.width, bottom - top}
}

// Scrolls the turn list just far enough to show row `index` whole; true when it moved.
changes_turn_reveal :: proc(
	state: ^Changes_State, g: Changes_Geometry, view: ^Changes_View, index: int,
) -> bool {
	if index < 0 || index >= len(view.turns) || g.turn_row <= 0 {return false}
	row, visible := int(g.turn_row), int(g.turns.height)
	top := index * row
	target := state.turn_scroll
	if top < target {
		target = top
	} else if top + row > target + visible {
		target = top + row - visible
	}
	target = clamp(target, 0, max(0, len(view.turns) * row - visible))
	moved := target != state.turn_scroll
	state.turn_scroll = target
	return moved
}

@(private)
turns_draw :: proc(
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	g: Changes_Geometry,
	view: ^Changes_View,
	state: ^Changes_State,
	pointer: [2]f32,
) -> render.Build_Status {
	if g.turns.width <= 0 || g.turns.height <= 0 || g.turn_row <= 0 {return .Ok}
	scope, opened := clip_scope_open(list, g.turns)
	if !opened {return .Ok}
	defer clip_scope_close(list, scope)
	s := g.scale
	body := text_styled(text, .Body)
	small := text_styled(text, .Detail)
	scroll := f32(state.turn_scroll)
	origin := g.turns.y - scroll
	count := len(view.turns)
	if view.first >= 0 && view.last >= view.first && view.first < count {
		last := min(view.last, count - 1)
		rect := render.Rect {
			g.turns.x,
			origin + f32(view.first) * g.turn_row,
			g.turns.width,
			f32(last - view.first + 1) * g.turn_row,
		}
		inner := render.Rect{rect.x, rect.y + s, rect.width, max(0, rect.height - 2 * s)}
		draw_rect(list, {rect = inner, color = theme.selection, radius = RADIUS_CONTROL * s})
		mark := navigation_row_mark_rect(rect, s)
		draw_rect(list, {rect = mark, color = theme.tab_indicator, radius = pill_radius(mark)})
	}
	first := max(0, int(scroll / g.turn_row))
	last := min(count - 1, int((scroll + g.turns.height) / g.turn_row))
	for i := first; i <= last; i += 1 {
		turn := &view.turns[i]
		row := render.Rect{g.turns.x, origin + f32(i) * g.turn_row, g.turns.width, g.turn_row}
		selected := i >= view.first && i <= view.last
		hit := Changes_Hit{.Turn, i}
		hovered, pressed := state.hover == hit, state.press == hit && state.hover == hit
		if !selected && (hovered || pressed) {
			nav := Navigation_Row {
				hovered = hovered,
				pressed = pressed,
			}
			if navigation_row_surface_draw(list, theme, row, nav, s, pointer) != .None {return .Ok}
		}
		if r := turn_row_draw(list, &body, &small, theme, row, turn, s); r != .Ok {return r}
	}
	return .Ok
}

@(private = "file")
turn_row_draw :: proc(
	list: ^render.Draw_List,
	body, small: ^Text,
	theme: Theme,
	row: render.Rect,
	turn: ^Changes_Turn,
	scale: f32,
) -> render.Build_Status {
	s := scale
	x := row.x + SPACE_3 * s
	right := row.x + row.width - SPACE_3 * s
	top := row.y + (row.height - body.line_height - small.line_height) / 2
	title_baseline := top + body.ascent
	detail_baseline := top + body.line_height + small.ascent
	stats_baseline := top + (body.line_height - small.line_height) / 2 + small.ascent
	left, status := stats_draw(list, small, theme, right, stats_baseline, turn.added, turn.removed, scale)
	if status != .Ok {return status}
	title := clip_bytes(turn.title, CHANGES_CLIP_BYTES)
	if title == "" {title = turn.between ? "Changes between turns" : "Agent turn"}
	if r := draw_fading_text(
		body, list, title, x, title_baseline, turn.between ? theme.muted : theme.text,
		left - SPACE_2 * s - x,
	); r != .Ok {return r}
	detail := clip_bytes(turn.detail, CHANGES_CLIP_BYTES)
	count_buf: [32]u8
	files := ""
	if turn.files > 0 {
		files = fmt.bprintf(count_buf[:], "%d %s", turn.files, turn.files == 1 ? "file" : "files")
	}
	files_x := right - text_width(small, files)
	if files != "" {
		if r := draw_text(small, list, files, files_x, detail_baseline, theme.faint); r != .Ok {return r}
		files_x -= SPACE_2 * s
	} else {
		files_x = right
	}
	return draw_fading_text(small, list, detail, x, detail_baseline, theme.muted, files_x - x)
}

@(private)
toolbar_draw :: proc(
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	g: Changes_Geometry,
	view: ^Changes_View,
	state: ^Changes_State,
	pointer: [2]f32,
) -> render.Build_Status {
	s := g.scale
	rule := render.Rect{g.toolbar.x, g.toolbar.y + g.toolbar.height - s, g.toolbar.width, s}
	draw_rect(list, {rect = rule, color = theme.border})
	@(static, rodata)
	labels := CHANGES_SCOPE_LABELS
	if g.scope.width > 0 {
		if r := dropdown_field_draw(list, text, theme, g.scope, labels[view.scope], state.scope_open, s); r != .Ok {
			return r
		}
		hover, press := changes_lit(state, {.Scope, 0})
		b := Button{rect = g.scope, hover = hover, press = press, radius = RADIUS_CONTROL, surface = .Flat_Unfilled}
		if _, _, err := button_draw(list, theme, b, s, pointer); err != .None {return .Ok}
	}
	if g.worktree.width > 0 {
		if r := dropdown_field_draw(
			list, text, theme, g.worktree, clip_bytes(view.worktree, CHANGES_CLIP_BYTES), state.worktree_open, s,
		); r != .Ok {
			return r
		}
		hover, press := changes_lit(state, {.Worktree, 0})
		b := Button {
			rect = g.worktree, hover = hover, press = press, radius = RADIUS_CONTROL, surface = .Flat_Unfilled,
		}
		if _, _, err := button_draw(list, theme, b, s, pointer); err != .None {return .Ok}
	}
	small := text_styled(text, .Detail)
	note := changes_scope_turns(view.scope) ? view.repository : (view.following ? CHANGES_FOLLOWING_LABEL : "")
	if note != "" && g.repository.width > 0 {
		if r := draw_fading_text(
			&small, list, clip_bytes(note, CHANGES_CLIP_BYTES), g.repository.x,
			baseline_in(g.repository.y, g.repository.height, &small),
			theme.muted, g.repository.width,
		); r != .Ok {return r}
	}
	if g.hooks.width > 0 {
		radius := RADIUS_CONTROL * s
		draw_rect(list, {rect = g.hooks, color = theme.surface, radius = radius})
		draw_rect(list, {rect = g.hooks, color = theme.border, radius = radius, stroke = s})
		hover, press := changes_lit(state, {.Hooks, 0})
		b := Button{rect = g.hooks, hover = hover, press = press, radius = RADIUS_CONTROL, surface = .Flat_Unfilled}
		face, _, err := button_draw(list, theme, b, s, pointer)
		if err != .None {return .Ok}
		body := text_styled(text, .Body)
		inset := CONTROL_INSET * s
		width := min(text_width(&body, CHANGES_HOOKS_LABEL), max(0, face.width - 2 * inset))
		return draw_text(
			&body, list, CHANGES_HOOKS_LABEL, face.x + (face.width - width) / 2,
			baseline_in(face.y, face.height, &body), theme.text, max(1, face.width - 2 * inset),
		)
	}
	return .Ok
}
