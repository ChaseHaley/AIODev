package ui

import "aio:render"
import "core:math"

// The vertical tab rail. Width, row rhythm and the dock threshold are shared with the window
// chrome and the settings-free startup geometry, so they live here rather than in one caller.
RAIL_WIDTH :: f32(208)
RAIL_ROW_HEIGHT :: f32(32)
RAIL_FOOTER_HEIGHT :: f32(32)
RAIL_PADDING :: f32(4)
RAIL_TAB_INDENT :: f32(0)
RAIL_TOGGLE_WIDTH :: f32(32)
// A docked 208 rail leaves about 500 DIPs of pane at this width, roughly 60 columns at the
// default font. Narrower than that the rail takes more than a third of the window.
RAIL_DOCK_MIN_WIDTH :: f32(720)

// Whole-pixel rail width: a fractional width subtracted from an integer client width loses a
// column at some DPI scales, so every rail and pane geometry reads this value.
rail_pixel_width :: proc(scale: f32) -> f32 {
	return math.round(RAIL_WIDTH * scale)
}

Rail_Layout :: struct {
	area:           render.Rect,
	list:           render.Rect,
	footer:         render.Rect,
	row_height:     f32,
	scroll:         f32,
	content_height: f32,
	count:          int,
	scale:          f32,
}

rail_layout :: proc(area: render.Rect, scale: f32, count: int, scroll: f32) -> Rail_Layout {
	footer_height := RAIL_FOOTER_HEIGHT * scale
	list_height := max(0, area.height - footer_height)
	layout := Rail_Layout {
		area           = area,
		list           = {area.x, area.y, area.width, list_height},
		footer         = {area.x, area.y + list_height, area.width, footer_height},
		row_height     = RAIL_ROW_HEIGHT * scale,
		content_height = f32(max(0, count)) * RAIL_ROW_HEIGHT * scale + 2 * RAIL_PADDING * scale,
		count          = count,
		scale          = scale,
	}
	layout.scroll = rail_scroll_clamped(layout, scroll)
	return layout
}

rail_scroll_max :: proc(layout: Rail_Layout) -> f32 {
	return max(0, layout.content_height - layout.list.height)
}

rail_scroll_clamped :: proc(layout: Rail_Layout, scroll: f32) -> f32 {
	return clamp(scroll, 0, rail_scroll_max(layout))
}

rail_row_rect :: proc(layout: Rail_Layout, index: int) -> render.Rect {
	if index < 0 || index >= layout.count {return {}}
	padding := RAIL_PADDING * layout.scale
	return {
		layout.list.x + padding,
		layout.list.y + padding + f32(index) * layout.row_height - layout.scroll,
		max(0, layout.list.width - 2 * padding),
		layout.row_height,
	}
}

rail_row_hit :: proc(layout: Rail_Layout, x, y: f32) -> int {
	if layout.count == 0 ||
	   x < layout.list.x ||
	   x >= layout.list.x + layout.list.width ||
	   y < layout.list.y ||
	   y >= layout.list.y + layout.list.height {return -1}
	local := y - layout.list.y - RAIL_PADDING * layout.scale + layout.scroll
	if local < 0 {return -1}
	index := int(math.floor(local / max(1, layout.row_height)))
	return index < layout.count ? index : -1
}

rail_row_contains :: proc(layout: Rail_Layout, index: int, x, y: f32) -> bool {
	row := rail_row_rect(layout, index)
	return x >= row.x && x < row.x + row.width && y >= row.y && y < row.y + row.height
}

// Keeps `index` fully inside the list, moving the scroll only when it is not already visible.
rail_reveal_row :: proc(layout: Rail_Layout, index: int) -> f32 {
	if index < 0 || index >= layout.count {return rail_scroll_clamped(layout, layout.scroll)}
	padding := RAIL_PADDING * layout.scale
	top := padding + f32(index) * layout.row_height
	bottom := top + layout.row_height
	scroll := layout.scroll
	if top - scroll < 0 {
		scroll = top
	} else if bottom - scroll > layout.list.height {
		scroll = bottom - layout.list.height
	}
	return rail_scroll_clamped(layout, scroll)
}

rail_close_rect :: proc(layout: Rail_Layout, index: int, scale: f32) -> render.Rect {
	row := rail_row_rect(layout, index)
	if row.width <= 0 {return {}}
	return {
		row.x + row.width - 26 * scale,
		row.y + (row.height - 22 * scale) / 2,
		22 * scale,
		22 * scale,
	}
}

rail_close_hit :: proc(layout: Rail_Layout, x, y, scale: f32) -> int {
	index := rail_row_hit(layout, x, y)
	r := rail_close_rect(layout, index, scale)
	if r.width > 0 &&
	   x >= r.x &&
	   x < r.x + r.width &&
	   y >= r.y &&
	   y < r.y + r.height {return index}
	return -1
}

rail_footer_hit :: proc(layout: Rail_Layout, x, y: f32) -> bool {
	r := layout.footer
	return x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height
}

rail_footer_tile :: proc(layout: Rail_Layout) -> render.Rect {
	padding := RAIL_PADDING * layout.scale
	return {
		layout.footer.x + padding,
		layout.footer.y + padding,
		max(0, layout.footer.width - 2 * padding),
		max(0, layout.footer.height - 2 * padding),
	}
}

rail_tab_tile :: proc(layout: Rail_Layout, row: render.Rect) -> render.Rect {
	inset := RAIL_TAB_INDENT * layout.scale
	return {row.x + inset, row.y, max(0, row.width - inset), row.height}
}
