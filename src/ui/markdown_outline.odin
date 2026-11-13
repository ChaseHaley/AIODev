package ui

import "aio:markdown"
import "aio:render"
import "core:math"

// The heading outline at a Markdown page's right edge (WORK-439): a short bar per heading, longer for
// shallower levels, with the section being read in the accent. Hovering the bars opens a panel naming
// every heading, and a bar or a row scrolls its heading to the top. The headings are collected once per
// layout of the view; a frame only places them.

// Bar lengths by depth below the document's shallowest heading level; deeper headings share the last.
@(private = "file", rodata)
BAR_LENGTHS := [?]f32{14, 11, 8, 5}
@(private = "file")
BAR_THICKNESS :: f32(2)
// The bar pitch while the column fits the page. More headings squeeze it down to the minimum, and past
// that the bars sample the headings evenly.
@(private = "file")
BAR_PITCH :: f32(8)
@(private = "file")
BAR_PITCH_MIN :: f32(4)
// The bars end this far from the page's right edge, clear of the overlay scrollbar's track.
@(private = "file")
OUTLINE_INSET :: SPACE_4
// The strip that opens the panel: wider than the bars so the pointer finds them easily, and ending where
// the scrollbar's track begins.
@(private = "file")
OUTLINE_STRIP :: f32(24)
@(private = "file")
PANEL_WIDTH_MIN :: f32(120)
@(private = "file")
PANEL_WIDTH_MAX :: f32(280)
@(private = "file")
PANEL_ROW :: HEIGHT_COMPACT
@(private = "file")
PANEL_INDENT :: SPACE_3
// A jump scrolls a heading's line to the whole pixel at or above it, and a heading just under the top
// of the page is the one being read; either counts as reached.
@(private = "file")
CURRENT_SLACK :: SPACE_2

Markdown_Outline_Heading :: struct {
	// The heading's text in the document.
	start, end: int,
	level:      int,
	// The top of its first line in the view.
	top:        f32,
}

// A Markdown pane keeps one beside its view; only the procs in this file write it.
Markdown_Outline :: struct {
	headings:    [dynamic]Markdown_Outline_Heading,
	// The view layout the headings were measured in; see Markdown_View.layouts.
	layout:      u64,
	// The shallowest heading level: its bars are the longest and its rows are not indented.
	top_level:   int,
	// The panel's width, measured the first time it opens after a layout; zero until then.
	panel_width: f32,
	// How far the panel's rows are scrolled, in pixels.
	scroll:      f32,
}

// Where the bars sit: `count` bars `pitch` apart down from `top`, ending at `right`, inside the strip
// that opens the panel.
Markdown_Outline_Column :: struct {
	strip:      render.Rect,
	right, top: f32,
	pitch:      f32,
	count:      int,
}

Markdown_Outline_Panel :: struct {
	rect:    render.Rect,
	// The rows' full height, which scrolls inside the rect when taller.
	content: f32,
}

markdown_outline_destroy :: proc(o: ^Markdown_Outline) {
	delete(o.headings)
	o^ = {}
}

// Collects the document's headings and the tops of their lines, once per layout of the view. `doc` is
// the document the view was laid out for.
markdown_outline_sync :: proc(o: ^Markdown_Outline, v: ^Markdown_View, doc: ^markdown.Document) {
	if o.layout == v.layouts {return}
	o.layout, o.top_level, o.panel_width, o.scroll = v.layouts, 0, 0, 0
	clear(&o.headings)
	line := 0
	for block in doc.blocks {
		if block.kind != .Heading {continue}
		text, start := markdown.block_text(doc, block)
		if text == "" {continue}
		// Headings come in document order, so each one's line is at or after the previous one's.
		for line < len(v.lines) && !line_reaches(v, line, start) {line += 1}
		top := line < len(v.lines) ? v.lines[line].top : v.height
		if _, err := append(&o.headings, Markdown_Outline_Heading{start, start + len(text), block.level, top});
		   err != nil {
			// A partial outline would leave sections out; show none.
			clear(&o.headings)
			return
		}
		o.top_level = o.top_level == 0 ? block.level : min(o.top_level, block.level)
	}
}

// Whether line `index` shows `offset` or text after it, as markdown_offset_top asks.
@(private = "file")
line_reaches :: proc(v: ^Markdown_View, index, offset: int) -> bool {
	line := v.lines[index]
	for i in 0 ..< line.run_count {
		if int(v.runs[line.first_run + i].end) > offset {return true}
	}
	return false
}

// The heading of the section being read: the last one whose line is at or above the top of the page as
// scrolled, or the first when none is yet. -1 without headings.
markdown_outline_current :: proc(o: ^Markdown_Outline, v: ^Markdown_View) -> int {
	if len(o.headings) == 0 {return -1}
	limit := f32(v.scroll) + CURRENT_SLACK * v.scale
	low, high := 0, len(o.headings)
	for low < high {
		middle := (low + high) / 2
		if o.headings[middle].top <= limit {low = middle + 1} else {high = middle}
	}
	return max(0, low - 1)
}

