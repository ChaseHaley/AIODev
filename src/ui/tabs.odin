package ui

import "aio:glyphs"
import "aio:render"

TAB_HEIGHT :: f32(40)

Tab_Bar :: struct {
	width, height, tab_width, button_width: f32,
	count: int,
	x: f32,
}

tab_bar_layout :: proc(width, scale: f32, count: int) -> Tab_Bar {
	if count < 1 { return {} }
	button := min(width, 32*scale)
	return {width, TAB_HEIGHT*scale, min(220*scale, max(0, width-button)/f32(count)), button, count, 0}
}

tab_drop_region :: proc(bar: Tab_Bar, width, scale: f32) -> render.Rect {
	left := bar.x+f32(bar.count)*bar.tab_width
	return {left, 0, max(0, width-138*scale-left), bar.height}
}

tab_drop_hit :: proc(bar: Tab_Bar, width, scale, x, y: f32) -> bool {
	r := tab_drop_region(bar, width, scale)
	return r.width > 0 && x >= r.x && x < r.x+r.width && y >= r.y && y < r.y+r.height
}

// The count is the new-tab button; -1 is outside the controls.
tab_bar_hit_test :: proc(bar: Tab_Bar, x, y: f32) -> int {
	local_x := x-bar.x
	if bar.count == 0 || local_x < 0 || local_x >= bar.width || y < 0 || y >= bar.height { return -1 }
	end := bar.tab_width*f32(bar.count)
	if local_x >= end { return local_x < end+bar.button_width ? bar.count : -1 }
	return bar.tab_width > 0 ? int(local_x/bar.tab_width) : -1
}

