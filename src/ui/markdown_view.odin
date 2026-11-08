package ui

import "aio:font"
import "aio:markdown"
import "aio:render"
import "core:log"
import "core:math"

// A rendered Markdown document: every run measured and placed once per width, then drawn only where
// the viewport shows it. Positions are DIP-scaled pixels from the top left of the column.

@(private = "file")
MARKDOWN_COLUMN :: f32(720)
// Reading text is one step above the interface's body size (D-080).
@(private = "file")
MARKDOWN_BODY_RATIO :: f32(15.0 / 13)
@(private = "file")
MARKDOWN_VISUAL_DEPTH :: 6

Markdown_Face :: enum u8 {
	Body,
	Strong,
	Emphasis,
	Strong_Emphasis,
	Code,
	H1,
	H2,
	H3,
}

@(private = "file")
Face_Spec :: struct {
	ratio, leading: f32,
	style:          font.Style,
}

@(private = "file", rodata)
FACE_SPECS := [Markdown_Face]Face_Spec {
	.Body            = {1, 1.5, .Regular},
	.Strong          = {1, 1.5, .Bold},
	.Emphasis        = {1, 1.5, .Italic},
	.Strong_Emphasis = {1, 1.5, .Bold_Italic},
	.Code            = {0.9, 1.5, .Regular},
	.H1              = {1.75, 1.25, .Bold},
	.H2              = {1.4, 1.3, .Bold},
	.H3              = {1.15, 1.35, .Bold},
}

@(private = "file")
Face_Metrics :: struct {
	family:         font.Family,
	style:          font.Style,
	size_px:        f32,
	line_height:    f32,
	// From the line's top to the baseline, with the leading shared above and below.
	baseline:       f32,
}

Markdown_Color :: enum u8 {
	Text,
	Muted,
	Accent,
}

@(private = "file")
Run_Flag :: enum u8 {
	Strike,
	Task_Open,
	Task_Done,
}

@(private = "file")
Run :: struct {
	x, width:   f32,
	start, end: i32,
	link:       i32,
	face:       Markdown_Face,
	color:      Markdown_Color,
	flags:      bit_set[Run_Flag;u8],
}

// Bands never overlap and always increase, even though the cells of a table row share one, so both
// ends of a viewport can be found by binary search.
@(private = "file")
Line :: struct {
	top, height, baseline:  f32,
	band_top, band_bottom:  f32,
	first_run, run_count:   i32,
}

@(private = "file")
Box_Kind :: enum u8 {
	Fill,
	Line,
}

@(private = "file")
Box :: struct {
	rect:   render.Rect,
	kind:   Box_Kind,
	radius: f32,
}

@(private = "file")
Flow_Item :: struct {
	offset:  i32,
	span:    i32,
	advance: f32,
	r:       rune,
}

Markdown_View :: struct {
	runs:       [dynamic]Run,
	lines:      [dynamic]Line,
	boxes:      [dynamic]Box,
	items:      [dynamic]Flow_Item,
	faces:      [Markdown_Face]Face_Metrics,
	fonts:      ^font.System,
	// What the current layout was measured for.
	width:      f32,
	body_px:    f32,
	family:     font.Family,
	mono:       font.Family,
	revision:   u64,
	height:     f32,
	scroll:     int,
	// The selection runs from anchor to head, byte offsets into the document; they are equal when
	// nothing is selected. Only the selection procs below write them.
	anchor:     int,
	head:       int,
	scale:      f32,
	// A layout append failed during this fit; fit discards the partial layout.
	failed:     bool,
}

@(private = "file")
layout_append :: proc(v: ^Markdown_View, array: ^[dynamic]$T, value: T) {
	if _, err := append(array, value); err != nil {v.failed = true}
}

// Where a view sits in its pane.
Markdown_Geometry :: struct {
	area:             render.Rect,
	left, top, width: f32,
}

markdown_view_destroy :: proc(v: ^Markdown_View) {
	delete(v.runs)
	delete(v.lines)
	delete(v.boxes)
	delete(v.items)
	v^ = {}
}

