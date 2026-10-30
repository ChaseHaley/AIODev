package ui

import "aio:glyphs"
import "aio:render"

// The horizontal title-bar tab strip. It shares the title-bar height so the strip, the workspace
// chip and the caption controls all sit in the same 40 DIP row.
TAB_HEIGHT :: TITLE_BAR_HEIGHT

Tab_Bar :: struct {
	width, height, tab_width, button_width: f32,
	count:                                  int,
	x:                                      f32,
}

tab_bar_layout :: proc(width, scale: f32, count: int) -> Tab_Bar {
	if count < 1 {return {}}
	button := min(width, 32 * scale)
	return {
		width,
		TAB_HEIGHT * scale,
		min(220 * scale, max(0, width - button) / f32(count)),
		button,
		count,
		0,
	}
}

tab_drop_region :: proc(bar: Tab_Bar, width, scale: f32) -> render.Rect {
	left := bar.x + f32(bar.count) * bar.tab_width
	return {left, 0, max(0, width - 138 * scale - left), bar.height}
}

tab_drop_hit :: proc(bar: Tab_Bar, width, scale, x, y: f32) -> bool {
	r := tab_drop_region(bar, width, scale)
	return r.width > 0 && x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height
}

// The count is the new-tab button; -1 is outside the controls.
tab_bar_hit_test :: proc(bar: Tab_Bar, x, y: f32) -> int {
	local_x := x - bar.x
	if bar.count == 0 ||
	   local_x < 0 ||
	   local_x >= bar.width ||
	   y < 0 ||
	   y >= bar.height {return -1}
	end := bar.tab_width * f32(bar.count)
	if local_x >= end {return local_x < end + bar.button_width ? bar.count : -1}
	return bar.tab_width > 0 ? int(local_x / bar.tab_width) : -1
}

tab_draw :: proc(
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	bar: Tab_Bar,
	index: int,
	title: string,
	selected: bool,
	scale: f32,
	hover: f32 = 0,
	pressed: f32 = 0,
	underline: f32 = -1,
	position: f32 = -1,
	marked: bool = false,
	icon: string = "",
	icon_atlas: render.Rect = {},
	pointer: [2]f32 = {},
	status: Status_Mark = {},
	status_phase: f32 = 0,
) -> glyphs.Result {
	x := f32(index) * bar.tab_width
	if position >= 0 {x = position}
	width := bar.tab_width
	if index == bar.count {x, width = f32(bar.count) * bar.tab_width, bar.button_width}
	x += bar.x
	if render.push_layer(list, {x, 0, width, bar.height}) != .None {return .Ok}
	draw_rect(list, {rect = {x, 0, width, bar.height}, color = theme.tab_bar})
	// Every tab rises on hover; the selected tab keeps its pane fill while it moves.
	lift := hover_lift_at(theme, hover, scale)
	tile := render.Rect{x + 2 * scale, 6 * scale - lift, max(0, width - 4 * scale), 28 * scale}
	if lift > 0 {
		if result := hover_shadow_draw(list, theme, tile, 7 * scale, hover, scale);
		   result != .None {return .Ok}
	}
	if selected {
		draw_rect(list, {rect = tile, color = theme.tab_active, radius = 7 * scale})
		draw_rect(list, {rect = tile, color = theme.border, radius = 7 * scale, stroke = scale})
	}
	if marked && !selected {
		draw_rect(list, {rect = tile, color = theme.selection, radius = 7 * scale})
		draw_rect(list, {rect = tile, color = theme.accent, radius = 7 * scale, stroke = scale})
	}
	fill := theme.hover
	fill.a *= hover
	// A marked tab already carries the selection tint; an opaque paper fill would paint over
	// it, while a translucent dark fill can pass over without hiding it.
	skip_fill := hover_fill_opaque(theme) && marked && !selected
	if !skip_fill {
		draw_rect(list, {rect = tile, color = fill, radius = 7 * scale})
	}
	fill = theme.pressed
	fill.a *= pressed
	draw_rect(list, {rect = tile, color = fill, radius = 7 * scale})
	if selected && underline < 0 {
		draw_rect(
			list,
			{
				rect = {x + 10 * scale, 30 * scale, max(0, width - 20 * scale), 2 * scale},
				color = theme.tab_indicator,
				radius = scale,
			},
		)
	}
	if width <= 16 * scale {return .Ok}
	if index < bar.count && width >= 56 * scale {
		close := tab_close_rect(bar, index, scale)
		close.x += x - bar.x - f32(index) * bar.tab_width
		close.y -= lift
		large := text^
		text_set_size(&large, text.size_px * 1.5)
		if result := draw_glyph_centered(&large, list, '×', close, theme.tab_text);
		   result != .Ok {return result}
	}
	icon_width := f32(0)
	if index < bar.count && status.glyph != .None {
		status_progress_draw(
			list,
			theme,
			{tile.x + 8 * scale, tile.y, max(0, tile.width - 16 * scale), tile.height - scale},
			status,
			scale,
		)
	}
	if index < bar.count && width >= 56 * scale && status.glyph != .None {
		icon_width = 22 * scale
		if result := status_glyph_draw(
			list,
			text,
			theme,
			{x + 10 * scale, 13 * scale - lift, 14 * scale, 14 * scale},
			status,
			status_phase,
			scale,
		); result != .Ok {return result}
	} else if index < bar.count && width >= 72 * scale && (icon != "" || icon_atlas.width > 0) {
		icon_width = 22 * scale
		if result := shell_badge_draw(
			list,
			text,
			theme,
			{x + 10 * scale, 13 * scale - lift, 14 * scale, 14 * scale},
			icon,
			scale,
			icon_atlas,
		); result != .Ok {return result}
	}
	if result := draw_fading_text(
		text,
		list,
		title,
		x + 11 * scale + icon_width,
		(bar.height - text.line_height) / 2 + text.ascent - lift,
		selected ? theme.tab_active_text : theme.tab_text,
		max(0, width - (index < bar.count ? 44 : 22) * scale - icon_width),
	); result != .Ok {return result}
	if hover > 0 {
		if result := hover_rim_draw(list, theme, tile, 7 * scale, hover, scale, pointer, !skip_fill);
		   result != .None {return .Ok}
	}
	return .Ok
}

tab_close_rect :: proc(bar: Tab_Bar, index: int, scale: f32) -> render.Rect {
	if index < 0 || index >= bar.count || bar.tab_width < 56 * scale {return {}}
	return {bar.x + f32(index + 1) * bar.tab_width - 28 * scale, 9 * scale, 22 * scale, 22 * scale}
}

tab_close_hit :: proc(bar: Tab_Bar, x, y, scale: f32) -> int {
	index := tab_bar_hit_test(bar, x, y)
	r := tab_close_rect(bar, index, scale)
	if r.width > 0 &&
	   x >= r.x &&
	   x < r.x + r.width &&
	   y >= r.y &&
	   y < r.y + r.height {return index}
	return -1
}
