package ui

import "aio:input"
import "aio:render"
import "base:runtime"

MENU_WIDTH :: f32(280)
MENU_ROW_HEIGHT :: HEIGHT_STANDARD
// A hairline with SPACE_1 above and below.
MENU_SEPARATOR_HEIGHT :: 2 * SPACE_1 + 1
// Enough for the longest owner: a profile menu's settings.PROFILE_LIMIT profiles and its separator,
// Settings and Command Palette rows.
MENU_MAX_ITEMS :: 72

Menu_Item :: struct {
	label, shortcut, icon: string,
	icon_atlas:            render.Rect,
	checked, enabled:      bool,
	separator:             bool,
	// A line icon in place of a badge, inked like the label.
	glyph:                 Icon,
	// Secondary text after the label, fading out where it runs out of room.
	detail:                string,
	// A compact button at the row's end, and one beyond it that shows while the row is selected.
	action:                Icon,
	selected_action:       Icon,
	// The label is an error.
	danger:                bool,
	// The owner's key for what choosing the row does; the menu only carries it.
	payload:               u32,
}

Menu_Row_Part :: enum {
	Row,
	Action,
	Selected_Action,
}

// Whether a menu shows is its owner's state; the menu holds its rows and the selection within them.
Menu :: struct {
	items:                [dynamic]Menu_Item,
	selection:            Maybe(int),
	// The first row shown as of the last selection change, so moving the selection within the visible
	// rows keeps them still. Drawing and hit testing show the selection even when it has not caught up.
	scroll:               int,
	anchor_x, anchor_y:   f32,
	// An embedded menu may stay inside its owning pane; zero uses the whole window.
	bounds:               render.Rect,
	// The surface's width in DIPs; zero is MENU_WIDTH.
	width:                f32,
	// The row button under the pointer, on the selected row.
	hover_part:           Menu_Row_Part,
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
	menu_select(m, -1)
	m.scroll = 0
}

// Added is false when the menu already holds MENU_MAX_ITEMS rows; the error is the append's.
menu_add :: proc(m: ^Menu, item: Menu_Item) -> (added: bool, error: runtime.Allocator_Error) {
	if len(m.items) >= MENU_MAX_ITEMS {return false, nil}
	if _, error = append(&m.items, item); error != nil {return false, error}
	if len(m.items) == 1 {menu_select(m, 0)}
	return true, nil
}

// The row, or -1 for no selection at the row-index interface.
menu_selected :: proc(m: ^Menu) -> int {
	index, selected := m.selection.?
	return selected ? index : -1
}

// The only writer of the selection. Negative or removed rows mean no selection; drawing never repairs it.
menu_select :: proc(m: ^Menu, index: int) {
	m.selection = nil
	if index >= 0 && index < len(m.items) {m.selection = index}
}

menu_anchor :: proc(m: ^Menu, x, y: f32) {
	m.anchor_x, m.anchor_y = x, y
}

menu_row_height :: proc(m: ^Menu, index: int) -> f32 {
	item := m.items[index]
	return item.separator ? MENU_SEPARATOR_HEIGHT : MENU_ROW_HEIGHT
}

// Moves the selection to the next enabled row in the step's direction. False leaves it where it was.
menu_step :: proc(m: ^Menu, step: int, wrap := true) -> bool {
	if len(m.items) == 0 || step == 0 {return false}
	direction := step > 0 ? 1 : -1
	index := menu_selected(m)
	for _ in 0..<len(m.items) {
		index += direction
		if !wrap && (index < 0 || index >= len(m.items)) {return false}
		index = (index + len(m.items)) % len(m.items)
		item := m.items[index]
		if !item.separator && item.enabled {
			menu_select(m, index)
			return true
		}
	}
	return false
}

// An edge search uses a local cursor: a failed search cannot leave an out-of-range selection behind.
menu_select_edge :: proc(m: ^Menu, last: bool) {
	for offset in 0..<len(m.items) {
		index := last ? len(m.items) - offset - 1 : offset
		item := m.items[index]
		if !item.separator && item.enabled {menu_select(m, index); return}
	}
}

// Stores the first row the selection needs, so later moves inside the visible rows keep them still.
menu_reveal :: proc(m: ^Menu, width, height, scale: f32) {
	_, _, m.scroll = menu_view(m, width, height, scale)
}

@(private = "file")
menu_bounds :: proc(m: ^Menu, width, height: f32) -> render.Rect {
	return m.bounds.width > 0 ? m.bounds : {0, 0, width, height}
}

// The surface height and how many rows fit when the list starts at row `first`.
@(private = "file")
menu_extent :: proc(m: ^Menu, first: int, bounds: render.Rect, scale: f32) -> (content: f32, rows: int) {
	content = 2 * OVERLAY_PADDING * scale
	for i in first..<len(m.items) {
		next := menu_row_height(m, i) * scale
		if rows > 0 && content + next > bounds.height - 16 * scale {break}
		content += next
		rows += 1
	}
	return
}