markdown_geometry :: proc(area: render.Rect, scale: f32) -> Markdown_Geometry {
	inset := SPACE_6 * scale
	width := max(0, min(MARKDOWN_COLUMN * scale, area.width - 2 * inset))
	return {
		area = area,
		left = math.round(area.x + (area.width - width) / 2),
		top = area.y + SPACE_4 * scale,
		width = width,
	}
}

// Brings the layout up to date for this document revision, width and set of fonts.
markdown_view_fit :: proc(
	v: ^Markdown_View,
	doc: ^markdown.Document,
	revision: u64,
	t: ^Text,
	mono: font.Family,
	width, scale: f32,
) {
	body_px := math.round(t.size_px * MARKDOWN_BODY_RATIO)
	if v.width == width && v.body_px == body_px && v.family == t.family && v.mono == mono &&
	   v.revision == revision && v.scale == scale {return}
	v.width, v.body_px, v.family, v.mono, v.revision, v.scale = width, body_px, t.family, mono, revision, scale
	v.fonts = t.fonts
	for spec, face in FACE_SPECS {
		family := face == .Code ? mono : t.family
		size := math.round(body_px * spec.ratio)
		m := font.face_metrics(t.fonts, family.faces[spec.style], size)
		natural := m.ascent + m.descent + m.line_gap
		height := math.round(max(natural, size * spec.leading))
		v.faces[face] = {
			family = family,
			style = spec.style,
			size_px = size,
			line_height = height,
			baseline = math.round((height - (m.ascent + m.descent)) / 2 + m.ascent),
		}
	}
	clear(&v.runs)
	clear(&v.lines)
	clear(&v.boxes)
	v.failed = false
	y: f32
	for i := 0; i < len(doc.blocks); {
		i, y = layout_block(v, doc, i, y)
	}
	v.height = y
	if v.failed {
		// Nothing partial is shown or kept as current: the view is empty until a later fit succeeds.
		log.errorf("markdown: no room to lay out the document")
		clear(&v.runs)
		clear(&v.lines)
		clear(&v.boxes)
		v.height, v.width = 0, -1
	}
}

@(private = "file")
face_of :: proc(block: markdown.Block, style: markdown.Style) -> Markdown_Face {
	if block.kind == .Code || .Code in style {return .Code}
	if block.kind == .Heading {
		switch block.level {
		case 1: return .H1
		case 2: return .H2
		case 3: return .H3
		}
		return .Strong
	}
	strong := .Strong in style || block.header
	if strong && .Emphasis in style {return .Strong_Emphasis}
	if strong {return .Strong}
	if .Emphasis in style {return .Emphasis}
	return .Body
}

@(private = "file")
rune_advance :: proc(v: ^Markdown_View, face: Markdown_Face, r: rune) -> f32 {
	m := &v.faces[face]
	if r == '\n' {return 0}
	shown, repeat := r, f32(1)
	if r == '\t' {shown, repeat = ' ', 4}
	g, found := font.glyph_lookup(v.fonts, m.family, m.style, shown)
	if !found {return 0}
	return font.glyph_advance(v.fonts, g, m.size_px) * repeat
}

@(private = "file")
string_advance :: proc(v: ^Markdown_View, face: Markdown_Face, s: string) -> f32 {
	width: f32
	for r in s {width += rune_advance(v, face, r)}
	return width
}

@(private = "file")
breaks_after :: proc(r: rune) -> bool {
	return r == ' ' || r == '\t' || r >= 0x2E80 && r <= 0x9FFF || r >= 0xF900 && r <= 0xFAFF
}

@(private = "file")
items_collect :: proc(v: ^Markdown_View, doc: ^markdown.Document, block: markdown.Block) {
	clear(&v.items)
	for i in 0 ..< block.span_count {
		span := doc.spans[block.first_span + i]
		face := face_of(block, span.style)
		text := string(doc.text[span.start:span.end])
		for r, offset in text {
			item := Flow_Item {
				offset  = i32(span.start + offset),
				span    = i32(block.first_span + i),
				advance = rune_advance(v, face, r),
				r       = r,
			}
			layout_append(v, &v.items, item)
		}
	}
}

