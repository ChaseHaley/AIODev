package ui

import "aio:render"

// The horizontal title-bar tab strip. It shares the title-bar height so the strip, the workspace
// chip and the caption controls all sit in the same 40 DIP row.
TAB_HEIGHT :: TITLE_BAR_HEIGHT

Tab_Bar :: struct {
	x, width, height, tab_width, button_width: f32,
	count:                                     int,
}

// The strip spans `width` from `x`. Its `count` tabs share their width with `incoming` tabs a drag
// offers, which hold their space without counting as tabs yet.
tab_bar_layout :: proc(x, width, scale: f32, count: int, incoming := 0) -> Tab_Bar {
	bar := Tab_Bar{x = x, height = TAB_HEIGHT * scale}
	slots := count + incoming
	if slots < 1 {return bar}
	bar.width, bar.count = width, count
	bar.button_width = min(width, TITLE_BUTTON_WIDTH * scale)
	bar.tab_width = min(220 * scale, max(0, width - bar.button_width) / f32(slots))
	return bar
}

tab_drop_region :: proc(bar: Tab_Bar, width, scale: f32) -> render.Rect {
	left := bar.x + f32(bar.count) * bar.tab_width
	return {left, 0, max(0, width - CAPTION_WIDTH * scale - left), bar.height}
}

tab_drop_hit :: proc(bar: Tab_Bar, width, scale, x, y: f32) -> bool {
	r := tab_drop_region(bar, width, scale)
	return r.width > 0 && render.rect_contains(r, x, y)
}

// The tab whose resting slot is under the point.
tab_at :: proc(bar: Tab_Bar, x, y: f32) -> (index: int, ok: bool) {
	local_x := x - bar.x
	if bar.count == 0 || bar.tab_width <= 0 || local_x < 0 || y < 0 || y >= bar.height {
		return -1, false
	}
	index = int(local_x / bar.tab_width)
	return index < bar.count ? index : -1, index < bar.count
}

// The new-tab button, just after the last tab.
tab_new_rect :: proc(bar: Tab_Bar) -> render.Rect {
	return {bar.x + f32(bar.count) * bar.tab_width, 0, bar.button_width, bar.height}
}

// The picture at the start of a tab: a content kind's icon, else the session's program badge.
Tab_Badge :: struct {
	icon:  Icon,
	shell: string,
	atlas: render.Rect,
}

tab_badge_shown :: proc(b: Tab_Badge) -> bool {
	return b.icon != .None || b.shell != "" || b.atlas.width > 0
}

// What a tab shows in the strip and the rail. Each orientation lays it out with its own geometry.
Tab_Tile :: struct {
	title:        string,
	badge:        Tab_Badge,
	status:       Status_Mark,
	status_phase: f32,
	// Tab status indicators are on: the status keeps its place, so titles do not reflow as
	// programs start and stop working.
	status_slot:  bool,
	selected:     bool,
	marked:       bool,
}

// Draws the badge in the leading icon column of `tile`.
tab_badge_draw :: proc(
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	tile: render.Rect,
	t: Tab_Tile,
	scale: f32,
) -> render.Build_Status {
	size := ICON_BUTTON * scale
	area := render.Rect{tile.x + CONTROL_INSET * scale, tile.y + (tile.height - size) / 2, size, size}
	if t.badge.icon != .None {
		ink := t.selected ? theme.tab_active_text : theme.tab_text
		icon_draw(list, t.badge.icon, area, ink, ICON_BUTTON, scale)
		return .Ok
	}
	return shell_badge_draw(list, text, theme, area, t.badge.shell, scale, t.badge.atlas)
}

// Draws the status progress along the bottom of `band`, inset from the tile's rounded ends.
tab_progress_draw :: proc(
	list: ^render.Draw_List,
	theme: Theme,
	band: render.Rect,
	status: Status_Mark,
	scale: f32,
) {
	bar := render.Rect{band.x + 8 * scale, band.y, max(0, band.width - 16 * scale), band.height}
	status_progress_draw(list, theme, bar, status, scale)
}

// The selected tab's underline under the tab at slot `position`, raised by the tab's hover `lift`.
tab_underline_rect :: proc(bar: Tab_Bar, position, lift, scale: f32) -> render.Rect {
	x := bar.x + position * bar.tab_width + 10 * scale
	return {x, 30 * scale - lift, max(0, bar.tab_width - 20 * scale), 2 * scale}
}

// The toolbar-height tile every strip control (tabs, new tab, profiles) draws on, raised by its hover.
tab_tile_rect :: proc(bar: Tab_Bar, x, width, lift, scale: f32) -> render.Rect {
	tile_height := HEIGHT_TOOLBAR * scale
	return {x + 2 * scale, (bar.height - tile_height) / 2 - lift, max(0, width - 4 * scale), tile_height}
}