// The surface, the visible row count and the first visible row: the stored scroll, moved only as far as
// showing the selection needs.
@(private = "file")
menu_view :: proc(m: ^Menu, width, height, scale: f32) -> (surface: render.Rect, rows, first: int) {
	bounds := menu_bounds(m, width, height)
	first = clamp(m.scroll, 0, max(0, len(m.items) - 1))
	selected := menu_selected(m)
	if selected >= 0 && selected < first {first = selected}
	content: f32
	content, rows = menu_extent(m, first, bounds, scale)
	for first + rows <= selected && selected < len(m.items) {
		first += 1
		content, rows = menu_extent(m, first, bounds, scale)
	}
	surface_width := min((m.width > 0 ? m.width : MENU_WIDTH) * scale, max(0, bounds.width - 16 * scale))
	left, top := bounds.x + 8 * scale, bounds.y + 8 * scale
	x := clamp(m.anchor_x, left, max(left, bounds.x + bounds.width - surface_width - 8 * scale))
	y := clamp(m.anchor_y, top, max(top, bounds.y + bounds.height - content - 8 * scale))
	return {x, y, surface_width, content}, rows, first
}

// Clamps the surface into the window and returns the visible rows.
menu_layout :: proc(
	m: ^Menu,
	width, height, scale: f32,
) -> (
	render.Rect,
	int,
) {
	surface, rows, _ := menu_view(m, width, height, scale)
	return surface, rows
}

menu_row_rect :: proc(m: ^Menu, index: int, width, height, scale: f32) -> render.Rect {
	surface, _, first := menu_view(m, width, height, scale)
	y := surface.y + OVERLAY_PADDING * scale
	for i in first..<index {y += menu_row_height(m, i) * scale}
	return {
		surface.x + OVERLAY_PADDING * scale,
		y,
		surface.width - 2 * OVERLAY_PADDING * scale,
		menu_row_height(m, index) * scale,
	}
}

menu_hit :: proc(m: ^Menu, x, y, width, height, scale: f32) -> int {
	surface, rows, first := menu_view(m, width, height, scale)
	if x < surface.x ||
	   x >= surface.x + surface.width ||
	   y < surface.y + OVERLAY_PADDING * scale ||
	   y >= surface.y + surface.height - OVERLAY_PADDING * scale {return -1}
	for i in first..<first + rows {
		row := menu_row_rect(m, i, width, height, scale)
		if y >= row.y && y < row.y + row.height {return i}
	}
	return -1
}

// Where a row's button sits. Its slot is kept even while the button is hidden, so labels hold still.
menu_action_rect :: proc(
	m: ^Menu,
	index: int,
	part: Menu_Row_Part,
	width, height, scale: f32,
) -> render.Rect {
	row := menu_row_rect(m, index, width, height, scale)
	size := HEIGHT_COMPACT * scale
	inset := (row.height - size) / 2
	slot: f32 = part == .Selected_Action ? 1 : 2
	return {row.x + row.width - inset - slot * size, row.y + inset, size, size}
}

// The part of row `index` at the point. Only buttons the row is showing count.
menu_row_part :: proc(m: ^Menu, index: int, x, y, width, height, scale: f32) -> Menu_Row_Part {
	if index < 0 || index >= len(m.items) {return .Row}
	item := m.items[index]
	if item.action != .None {
		if render.rect_contains(menu_action_rect(m, index, .Action, width, height, scale), x, y) {return .Action}
	}
	if item.selected_action != .None && index == menu_selected(m) {
		if render.rect_contains(menu_action_rect(m, index, .Selected_Action, width, height, scale), x, y) {
			return .Selected_Action
		}
	}
	return .Row
}

Menu_Outcome :: enum {
	None,
	Changed,
	Chosen,
	Closed,
}

// Closed asks the owner to close the menu; whether it shows is the owner's state.
menu_key :: proc(m: ^Menu, e: input.Key_Event) -> Menu_Outcome {
	if !e.pressed {return .None}
	if step := list_step(e); step != 0 {
		menu_step(m, step)
		return .Changed
	}
	#partial switch e.key {
	case .Escape, .Context_Menu:
		return .Closed
	case .Home:
		menu_select_edge(m, false)
		return .Changed
	case .End:
		menu_select_edge(m, true)
		return .Changed
	case .Enter, .Numpad_Enter, .Space:
		if selected := menu_selected(m); selected >= 0 && selected < len(m.items) {
			item := m.items[selected]
			if item.enabled && !item.separator {return .Chosen}
		}
	}
	return .None
}

menu_wheel :: proc(m: ^Menu, rows: int) {
	menu_step(m, -rows, false)
}