// Wraps `v.items` to `width` and places the lines from `y`, returning the y below them. The marker
// hangs to the left of the first line.
@(private = "file")
flow :: proc(
	v: ^Markdown_View,
	doc: ^markdown.Document,
	block: markdown.Block,
	x, width, y: f32,
	color: Markdown_Color,
) -> f32 {
	y := y
	items_collect(v, doc, block)
	emit :: proc(
		v: ^Markdown_View,
		doc: ^markdown.Document,
		block: markdown.Block,
		from, to: int,
		x, width, y: f32,
		color: Markdown_Color,
		first: bool,
	) -> f32 {
		visible := to
		for visible > from && (v.items[visible - 1].r == ' ' || v.items[visible - 1].r == '\t') {visible -= 1}
		line_width: f32
		for item in v.items[from:visible] {line_width += item.advance}
		pen := x
		switch block.align {
		case .Left:
		case .Center: pen += max(0, (width - line_width) / 2)
		case .Right: pen += max(0, width - line_width)
		}
		fallback: Markdown_Face = block.kind == .Heading ? face_of(block, {}) : .Body
		if block.kind == .Code {fallback = .Code}
		height, baseline := v.faces[fallback].line_height, v.faces[fallback].baseline
		if from < visible {height, baseline = 0, 0}
		for item in v.items[from:visible] {
			m := v.faces[face_of(block, doc.spans[item.span].style)]
			height, baseline = max(height, m.line_height), max(baseline, m.baseline)
		}
		line := Line {
			top = y,
			height = height,
			baseline = y + baseline,
			band_top = y,
			band_bottom = y + height,
			first_run = i32(len(v.runs)),
		}
		if first && block.marker_end > block.marker_start {
			text := string(doc.text[block.marker_start:block.marker_end])
			marker_width := string_advance(v, .Body, text)
			flags: bit_set[Run_Flag;u8]
			if block.task != .None {
				marker_width = CHECKBOX_SIZE * v.scale
				flags = block.task == .Open ? {.Task_Open} : {.Task_Done}
			}
			layout_append(
				v,
				&v.runs,
				Run {
					x = x - marker_width - SPACE_2 * v.scale,
					width = marker_width,
					start = i32(block.marker_start),
					end = i32(block.marker_end),
					link = -1,
					face = .Body,
					color = .Muted,
					flags = flags,
				},
			)
		}
		index := from
		for index < visible {
			span := v.items[index].span
			start := index
			run_width: f32
			for index < visible && v.items[index].span == span {
				run_width += v.items[index].advance
				index += 1
			}
			end := index < len(v.items) ? int(v.items[index].offset) : int(doc.spans[span].end)
			style := doc.spans[span].style
			run := Run {
				x = pen,
				width = run_width,
				start = v.items[start].offset,
				end = i32(end),
				link = i32(doc.spans[span].link),
				face = face_of(block, style),
				color = .Link in style ? .Accent : color,
			}
			if .Strike in style {run.flags += {.Strike}}
			layout_append(v, &v.runs, run)
			if .Code in style && block.kind != .Code {
				pad := 3 * v.scale
				rect := render.Rect{pen - pad, y + v.scale, run_width + 2 * pad, height - 2 * v.scale}
				layout_append(v, &v.boxes, Box{rect, .Fill, RADIUS_CONTROL * v.scale})
			}
			pen += run_width
		}
		line.run_count = i32(len(v.runs)) - line.first_run
		layout_append(v, &v.lines, line)
		return y + height
	}
	start, pen, last_break, first := 0, f32(0), -1, true
	i := 0
	ended_on_break := false
	for i < len(v.items) {
		item := v.items[i]
		if item.r == '\n' {
			y = emit(v, doc, block, start, i, x, width, y, color, first)
			first, start, pen, last_break = false, i + 1, 0, -1
			i += 1
			ended_on_break = true
			continue
		}
		ended_on_break = false
		if pen + item.advance > width && i > start && item.r != ' ' {
			split := last_break > start ? last_break : i
			y = emit(v, doc, block, start, split, x, width, y, color, first)
			first, start, pen, last_break, i = false, split, 0, -1, split
			continue
		}
		pen += item.advance
		if breaks_after(item.r) {last_break = i + 1}
		i += 1
	}
	if start < len(v.items) || first || ended_on_break {
		y = emit(v, doc, block, start, len(v.items), x, width, y, color, first)
	}
	return y
}

