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

// Clamps the highlight to `count` options and scrolls so it sits on one of CHOICE_LIST_ROWS rows.
choice_list_keep_visible :: proc(c: ^Choice_List, count: int) {
	c.index = clamp(c.index, 0, max(0, count - 1))
	if c.index < c.scroll {c.scroll = c.index}
	if c.index >= c.scroll + CHOICE_LIST_ROWS {c.scroll = c.index - CHOICE_LIST_ROWS + 1}
	c.scroll = clamp(c.scroll, 0, max(0, count - CHOICE_LIST_ROWS))
}

choice_list_move :: proc(c: ^Choice_List, delta, count: int) {
	c.index += delta
	choice_list_keep_visible(c, count)
}

// Steps the highlight with list_step's chords, and Page Up or Page Down by a list's height.
choice_list_key :: proc(c: ^Choice_List, e: input.Key_Event, count: int) -> bool {
	delta := list_step(e)
	#partial switch e.key {
	case .Page_Up:
		delta = -CHOICE_LIST_ROWS
	case .Page_Down:
		delta = CHOICE_LIST_ROWS
	}
	if delta == 0 || !e.pressed {return false}
	choice_list_move(c, delta, count)
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