// Draws the rows around the selection; it reads the menu and changes nothing in it.
menu_draw :: proc(
	m: ^Menu,
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	width, height, scale: f32,
	pointer: [2]f32 = {},
) -> render.Build_Status {
	surface, rows, first := menu_view(m, width, height, scale)
	selected := menu_selected(m)
	if !popover_open(list, surface, theme, width, height, scale) {return .Ok}
	small := text_styled(text, .Detail)
	inset := CONTROL_INSET * scale
	for visible in 0..<rows {
		i := first + visible
		if i >= len(m.items) {break}
		item := m.items[i]
		row := menu_row_rect(m, i, width, height, scale)
		if item.separator {
			if render.push_rect(
				list,
				{
					rect = {row.x + inset, row.y + 4 * scale, row.width - 2 * inset, scale},
					color = theme.border,
				},
			) != .None {return .Ok}
			continue
		}
		if i == selected && item.enabled {
			if render.push_rect(list, {rect = row, color = theme.selection, radius = RADIUS_CONTROL * scale}) !=
			   .None {return .Ok}
		}
		if item.checked {
			mark := render.Rect{row.x + scale, row.y + 8 * scale, 3 * scale, row.height - 16 * scale}
			if render.push_rect(list, {rect = mark, color = theme.accent, radius = pill_radius(mark)}) !=
			   .None {return .Ok}
		}
		label_x := row.x + inset
		if item.icon != "" || item.icon_atlas.width > 0 {
			icon_width := (16 + SPACE_2) * scale
			if result := shell_badge_draw(
				list,
				text,
				theme,
				{label_x, row.y + (row.height - 16 * scale) / 2, 16 * scale, 16 * scale},
				item.icon,
				scale,
				item.icon_atlas,
			); result != .Ok {return result}
			label_x += icon_width
		}
		ink := item.enabled ? theme.text : theme.muted
		if item.danger {ink = theme.error}
		if item.glyph != .None {
			glyph := render.Rect{label_x, row.y, ICON_BUTTON * scale, row.height}
			icon_draw(list, item.glyph, glyph, ink, ICON_BUTTON, scale)
			label_x += (ICON_BUTTON + SPACE_2) * scale
		}
		end := row.x + row.width - inset
		has_action := item.action != .None
		has_selected_action := item.selected_action != .None
		if has_selected_action {
			end = menu_action_rect(m, i, .Selected_Action, width, height, scale).x
		}
		if has_action {
			end = menu_action_rect(m, i, .Action, width, height, scale).x
		}
		shortcut_width := f32(0)
		if item.shortcut != "" {
			shortcut_width = text_width(&small, item.shortcut)
			if result := draw_text(
				&small,
				list,
				item.shortcut,
				row.x + row.width - inset - shortcut_width,
				row.y + (row.height - small.line_height) / 2 + small.ascent,
				theme.faint,
			); result != .Ok {return result}
		}
		end -= shortcut_width > 0 ? shortcut_width + SPACE_2 * scale : 0
		available := max(1, end - label_x)
		label_baseline := row.y + (row.height - text.line_height) / 2 + text.ascent
		if item.detail == "" {
			if result := draw_text(text, list, item.label, label_x, label_baseline, ink, available);
			   result != .Ok {return result}
		} else {
			label_width := min(text_width(text, item.label), available)
			if result := draw_fading_text(text, list, item.label, label_x, label_baseline, ink, label_width);
			   result != .Ok {return result}
			detail_x := label_x + label_width + SPACE_2 * scale
			if end - detail_x > 0 {
				if result := draw_fading_text(
					&small,
					list,
					item.detail,
					detail_x,
					label_baseline,
					theme.faint,
					end - detail_x,
				); result != .Ok {return result}
			}
		}
		if i == selected && item.enabled && render.rect_contains(row, pointer.x, pointer.y) {
			if result := hover_rim_draw(list, theme, row, RADIUS_CONTROL * scale, 1, scale, pointer);
			   result != .None {return .Ok}
		}
		if item.action != .None {
			hover: f32 = i == selected && m.hover_part == .Action ? 1 : 0
			rect := menu_action_rect(m, i, .Action, width, height, scale)
			if icon_button_draw(list, theme, rect, item.action, hover, 0, scale, pointer,
				radius = RADIUS_CONTROL) != .None {
				return .Ok
			}
		}
		if item.selected_action != .None && i == selected {
			hover: f32 = m.hover_part == .Selected_Action ? 1 : 0
			rect := menu_action_rect(m, i, .Selected_Action, width, height, scale)
			if icon_button_draw(list, theme, rect, item.selected_action, hover, 0, scale, pointer,
				radius = RADIUS_CONTROL) != .None {
				return .Ok
			}
		}
	}
	return .Ok
}