@(private = "file")
gap_before :: proc(v: ^Markdown_View, doc: ^markdown.Document, index: int) -> f32 {
	if index == 0 {return 0}
	block, previous := doc.blocks[index], doc.blocks[index - 1]
	line := v.faces[.Body].line_height
	if block.kind == .Heading {return math.round(line * (block.level <= 2 ? 1.5 : 1.15))}
	if previous.kind == .Heading {return math.round(line * 0.4)}
	if block.tight {return math.round(2 * v.scale)}
	return math.round(line * 0.7)
}

@(private = "file")
layout_block :: proc(
	v: ^Markdown_View,
	doc: ^markdown.Document,
	index: int,
	y: f32,
) -> (next: int, below: f32) {
	block := doc.blocks[index]
	s := v.scale
	gap := gap_before(v, doc, index)
	y := y
	y += gap
	quote_step, list_step := SPACE_4 * s, SPACE_6 * s
	quotes := min(block.quote_depth, MARKDOWN_VISUAL_DEPTH)
	x := f32(quotes) * quote_step + f32(min(block.list_depth, MARKDOWN_VISUAL_DEPTH)) * list_step
	x = min(x, v.width / 2)
	width := v.width - x
	color: Markdown_Color = quotes > 0 ? .Muted : .Text
	top := y
	next = index + 1
	switch block.kind {
	case .Paragraph, .Heading:
		y = flow(v, doc, block, x, width, y, color)
	case .Code:
		pad := SPACE_3 * s
		box := len(v.boxes)
		layout_append(v, &v.boxes, Box{{x, y, width, 0}, .Fill, RADIUS_CONTROL * s})
		y = flow(v, doc, block, x + pad, max(width - 2 * pad, 1), y + pad, .Text) + pad
		if box < len(v.boxes) {v.boxes[box].rect.height = y - top}
	case .Rule:
		height := max(1, math.round(s))
		layout_append(v, &v.boxes, Box{{x, y, width, height}, .Line, 0})
		y += height
	case .Table_Cell:
		next, y = layout_table(v, doc, index, x, width, y)
	}
	for depth in 0 ..< quotes {
		bar := SPACE_4 * s * f32(depth)
		joined := index > 0 && doc.blocks[index - 1].quote_depth > depth
		reach := joined ? gap : 0
		rect := render.Rect{bar, top - reach, math.round(2 * s), y - top + reach}
		layout_append(v, &v.boxes, Box{rect, .Line, 0})
	}
	return next, y
}

