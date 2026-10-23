package ui

import "aio:glyphs"
import "aio:platform"
import "aio:render"
import "base:runtime"

MENU_WIDTH :: f32(280)
MENU_ROW_HEIGHT :: f32(30)
MENU_SEPARATOR_HEIGHT :: f32(9)
MENU_MAX_ITEMS :: 40

Menu_Item :: struct {
	label, shortcut, icon: string,
	icon_atlas:            render.Rect,
	checked, enabled:      bool,
	separator:             bool,
}

Menu :: struct {
	open:                 bool,
	items:                [dynamic]Menu_Item,
	selected, scroll:     int,
	anchor_x, anchor_y:   f32,
}

menu_init :: proc(m: ^Menu, allocator := context.allocator) {
	m.items.allocator = allocator
}

menu_destroy :: proc(m: ^Menu) {
	delete(m.items)
	m^ = {}
}

menu_clear :: proc(m: ^Menu) {
	clear(&m.items)
	m.selected, m.scroll = 0, 0
}

menu_add :: proc(m: ^Menu, item: Menu_Item) -> runtime.Allocator_Error {
	if len(m.items) >= MENU_MAX_ITEMS {return nil}
	_, err := append(&m.items, item)
	return err
}

menu_anchor :: proc(m: ^Menu, x, y: f32) {
	m.anchor_x, m.anchor_y = x, y
}

menu_row_height :: proc(m: ^Menu, index: int) -> f32 {
	item := m.items[index]
	return item.separator ? MENU_SEPARATOR_HEIGHT : MENU_ROW_HEIGHT
}

menu_step :: proc(m: ^Menu, step: int, wrap := true) {
	if len(m.items) == 0 || step == 0 {return}
	direction := step > 0 ? 1 : -1
	index := m.selected
	for _ in 0..<len(m.items) {
		index += direction
		if !wrap && (index < 0 || index >= len(m.items)) {return}
		index = (index + len(m.items)) % len(m.items)
		item := m.items[index]
		if !item.separator && item.enabled {
			m.selected = index
			return
		}
	}
}

// Clamps the surface into the window and returns the visible rows.
menu_layout :: proc(
	m: ^Menu,
	width, height, scale: f32,
) -> (
	render.Rect,
	int,
) {
	rows := 0
	content := 8 * scale
	for i in m.scroll..<len(m.items) {
		next := menu_row_height(m, i) * scale
		if rows > 0 && content + next > height - 16 * scale {break}
		content += next
		rows += 1
	}
	surface_width := min(MENU_WIDTH * scale, width - 16 * scale)
	x := clamp(m.anchor_x, 8 * scale, max(8 * scale, width - surface_width - 8 * scale))
	y := clamp(m.anchor_y, 8 * scale, max(8 * scale, height - content - 8 * scale))
	return {x, y, surface_width, content}, rows
}

menu_row_rect :: proc(m: ^Menu, index: int, width, height, scale: f32) -> render.Rect {
	surface, _ := menu_layout(m, width, height, scale)
	y := surface.y + 4 * scale
	for i in m.scroll..<index {y += menu_row_height(m, i) * scale}
	return {
		surface.x + 4 * scale,
		y,
		surface.width - 8 * scale,
		menu_row_height(m, index) * scale,
	}
}

menu_hit :: proc(m: ^Menu, x, y, width, height, scale: f32) -> int {
	surface, rows := menu_layout(m, width, height, scale)
	if x < surface.x ||
	   x >= surface.x + surface.width ||
	   y < surface.y + 4 * scale ||
	   y >= surface.y + surface.height - 4 * scale {return -1}
	for i in m.scroll..<m.scroll + rows {
		row := menu_row_rect(m, i, width, height, scale)
		if y >= row.y && y < row.y + row.height {return i}
	}
	return -1
}

Menu_Outcome :: enum {
	None,
	Changed,
	Chosen,
	Closed,
}