tab_draw :: proc(
	list: ^render.Draw_List, text: ^Text, theme: Theme, bar: Tab_Bar,
	index: int, title: string, selected: bool, scale: f32, hover: f32 = 0, pressed: f32 = 0,
	underline: f32 = -1,
	position: f32 = -1, marked: bool = false, icon: string = "", icon_atlas: render.Rect = {},
) -> glyphs.Result {
	x := f32(index)*bar.tab_width
	if position >= 0 { x = position }
	width := bar.tab_width
	if index == bar.count { x, width = f32(bar.count)*bar.tab_width, bar.button_width }
	x += bar.x
	if render.push_layer(list, {x, 0, width, bar.height}) != .None { return .Ok }
	draw_rect(list, {rect = {x, 0, width, bar.height}, color = theme.chrome})
	tile := render.Rect{x+2*scale, 6*scale, max(0, width-4*scale), 28*scale}
	if selected {
		draw_rect(list, {rect = tile, color = theme.pane, radius = 7*scale})
		draw_rect(list, {rect = tile, color = theme.border, radius = 7*scale, stroke = scale})
	}
	if marked && !selected {
		draw_rect(list, {rect = tile, color = theme.selection, radius = 7*scale})
		draw_rect(list, {rect = tile, color = theme.accent, radius = 7*scale, stroke = scale})
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
	if index < bar.count && width >= 56*scale {
		close := tab_close_rect(bar, index, scale)
		close.x += x-bar.x-f32(index)*bar.tab_width
		large := text^
		text_set_size(&large, text.size_px*1.5)
		if result := draw_glyph_centered(&large, list, '×', close, theme.muted); result != .Ok { return result }
	}
	icon_width := f32(0)
	if index < bar.count && width >= 72*scale && (icon != "" || icon_atlas.width > 0) {
		icon_width = 22*scale
		if result := shell_badge_draw(list, text, theme, {x+10*scale, 13*scale, 14*scale, 14*scale},
			icon, scale, icon_atlas); result != .Ok { return result }
	}
	return draw_fading_text(text, list, title, x+11*scale+icon_width,
		(bar.height-text.line_height)/2+text.ascent, selected ? theme.text : theme.muted,
		max(0, width-(index < bar.count ? 44 : 22)*scale-icon_width))
}

tab_selection_update :: proc(marked: []bool, index, anchor: int, toggle, range: bool) {
	if index < 0 || index >= len(marked) { return }
	if range {
		first := clamp(anchor, 0, len(marked)-1)
		for &value, i in marked {
			inside := i >= min(first, index) && i <= max(first, index)
			value = inside || (toggle && value)
		}
	} else if toggle { marked[index] = !marked[index] }
	else {
		for &value, i in marked { value = i == index }
	}
}

// `slot` counts unselected tabs preceding the group. The result indexes the original strip.
tab_group_order :: proc(marked: []bool, slot: int, out: []int) -> bool {
	if len(out) != len(marked) { return false }
	count := 0
	for value in marked { if value { count += 1 } }
	if count == 0 || slot < 0 || slot > len(marked)-count { return false }
	at, unmarked := 0, 0
	for value, i in marked {
		if value { continue }
		if unmarked == slot {
			for selected, j in marked { if selected { out[at] = j; at += 1 } }
		}
		out[at], at, unmarked = i, at+1, unmarked+1
	}
	if unmarked == slot {
		for selected, j in marked { if selected { out[at] = j; at += 1 } }
	}
	return true
}

tab_close_rect :: proc(bar: Tab_Bar, index: int, scale: f32) -> render.Rect {
	if index < 0 || index >= bar.count || bar.tab_width < 56*scale { return {} }
	return {bar.x+f32(index+1)*bar.tab_width-28*scale, 9*scale, 22*scale, 22*scale}
}

tab_close_hit :: proc(bar: Tab_Bar, x, y, scale: f32) -> int {
	index := tab_bar_hit_test(bar, x, y)
	r := tab_close_rect(bar, index, scale)
	if r.width > 0 && x >= r.x && x < r.x+r.width && y >= r.y && y < r.y+r.height { return index }
	return -1
}

caption_hit :: proc(width, x, y, scale: f32) -> int {
	if y < 0 || y >= TAB_HEIGHT*scale || x < width-138*scale || x >= width { return -1 }
	return clamp(int((x-width+138*scale)/(46*scale)), 0, 2)
}

caption_draw :: proc(list: ^render.Draw_List, text: ^Text, theme: Theme, width, scale: f32,
	hover, pressed: int, maximized: bool) -> glyphs.Result {
	if render.push_layer(list, {0, 0, width, TAB_HEIGHT*scale}) != .None { return .Ok }
	for i in 0..<3 {
		r := render.Rect{width-f32(3-i)*46*scale, 0, 46*scale, TAB_HEIGHT*scale}
		ink := theme.text
		if i == hover {
			fill := i == pressed ? theme.pressed : theme.hover
			if i == 2 { fill, ink = {0.77, 0.17, 0.11, 1}, {1, 1, 1, 1} }
			draw_rect(list, {rect = r, color = fill})
		}
		icon := ([3]rune{'\ue921', maximized ? '\ue923' : '\ue922', '\ue8bb'})[i]
		if result := draw_icon(text, list, icon, r, ink, 0.4); result != .Ok { return result }
	}
	return .Ok
}

leader_status_layout :: proc(area: render.Rect, width, scale: f32) -> render.Rect {
	padding := min(8*scale, area.width/4, area.height/4)
	height := min(22*scale, max(0, area.height-2*padding))
	return {area.x+padding, area.y+area.height-padding-height,
		min(max(0, area.width-2*padding), width+16*scale), height}
}

leader_status_draw :: proc(list: ^render.Draw_List, text: ^Text, theme: Theme, area: render.Rect,
	chord: string, scale: f32) -> glyphs.Result {
	small := text_styled(text, .Small)
	keycap := text_styled(text, .Keycap)
	hint := "Leader · awaiting key"
	key_width := text_width(&keycap, chord)
	r := leader_status_layout(area, key_width+8*scale+text_width(&small, hint), scale)
	if r.height < small.line_height || r.width <= 16*scale { return .Ok }
	if render.push_layer(list, r) != .None { return .Ok }
	draw_rect(list, {rect = r, color = theme.pane})
	baseline := r.y+(r.height-small.line_height)/2+small.ascent
	if result := draw_text(&keycap, list, chord, r.x+8*scale, baseline, theme.accent,
		max(0, r.width-16*scale)); result != .Ok { return result }
	return draw_text(&small, list, hint, r.x+8*scale+key_width+8*scale, baseline, theme.muted,
		max(0, r.width-key_width-24*scale))
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
