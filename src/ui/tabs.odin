package ui

import "aio:glyphs"
import "aio:render"

TAB_HEIGHT :: f32(36)

Tab_Bar :: struct {
	width, height, tab_width, button_width: f32,
	count: int,
}

tab_bar_layout :: proc(width, scale: f32, count: int, show_with_one_tab: bool) -> Tab_Bar {
	if count < 1 || (count == 1 && !show_with_one_tab) { return {} }
	button := min(width, 32*scale)
	return {width, TAB_HEIGHT*scale, min(220*scale, max(0, width-button)/f32(count)), button, count}
}

// The count is the new-tab button; -1 is outside the controls.
tab_bar_hit_test :: proc(bar: Tab_Bar, x, y: f32) -> int {
	if bar.count == 0 || x < 0 || x >= bar.width || y < 0 || y >= bar.height { return -1 }
	end := bar.tab_width*f32(bar.count)
	if x >= end { return x < end+bar.button_width ? bar.count : -1 }
	return bar.tab_width > 0 ? int(x/bar.tab_width) : -1
}

tab_draw :: proc(
	list: ^render.Draw_List, text: ^Text, theme: Theme, bar: Tab_Bar,
	index: int, title: string, selected: bool, scale: f32, hover: f32 = 0, pressed: f32 = 0,
	underline: f32 = -1,
) -> glyphs.Result {
	x := f32(index)*bar.tab_width
	width := bar.tab_width
	if index == bar.count { x, width = f32(bar.count)*bar.tab_width, bar.button_width }
	if render.push_layer(list, {x, 0, width, bar.height}) != .None { return .Ok }
	draw_rect(list, {rect = {x, 0, width, bar.height}, color = theme.chrome})
	tile := render.Rect{x+2*scale, 4*scale, max(0, width-4*scale), 28*scale}
	if selected {
		draw_rect(list, {rect = tile, color = theme.pane, radius = 7*scale})
		draw_rect(list, {rect = tile, color = theme.border, radius = 7*scale, stroke = scale})
	}
	fill := theme.hover
	fill.a *= hover
	draw_rect(list, {rect = tile, color = fill, radius = 7*scale})
	fill = theme.pressed
	fill.a *= pressed
	draw_rect(list, {rect = tile, color = fill, radius = 7*scale})
	if selected && underline < 0 {
		draw_rect(list, {rect = {x+10*scale, 30*scale, max(0, width-20*scale), 2*scale},
			color = theme.accent, radius = scale})
	}
	if width <= 16*scale { return .Ok }
	return draw_fading_text(text, list, title, x+11*scale, (bar.height-text.line_height)/2+text.ascent,
		selected ? theme.text : theme.muted, width-22*scale)
}

pane_message_draw :: proc(
	list: ^render.Draw_List, text: ^Text, theme: Theme, area: render.Rect, message: string, scale: f32, radius: f32 = 0,
) -> glyphs.Result {
	if render.push_layer(list, area, radius) != .None { return .Ok }
	padding := min(10*scale, area.width/4)
	lines := make([dynamic]string, context.temp_allocator)
	wrap(text, message, max(1, area.width-2*padding), &lines)
	height := min(area.height, f32(len(lines))*text.line_height+2*padding)
	top := area.y+area.height-height
	draw_rect(list, {rect = {area.x, top, area.width, height}, color = theme.surface})
	draw_rect(list, {rect = {area.x, top, area.width, 1}, color = theme.accent})
	for line, i in lines {
		if result := draw_text(text, list, line, area.x+padding,
			top+padding+f32(i)*text.line_height+text.ascent, theme.text); result != .Ok { return result }
	}
	return .Ok
}