menu_key :: proc(m: ^Menu, e: platform.Key_Event) -> Menu_Outcome {
	if !e.pressed {return .None}
	if step := list_step(e); step != 0 {
		menu_step(m, step)
		return .Changed
	}
	#partial switch e.key {
	case .Escape, .Context_Menu:
		m.open = false
		return .Closed
	case .Home:
		m.selected = -1
		menu_step(m, 1)
		return .Changed
	case .End:
		m.selected = len(m.items)
		menu_step(m, -1)
		return .Changed
	case .Enter, .Numpad_Enter, .Space:
		if m.selected >= 0 && m.selected < len(m.items) {
			item := m.items[m.selected]
			if item.enabled && !item.separator {return .Chosen}
		}
	}
	return .None
}

menu_wheel :: proc(m: ^Menu, rows: int) {
	menu_step(m, -rows, false)
}

menu_draw :: proc(
	m: ^Menu,
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	width, height, scale: f32,
) -> glyphs.Result {
	if !m.open {return .Ok}
	if m.selected >= len(m.items) {m.selected = len(m.items) - 1}
	surface, rows := menu_layout(m, width, height, scale)
	for m.scroll + rows <= m.selected {m.scroll += 1; surface, rows = menu_layout(m, width, height, scale)}
	if m.selected >= 0 && m.selected < m.scroll {
		m.scroll = m.selected
		surface, rows = menu_layout(m, width, height, scale)
	}
	if render.push_layer(list, {0, 0, width, height}) != .None {return .Ok}
	frame := Panel {
		rect     = surface,
		radius   = 8 * scale,
		scale    = scale,
		shadow_y = 5,
		softness = 16,
		border   = .Stroked,
	}
	if panel_draw(list, frame, theme) != .None {return .Ok}
	if render.push_layer(list, surface, 8 * scale) != .None {return .Ok}
	small := text_styled(text, .Small)
	for visible in 0..<rows {
		i := m.scroll + visible
		if i >= len(m.items) {break}
		item := m.items[i]
		row := menu_row_rect(m, i, width, height, scale)
		if item.separator {
			if render.push_rect(
				list,
				{
					rect = {row.x + 10 * scale, row.y + 4 * scale, row.width - 20 * scale, scale},
					color = theme.border,
				},
			) != .None {return .Ok}
			continue
		}
		if i == m.selected && item.enabled {
			if render.push_rect(list, {rect = row, color = theme.selection, radius = 4 * scale}) !=
			   .None {return .Ok}
		}
		if item.checked {
			if render.push_rect(
				list,
				{
					rect = {row.x + scale, row.y + 8 * scale, 3 * scale, row.height - 16 * scale},
					color = theme.accent,
					radius = 2 * scale,
				},
			) != .None {return .Ok}
		}
		label_x := row.x + 10 * scale
		if item.icon != "" || item.icon_atlas.width > 0 {
			icon_width := 22 * scale
			if result := shell_badge_draw(
				list,
				text,
				theme,
				{row.x + 8 * scale, row.y + (row.height - 16 * scale) / 2, 16 * scale, 16 * scale},
				item.icon,
				scale,
				item.icon_atlas,
			); result != .Ok {return result}
			label_x += icon_width
		}
		shortcut_width := f32(0)
		if item.shortcut != "" {
			shortcut_width = text_width(&small, item.shortcut)
			if result := draw_text(
				&small,
				list,
				item.shortcut,
				row.x + row.width - 10 * scale - shortcut_width,
				row.y + (row.height - small.line_height) / 2 + small.ascent,
				theme.faint,
			); result != .Ok {return result}
		}
		if result := draw_text(
			text,
			list,
			item.label,
			label_x,
			row.y + (row.height - text.line_height) / 2 + text.ascent,
			item.enabled ? theme.text : theme.muted,
			max(1, row.x + row.width - 18 * scale - shortcut_width - label_x),
		); result != .Ok {return result}
	}
	return .Ok
}