@(private = "file")
layout_table :: proc(
	v: ^Markdown_View,
	doc: ^markdown.Document,
	index: int,
	x, width, y: f32,
) -> (next: int, below: f32) {
	s := v.scale
	table := doc.blocks[index].table
	columns := doc.tables[table].columns
	end := index
	for end < len(doc.blocks) && doc.blocks[end].kind == .Table_Cell && doc.blocks[end].table == table {end += 1}
	natural := make([]f32, columns, context.temp_allocator)
	minimum := make([]f32, columns, context.temp_allocator)
	sizes := make([]f32, columns, context.temp_allocator)
	for block in doc.blocks[index:end] {
		items_collect(v, doc, block)
		line, word: f32
		for item in v.items {
			if item.r == '\n' {line, word = 0, 0; continue}
			line += item.advance
			word = breaks_after(item.r) ? 0 : word + item.advance
			natural[block.column] = max(natural[block.column], line)
			minimum[block.column] = max(minimum[block.column], word)
		}
	}
	pad := SPACE_2 * s
	room := max(width - f32(columns) * 2 * pad, f32(columns))
	total, least: f32
	for i in 0 ..< columns {
		minimum[i] = min(natural[i], minimum[i])
		total, least = total + natural[i], least + minimum[i]
	}
	// When even whole words do not fit, only the longest ones give way, so a short column stays whole.
	limit := max(f32)
	if least > room {
		low, high := f32(1), room
		for _ in 0 ..< 16 {
			limit = (low + high) / 2
			used: f32
			for word in minimum {used += min(word, limit)}
			if used > room {high = limit} else {low = limit}
		}
		limit = low
	}
	for i in 0 ..< columns {
		switch {
		case total <= room:
			sizes[i] = natural[i]
		case least > room:
			sizes[i] = min(minimum[i], limit)
		case:
			sizes[i] = minimum[i] + (room - least) * (natural[i] - minimum[i]) / max(total - least, 1)
		}
		sizes[i] = max(sizes[i], 1)
	}
	table_width: f32
	for size in sizes {table_width += size + 2 * pad}
	y := y
	i := index
	rule := max(1, math.round(s))
	for i < end {
		row := doc.blocks[i].row
		first_line := len(v.lines)
		row_top := y
		bottom := y + pad
		cell_x := x
		column := 0
		for i < end && doc.blocks[i].row == row {
			block := doc.blocks[i]
			for column < block.column {cell_x += sizes[column] + 2 * pad; column += 1}
			bottom = max(bottom, flow(v, doc, block, cell_x + pad, sizes[column], row_top + pad / 2, .Text))
			i += 1
		}
		y = bottom + pad / 2
		for &line in v.lines[first_line:] {line.band_top, line.band_bottom = row_top, y}
		layout_append(v, &v.boxes, Box{{x, y, table_width, rule}, .Line, 0})
		y += rule
	}
	return end, y
}

// The scrollable height, including the space above and below the column.
markdown_total :: proc(v: ^Markdown_View) -> int {
	return int(math.ceil(v.height)) + int(2 * SPACE_4 * v.scale)
}

markdown_scroll_by :: proc(v: ^Markdown_View, delta, visible: int) -> bool {
	before := v.scroll
	v.scroll = clamp(v.scroll + delta, 0, max(0, markdown_total(v) - visible))
	return v.scroll != before
}

// One line of reading text, the unit keys and the wheel scroll by.
markdown_line :: proc(v: ^Markdown_View) -> int {
	return max(1, int(v.faces[.Body].line_height))
}

// The first line whose band reaches below `y`.
@(private = "file")
line_at :: proc(v: ^Markdown_View, y: f32) -> int {
	low, high := 0, len(v.lines)
	for low < high {
		mid := (low + high) / 2
		if v.lines[mid].band_bottom <= y {low = mid + 1} else {high = mid}
	}
	return low
}

@(private = "file")
local_point :: proc(v: ^Markdown_View, g: Markdown_Geometry, x, y: f32) -> (lx, ly: f32) {
	return x - g.left, y - g.top + f32(v.scroll)
}

// The line nearest a point: within the band holding it, the one the point is closest to.
@(private = "file")
nearest_line :: proc(v: ^Markdown_View, lx, ly: f32) -> int {
	if len(v.lines) == 0 {return -1}
	first := min(line_at(v, ly), len(v.lines) - 1)
	band := v.lines[first].band_top
	best, score := first, max(f32)
	for i := first; i < len(v.lines) && v.lines[i].band_top == band; i += 1 {
		line := v.lines[i]
		dy := ly < line.top ? line.top - ly : max(0, ly - line.top - line.height)
		dx: f32
		if line.run_count > 0 {
			left := v.runs[line.first_run].x
			last := v.runs[line.first_run + line.run_count - 1]
			dx = lx < left ? left - lx : max(0, lx - last.x - last.width)
		}
		if distance := dy * 1000 + dx; distance < score {best, score = i, distance}
	}
	return best
}

// The text offset under a point, for placing a selection end.
markdown_offset_at :: proc(
	v: ^Markdown_View,
	doc: ^markdown.Document,
	g: Markdown_Geometry,
	x, y: f32,
) -> int {
	lx, ly := local_point(v, g, x, y)
	index := nearest_line(v, lx, ly)
	if index < 0 {return 0}
	line := v.lines[index]
	if ly < line.top && index == 0 {return 0}
	offset := len(doc.text)
	if index + 1 < len(v.lines) && v.lines[index + 1].run_count > 0 {
		offset = int(v.runs[v.lines[index + 1].first_run].start)
	}
	for i in 0 ..< line.run_count {
		run := v.runs[line.first_run + i]
		if lx < run.x {return int(run.start)}
		if lx >= run.x + run.width {offset = int(run.end); continue}
		pen := run.x
		text := string(doc.text[run.start:run.end])
		for r, at in text {
			advance := rune_advance(v, run.face, r)
			if lx < pen + advance / 2 {return int(run.start) + at}
			pen += advance
		}
		return int(run.end)
	}
	return offset
}