// Draws tab `index` at slot `position`, which differs from the index while tabs move.
tab_draw :: proc(
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	bar: Tab_Bar,
	index: int,
	position: f32,
	t: Tab_Tile,
	hover, pressed, scale: f32,
	pointer: [2]f32 = {},
) -> render.Build_Status {
	x := bar.x + position * bar.tab_width
	width := bar.tab_width
	if render.push_layer(list, {x, 0, width, bar.height}) != .None {return .Ok}
	draw_rect(list, {rect = {x, 0, width, bar.height}, color = theme.tab_bar})
	// Every tab rises on hover; the selected tab keeps its pane fill while it moves.
	lift := hover_lift_at(theme, hover, scale)
	tile := tab_tile_rect(bar, x, width, lift, scale)
	radius := RADIUS_CONTROL * scale
	indicator := ICON_INDICATOR * scale
	if lift > 0 {
		if result := hover_shadow_draw(list, theme, tile, radius, hover, scale); result != .None {return .Ok}
	}
	if t.selected {
		draw_rect(list, {rect = tile, color = theme.tab_active, radius = radius})
		draw_rect(list, {rect = tile, color = theme.border, radius = radius, stroke = scale})
	}
	if t.marked && !t.selected {
		draw_rect(list, {rect = tile, color = theme.selection, radius = radius})
		draw_rect(list, {rect = tile, color = theme.accent, radius = radius, stroke = scale})
	}
	fill := theme.hover
	fill.a *= hover
	// A marked tab already carries the selection tint; an opaque paper fill would paint over
	// it, while a translucent dark fill can pass over without hiding it.
	skip_fill := hover_fill_opaque(theme) && t.marked && !t.selected
	if !skip_fill {
		draw_rect(list, {rect = tile, color = fill, radius = radius})
	}
	fill = theme.pressed
	fill.a *= pressed
	draw_rect(list, {rect = tile, color = fill, radius = radius})
	if width <= 16 * scale {return .Ok}
	if close := tab_close_rect(bar, index, position, scale); close.width > 0 {
		close.y -= lift
		icon_draw(list, .Close, close, theme.tab_text, ICON_INDICATOR, scale)
	}
	icon_width, status_width := f32(0), f32(0)
	if t.status.glyph != .None {
		tab_progress_draw(list, theme, {tile.x, tile.y, tile.width, tile.height - scale}, t.status, scale)
	}
	// Status sits just before Close; a tab narrower than 90 DIPs keeps no empty slot for it.
	if width >= 56 * scale && (t.status_slot && width >= 90 * scale || t.status.glyph != .None) {
		status_width = (ICON_INDICATOR + SPACE_1) * scale
		if t.status.glyph != .None {
			if result := status_glyph_draw(
				list,
				text,
				theme,
				{x + width - 44 * scale, tile.y + (tile.height - indicator) / 2, indicator, indicator},
				t.status,
				t.status_phase,
				scale,
			); result != .Ok {return result}
		}
	}
	// A tab too narrow for both drops the program icon before the status.
	if width >= 72 * scale + status_width && tab_badge_shown(t.badge) {
		icon_width = (ICON_BUTTON + SPACE_2) * scale
		if result := tab_badge_draw(list, text, theme, tile, t, scale); result != .Ok {return result}
	}
	if result := draw_fading_text(
		text,
		list,
		t.title,
		tile.x + CONTROL_INSET * scale + icon_width,
		(bar.height - text.line_height) / 2 + text.ascent - lift,
		t.selected ? theme.tab_active_text : theme.tab_text,
		max(0, width - 44 * scale - icon_width - status_width),
	); result != .Ok {return result}
	if hover > 0 {
		if result := hover_rim_draw(list, theme, tile, radius, hover, scale, pointer, !skip_fill);
		   result != .None {return .Ok}
	}
	return .Ok
}

// Draws the new-tab button after the last tab.
tab_new_draw :: proc(
	list: ^render.Draw_List,
	theme: Theme,
	bar: Tab_Bar,
	hover, pressed, scale: f32,
	pointer: [2]f32 = {},
) -> render.Build_Status {
	r := tab_new_rect(bar)
	if render.push_layer(list, r) != .None {return .Ok}
	draw_rect(list, {rect = r, color = theme.tab_bar})
	lift := hover_lift_at(theme, hover, scale)
	tile := tab_tile_rect(bar, r.x, r.width, lift, scale)
	radius := RADIUS_CONTROL * scale
	if lift > 0 {
		if result := hover_shadow_draw(list, theme, tile, radius, hover, scale); result != .None {return .Ok}
	}
	fill := theme.hover
	fill.a *= hover
	draw_rect(list, {rect = tile, color = fill, radius = radius})
	fill = theme.pressed
	fill.a *= pressed
	draw_rect(list, {rect = tile, color = fill, radius = radius})
	if r.width <= 16 * scale {return .Ok}
	icon_draw(list, .Add, tile, hover > 0 || pressed > 0 ? theme.text : theme.muted, ICON_BUTTON, scale)
	if hover > 0 {
		if result := hover_rim_draw(list, theme, tile, radius, hover, scale, pointer, true, compact = true);
		   result != .None {return .Ok}
	}
	return .Ok
}

// The close button of tab `index` at slot `position`; none on a tab too narrow to show it.
tab_close_rect :: proc(bar: Tab_Bar, index: int, position: f32, scale: f32) -> render.Rect {
	if index < 0 || index >= bar.count || bar.tab_width < 56 * scale {return {}}
	button := HEIGHT_COMPACT * scale
	x := bar.x + f32(index + 1) * bar.tab_width - 4 * scale - button
	x += (position - f32(index)) * bar.tab_width
	return {x, (bar.height - button) / 2, button, button}
}

// The resting tab whose close button is under the point.
tab_close_hit :: proc(bar: Tab_Bar, x, y, scale: f32) -> (index: int, ok: bool) {
	index, ok = tab_at(bar, x, y)
	if !ok {return -1, false}
	r := tab_close_rect(bar, index, f32(index), scale)
	if r.width > 0 && render.rect_contains(r, x, y) {return index, true}
	return -1, false
}
