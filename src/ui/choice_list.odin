package ui

import "aio:input"
import "aio:render"

// Dropdowns show at most this many options and scroll the rest.
CHOICE_LIST_ROWS :: 8

// The highlighted option and the first option shown of an open dropdown: the palette's choice list,
// the Settings choice popup and the shortcut alternatives. Owners keep the options and their count,
// and draw them in their own surface's style.
Choice_List :: struct {
	index, scroll: int,
}

// Eight DIPs of page margin on either side plus the popup's own eight-DIP inset.
choice_list_rows :: proc(count: int, page_height, scale: f32, header_height: f32 = 0) -> int {
	return min(count, CHOICE_LIST_ROWS,
	           max(1, int((page_height - 24 * scale - header_height) / (CHOICE_HEIGHT * scale))))
}

// Clamps the highlight and keeps it inside the caller's fitted number of rows.
choice_list_keep_visible :: proc(c: ^Choice_List, count, visible: int) {
	c.index = clamp(c.index, 0, max(0, count - 1))
	if c.index < c.scroll {c.scroll = c.index}
	rows := max(1, visible)
	if c.index >= c.scroll + rows {c.scroll = c.index - rows + 1}
	c.scroll = clamp(c.scroll, 0, max(0, count - rows))
}

choice_list_move :: proc(c: ^Choice_List, delta, count, visible: int) {
	c.index += delta
	choice_list_keep_visible(c, count, visible)
}

// Steps the highlight with list_step's chords, and Page Up or Page Down by a list's height.
choice_list_key :: proc(c: ^Choice_List, e: input.Key_Event, count, visible: int) -> bool {
	delta := list_step(e)
	#partial switch e.key {
	case .Page_Up:
		delta = -max(1, visible)
	case .Page_Down:
		delta = max(1, visible)
	}
	if delta == 0 || !e.pressed {return false}
	choice_list_move(c, delta, count, visible)
	return true
}

// Scrolls to `offset` with `visible` rows shown, keeping the highlight on one of them. Reports
// whether the list moved.
choice_list_scroll_to :: proc(c: ^Choice_List, offset, count, visible: int) -> bool {
	scroll := clamp(offset, 0, max(0, count - visible))
	moved := scroll != c.scroll
	c.scroll = scroll
	c.index = clamp(c.index, scroll, max(0, scroll + visible - 1))
	return moved
}

// The option under `y` when the first shown row starts at `top`, or -1 outside the `visible` rows.
choice_list_at :: proc(c: Choice_List, top, row_height, y: f32, count, visible: int) -> int {
	if y < top || row_height <= 0 {return -1}
	row := int((y - top) / row_height)
	if row >= visible {return -1}
	index := c.scroll + row
	return index < count ? index : -1
}

// Places a dropdown measured below its row: above the row when the page has no room below, then
// inside the page's margin.
dropdown_place :: proc(r, row, page: render.Rect, scale: f32) -> render.Rect {
	s := scale
	r := r
	if r.y + r.height > page.y + page.height - 8 * s {r.y = row.y - r.height - 4 * s}
	r.width = min(r.width, page.width - 16 * s)
	r.x = clamp(r.x, page.x + 8 * s, max(page.x + 8 * s, page.x + page.width - r.width - 8 * s))
	r.y = clamp(r.y, page.y + 8 * s, max(page.y + 8 * s, page.y + page.height - r.height - 8 * s))
	return r
}