// The link index under a point, or -1.
markdown_link_at :: proc(v: ^Markdown_View, g: Markdown_Geometry, x, y: f32) -> int {
	lx, ly := local_point(v, g, x, y)
	for index := line_at(v, ly); index < len(v.lines) && v.lines[index].band_top <= ly; index += 1 {
		line := v.lines[index]
		if ly < line.top || ly >= line.top + line.height {continue}
		for i in 0 ..< line.run_count {
			run := v.runs[line.first_run + i]
			if lx >= run.x && lx < run.x + run.width {return int(run.link)}
		}
	}
	return -1
}

markdown_selection :: proc(v: ^Markdown_View) -> (from, to: int) {
	return min(v.anchor, v.head), max(v.anchor, v.head)
}

markdown_selected_text :: proc(v: ^Markdown_View, doc: ^markdown.Document) -> string {
	from, to := markdown_selection(v)
	to = min(to, len(doc.text))
	if from >= to {return ""}
	return string(doc.text[from:to])
}

markdown_selection_clear :: proc(v: ^Markdown_View) {
	v.anchor, v.head = 0, 0
}

// A press at `offset` starts a new selection unless `extend` keeps the anchor; a drag extends.
markdown_select_at :: proc(v: ^Markdown_View, offset: int, extend: bool) {
	if !extend {v.anchor = offset}
	v.head = offset
}

markdown_select_all :: proc(v: ^Markdown_View, doc: ^markdown.Document) {
	v.anchor, v.head = 0, len(doc.text)
}

// Scrolls a range of the text into view as a terminal does a match: left alone when it already shows,
// otherwise with its first line at the middle. `visible` is the viewport's height.
markdown_reveal :: proc(v: ^Markdown_View, start, end, visible: int) -> bool {
	top, bottom := max(f32), min(f32)
	scan: for line in v.lines {
		for i in 0 ..< line.run_count {
			run := v.runs[line.first_run + i]
			if int(run.start) >= end {break scan}
			if int(run.end) <= start {continue}
			top, bottom = min(top, line.top), max(bottom, line.top + line.height)
		}
	}
	if top > bottom {return false}
	inset := SPACE_4 * v.scale
	first, last := int(top + inset), int(math.ceil(bottom + inset))
	if first >= v.scroll && last <= v.scroll + visible {return false}
	return markdown_scroll_by(v, first - visible / 2 - v.scroll, visible)
}

// Find's matches, in the colours a terminal gives its own.
Markdown_Find :: struct {
	matches:                                      []markdown.Match,
	selected:                                     int,
	foreground, background, selected_background: render.Color,
}

// The first match that ends after `offset`.
@(private = "file")
match_after :: proc(matches: []markdown.Match, offset: int) -> int {
	low, high := 0, len(matches)
	for low < high {
		middle := (low + high) / 2
		if matches[middle].end <= offset {low = middle + 1} else {high = middle}
	}
	return low
}

@(private = "file")
draw_matches :: proc(
	v: ^Markdown_View,
	doc: ^markdown.Document,
	list: ^render.Draw_List,
	find: Markdown_Find,
	run: Run,
	x, top, height: f32,
) {
	for i := match_after(find.matches, int(run.start));
	    i < len(find.matches) && find.matches[i].start < int(run.end);
	    i += 1 {
		start, stop := max(find.matches[i].start, int(run.start)), min(find.matches[i].end, int(run.end))
		left := string_advance(v, run.face, string(doc.text[run.start:start]))
		middle := string_advance(v, run.face, string(doc.text[start:stop]))
		color := i == find.selected ? find.selected_background : find.background
		draw_rect(list, {rect = {x + left, top, middle, height}, color = color})
	}
}