// Where the bars go on a page at `g`. Not shown without headings, or when the page is too narrow for
// the bars to stay clear of the text column.
markdown_outline_column :: proc(
	o: ^Markdown_Outline,
	g: Markdown_Geometry,
	scale: f32,
) -> (
	column: Markdown_Outline_Column,
	shown: bool,
) {
	count := len(o.headings)
	if count == 0 {return}
	area := g.area
	right := area.x + area.width - OUTLINE_INSET * scale
	if right - BAR_LENGTHS[0] * scale < g.left + g.width + SPACE_2 * scale {return}
	room := area.height - 2 * SPACE_4 * scale
	pitch := BAR_PITCH * scale
	if f32(count) * pitch > room {
		pitch = room / f32(count)
		if pitch < BAR_PITCH_MIN * scale {
			pitch = BAR_PITCH_MIN * scale
			count = int(room / pitch)
		}
	}
	if count <= 0 {return}
	height := f32(count) * pitch
	top := math.round(area.y + (area.height - height) / 2)
	strip_width := OUTLINE_STRIP * scale
	strip := render.Rect {
		right + SPACE_1 * scale - strip_width,
		top - SPACE_2 * scale,
		strip_width,
		height + 2 * SPACE_2 * scale,
	}
	return {strip, right, top, pitch, count}, true
}

// The heading bar `bar` stands for. With fewer bars than headings, the bars sample them evenly.
markdown_outline_bar_heading :: proc(o: ^Markdown_Outline, column: Markdown_Outline_Column, bar: int) -> int {
	return bar * len(o.headings) / column.count
}

// The bar standing for `heading`: the last one whose heading is at or before it.
markdown_outline_heading_bar :: proc(
	o: ^Markdown_Outline,
	column: Markdown_Outline_Column,
	heading: int,
) -> int {
	return ((heading + 1) * column.count - 1) / len(o.headings)
}

markdown_outline_bar_rect :: proc(
	o: ^Markdown_Outline,
	column: Markdown_Outline_Column,
	bar: int,
	scale: f32,
) -> render.Rect {
	level := o.headings[markdown_outline_bar_heading(o, column, bar)].level
	length := BAR_LENGTHS[clamp(level - o.top_level, 0, len(BAR_LENGTHS) - 1)] * scale
	thickness := max(1, math.round(BAR_THICKNESS * scale))
	y := math.round(column.top + f32(bar) * column.pitch + (column.pitch - thickness) / 2)
	return {column.right - length, y, length, thickness}
}

// The bar nearest a point on the strip, or -1 off it.
markdown_outline_bar_at :: proc(column: Markdown_Outline_Column, x, y: f32) -> int {
	if !render.rect_contains(column.strip, x, y) {return -1}
	return clamp(int(math.floor((y - column.top) / column.pitch)), 0, column.count - 1)
}

@(private = "file")
heading_text :: proc(doc: ^markdown.Document, heading: Markdown_Outline_Heading) -> string {
	return string(doc.text[heading.start:heading.end])
}

@(private = "file")
heading_indent :: proc(o: ^Markdown_Outline, heading: Markdown_Outline_Heading, scale: f32) -> f32 {
	return f32(max(0, heading.level - o.top_level)) * PANEL_INDENT * scale
}

// The panel hanging left of the strip in `area`, centred on the bars and kept inside the area. Its
// width fits the widest heading, measured the first time after a layout.
markdown_outline_panel :: proc(
	o: ^Markdown_Outline,
	doc: ^markdown.Document,
	column: Markdown_Outline_Column,
	area: render.Rect,
	text: ^Text,
	scale: f32,
) -> Markdown_Outline_Panel {
	padding := OVERLAY_PADDING * scale
	if o.panel_width == 0 {
		frame := 2 * (padding + CONTROL_INSET * scale)
		limit := PANEL_WIDTH_MAX * scale - frame
		widest := f32(0)
		for heading in o.headings {
			widest = max(widest, heading_indent(o, heading, scale) + text_width(text, heading_text(doc, heading)))
			if widest >= limit {break}
		}
		o.panel_width = clamp(widest + frame, PANEL_WIDTH_MIN * scale, PANEL_WIDTH_MAX * scale)
	}
	margin := SPACE_2 * scale
	right := column.strip.x
	width := min(o.panel_width, max(0, right - area.x - margin))
	content := f32(len(o.headings)) * PANEL_ROW * scale + 2 * padding
	height := min(content, max(0, area.height - 2 * margin))
	middle := column.top + f32(column.count) * column.pitch / 2
	lowest := area.y + margin
	y := clamp(math.round(middle - height / 2), lowest, max(lowest, area.y + area.height - margin - height))
	o.scroll = clamp(o.scroll, 0, content - height)
	return {{right - width, y, width, height}, content}
}