// Text in a match takes find's colour, except where the selection covers it, as in a terminal.
@(private = "file")
draw_run :: proc(
	v: ^Markdown_View,
	doc: ^markdown.Document,
	text: ^Text,
	list: ^render.Draw_List,
	run: Run,
	x, baseline: f32,
	color: render.Color,
	find: Markdown_Find,
	selected_from, selected_to: int,
) -> render.Build_Status {
	m := &v.faces[run.face]
	shown := text^
	shown.size_px = m.size_px
	pen := x
	next := match_after(find.matches, int(run.start))
	for r, at in string(doc.text[run.start:run.end]) {
		advance := rune_advance(v, run.face, r)
		if r != ' ' && r != '\t' && r != '\n' {
			if g, found := font.glyph_lookup(v.fonts, m.family, m.style, r); found {
				offset := int(run.start) + at
				for next < len(find.matches) && find.matches[next].end <= offset {next += 1}
				matched := next < len(find.matches) && find.matches[next].start <= offset
				in_selection := offset >= selected_from && offset < selected_to
				ink := matched && !in_selection ? find.foreground : color
				if result := draw_glyph(&shown, list, g, pen, baseline, ink); result != .Ok {return result}
			}
		}
		pen += advance
	}
	return .Ok
}

// Draws what the viewport shows, clipped to the pane's content.
markdown_draw :: proc(
	v: ^Markdown_View,
	doc: ^markdown.Document,
	g: Markdown_Geometry,
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	find: Markdown_Find = {},
	hover_link := -1,
) -> render.Build_Status {
	if render.push_layer(list, g.area, 0) != .None {return .Ok}
	origin_y := g.top - f32(v.scroll)
	visible_top := g.area.y - origin_y
	visible_bottom := visible_top + g.area.height
	for box in v.boxes {
		if box.rect.y >= visible_bottom || box.rect.y + box.rect.height <= visible_top {continue}
		rect := box.rect
		rect.x, rect.y = rect.x + g.left, rect.y + origin_y
		color := box.kind == .Fill ? theme.pressed : theme.border
		draw_rect(list, {rect = rect, color = color, radius = box.radius})
	}
	colors := [Markdown_Color]render.Color {
		.Text   = theme.text,
		.Muted  = theme.muted,
		.Accent = theme.accent,
	}
	from, to := markdown_selection(v)
	for index := line_at(v, visible_top);
	    index < len(v.lines) && v.lines[index].band_top < visible_bottom;
	    index += 1 {
		line := v.lines[index]
		baseline := line.baseline + origin_y
		for i in 0 ..< line.run_count {
			run := v.runs[line.first_run + i]
			x := run.x + g.left
			if run.flags & {.Task_Open, .Task_Done} != {} {
				box := checkbox_rect(x, line.top + origin_y, line.height, v.scale)
				checkbox_draw(list, box, .Task_Done in run.flags, theme, v.scale)
				continue
			}
			draw_matches(v, doc, list, find, run, x, line.top + origin_y, line.height)
			if from < to && int(run.end) > from && int(run.start) < to {
				start, stop := max(from, int(run.start)), min(to, int(run.end))
				left := string_advance(v, run.face, string(doc.text[run.start:start]))
				middle := string_advance(v, run.face, string(doc.text[start:stop]))
				rect := render.Rect{x + left, line.top + origin_y, middle, line.height}
				draw_rect(list, {rect = rect, color = theme.selection})
			}
			color := colors[run.color]
			result := draw_run(v, doc, text, list, run, x, baseline, color, find, from, to)
			if result != .Ok {return result}
			thickness := max(1, math.round(v.scale))
			if run.link >= 0 && int(run.link) == hover_link {
				rect := render.Rect{x, baseline + math.round(2 * v.scale), run.width, thickness}
				draw_rect(list, {rect = rect, color = color})
			}
			if .Strike in run.flags {
				middle := math.round(baseline - v.faces[run.face].size_px * 0.3)
				draw_rect(list, {rect = {x, middle, run.width, thickness}, color = color})
			}
		}
	}
	return .Ok
}