markdown_outline_row_rect :: proc(
	o: ^Markdown_Outline,
	panel: Markdown_Outline_Panel,
	row: int,
	scale: f32,
) -> render.Rect {
	padding := OVERLAY_PADDING * scale
	height := PANEL_ROW * scale
	return {
		panel.rect.x + padding,
		panel.rect.y + padding + f32(row) * height - o.scroll,
		panel.rect.width - 2 * padding,
		height,
	}
}

// The row under a point, -1 on the panel's padding; `inside` is whether the point is on the panel.
markdown_outline_row_at :: proc(
	o: ^Markdown_Outline,
	panel: Markdown_Outline_Panel,
	x, y, scale: f32,
) -> (
	row: int,
	inside: bool,
) {
	if !render.rect_contains(panel.rect, x, y) {return -1, false}
	padding := OVERLAY_PADDING * scale
	if y < panel.rect.y + padding || y >= panel.rect.y + panel.rect.height - padding {return -1, true}
	row = int(math.floor((y - panel.rect.y - padding + o.scroll) / (PANEL_ROW * scale)))
	return row < len(o.headings) ? row : -1, true
}

markdown_outline_scrollable :: proc(panel: Markdown_Outline_Panel) -> bool {
	return panel.content > panel.rect.height
}

// Scrolls the panel's rows by `delta` pixels, as far as they go; false when nothing moved.
@(private = "file")
scroll_by :: proc(o: ^Markdown_Outline, panel: Markdown_Outline_Panel, delta: f32) -> bool {
	before := o.scroll
	o.scroll = clamp(o.scroll + delta, 0, max(0, panel.content - panel.rect.height))
	return o.scroll != before
}

// Rows are wheel rows, positive toward the top; each moves the panel by one of its own rows.
markdown_outline_wheel :: proc(
	o: ^Markdown_Outline,
	panel: Markdown_Outline_Panel,
	rows: int,
	scale: f32,
) -> bool {
	return scroll_by(o, panel, -f32(rows) * PANEL_ROW * scale)
}

// Scrolls the panel so row `row` sits in its middle, as far as the rows allow.
markdown_outline_reveal :: proc(o: ^Markdown_Outline, panel: Markdown_Outline_Panel, row: int, scale: f32) {
	height := PANEL_ROW * scale
	o.scroll = 0
	scroll_by(o, panel, f32(row) * height - (panel.rect.height - height) / 2)
}

// Draws the bars over the page at `g` and, while `open`, the panel. `hovered` is the heading under the
// pointer, or -1.
markdown_outline_draw :: proc(
	o: ^Markdown_Outline,
	v: ^Markdown_View,
	doc: ^markdown.Document,
	g: Markdown_Geometry,
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	open: bool,
	hovered: int,
	scale: f32,
) -> render.Build_Status {
	column, shown := markdown_outline_column(o, g, scale)
	if !shown {return .Ok}
	// A layer of its own puts the bars and the panel over the page's text.
	if render.push_layer(list, g.area, 0) != .None {return .Ok}
	current := markdown_outline_current(o, v)
	current_bar := markdown_outline_heading_bar(o, column, current)
	hovered_bar := hovered >= 0 ? markdown_outline_heading_bar(o, column, hovered) : -1
	for bar in 0 ..< column.count {
		rect := markdown_outline_bar_rect(o, column, bar, scale)
		color := theme.faint
		if bar == hovered_bar {color = theme.muted}
		if bar == current_bar {color = theme.accent}
		draw_rect(list, {rect = rect, color = color, radius = pill_radius(rect)})
	}
	if !open {return .Ok}
	panel := markdown_outline_panel(o, doc, column, g.area, text, scale)
	if panel_draw(list, popover_panel(panel.rect, scale), theme) != .None {return .Ok}
	if render.push_layer(list, panel.rect, RADIUS_OVERLAY * scale) != .None {return .Ok}
	inset := CONTROL_INSET * scale
	bottom := panel.rect.y + panel.rect.height
	for row := max(0, int(o.scroll / (PANEL_ROW * scale))); row < len(o.headings); row += 1 {
		rect := markdown_outline_row_rect(o, panel, row, scale)
		if rect.y >= bottom {break}
		if row == hovered {draw_rect(list, {rect = rect, color = theme.hover, radius = RADIUS_CONTROL * scale})}
		heading := o.headings[row]
		x := rect.x + inset + heading_indent(o, heading, scale)
		ink := row == current ? theme.accent : theme.text
		baseline := math.round(rect.y + (rect.height - text.line_height) / 2 + text.ascent)
		available := max(1, rect.x + rect.width - inset - x)
		if result := draw_text(text, list, heading_text(doc, heading), x, baseline, ink, available); result != .Ok {
			return result
		}
	}
	return .Ok
}
