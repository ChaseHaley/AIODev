package markdown

import "core:slice"
import "core:strings"

// The edit view's document (WORK-441). Each file line is a block of its own, as an editor shows it. The
// lines the caret or selection touches show their source, markup and all; every other line shows its
// text rendered with its markup hidden, as Obsidian's Live Preview does. Tables and the frontmatter
// show rendered whole until the caret enters them, then as source whole.
//
// The whole file is parsed as the reading view parses it, and each span's file offsets say which bytes
// are text: what no span covers is markup. The blocks and spans built here carry file offsets too, so a
// point on screen maps to a place in the file and back (live_source, live_display).
Live :: struct {
	parsed: Document,
	// The spans of `parsed` that come from the file, in file order.
	order:  [dynamic]Live_Span,
	// The block of `parsed` holding each of its spans.
	owner:  [dynamic]int,
	// The list lines seen so far, outermost first, for the depth of an item with no text.
	lists:  [dynamic]Live_List,
}

@(private)
Live_Span :: struct {
	source, span: int,
}

@(private)
Live_List :: struct {
	indent, depth: int,
}

live_destroy :: proc(l: ^Live) {
	document_destroy(&l.parsed)
	delete(l.order)
	delete(l.owner)
	delete(l.lists)
	l^ = {}
}

@(private = "file")
Fence :: struct {
	mark:  u8,
	count: int,
}

@(private = "file")
Live_Builder :: struct {
	l:        ^Live,
	doc:      ^Document,
	source:   string,
	// The file range shown as source.
	from, to: int,
	// The first of l.order not yet placed on a line.
	cursor:   int,
	// The block of `doc` being filled.
	block:    int,
	fence:    Fence,
	// The block of `parsed` the previous line's text belonged to, or -1.
	previous: int,
}

// Builds `doc` from `source`, showing the lines the range from..to touches as source. False only when
// memory runs out, which leaves `doc` empty.
@(require_results)
live_build :: proc(l: ^Live, source: string, from, to: int, doc: ^Document) -> bool {
	if !live_build_into(l, source, from, to, doc) {
		document_clear(doc)
		doc.live = true
		return false
	}
	return true
}

@(private = "file")
live_before :: proc(a, b: Live_Span) -> bool {
	return a.source < b.source
}

@(private = "file", require_results)
live_build_into :: proc(l: ^Live, source: string, from, to: int, doc: ^Document) -> bool {
	document_clear(&l.parsed)
	document_clear(doc)
	doc.live = true
	parser := Builder {
		doc = &l.parsed,
		ctx = context,
	}
	defer builder_destroy(&parser)
	if !parse_into(&parser, source) {return false}
	parsed := &l.parsed
	for link in parsed.links {
		href, err := strings.clone(link.href)
		if err != nil {return false}
		if _, append_error := append(&doc.links, Link{href, link.wiki}); append_error != nil {
			delete(href)
			return false
		}
	}
	if resize(&l.owner, len(parsed.spans)) != nil {return false}
	for block, index in parsed.blocks {
		for span in block.first_span ..< block.first_span + block.span_count {l.owner[span] = index}
	}
	clear(&l.order)
	for span, index in parsed.spans {
		if span.source == NO_SOURCE {continue}
		if _, err := append(&l.order, Live_Span{span.source, index}); err != nil {return false}
	}
	if !slice.is_sorted_by(l.order[:], live_before) {slice.stable_sort_by(l.order[:], live_before)}
	clear(&l.lists)
	b := Live_Builder {
		l        = l,
		doc      = doc,
		source   = source,
		from     = from,
		to       = to,
		previous = -1,
	}
	at := strings.has_prefix(source, BOM) ? len(BOM) : 0
	if front := frontmatter_end(source[at:]); front > 0 {
		if !live_frontmatter(&b, at, at + front) {return false}
		at += front
	}
	for at <= len(source) {
		newline := strings.index_byte(source[at:], '\n')
		end := newline < 0 ? len(source) : at + newline
		if cell, region := live_table_region(&b, at, end); region > 0 {
			if !live_table(&b, cell, at, region) {return false}
			if region >= len(source) {break}
			at = region + 1
			continue
		}
		if !live_line(&b, at, end) {return false}
		if newline < 0 {break}
		at = end + 1
	}
	return true
}

// Starts a block of `doc` after the separator that sets it apart from the one before, with `marker`
// hanging before its text.
@(private = "file", require_results)
live_block_begin :: proc(b: ^Live_Builder, block: Block, marker := "", separator := "\n") -> bool {
	doc := b.doc
	if len(doc.blocks) > 0 {
		if _, err := append(&doc.text, separator); err != nil {return false}
	}
	block := block
	block.first_span, block.span_count = len(doc.spans), 0
	block.tight = true
	// A live block's marker_start is where it starts in the text, marker or not.
	block.marker_start, block.marker_end = len(doc.text), len(doc.text)
	if marker != "" {
		if _, err := append(&doc.text, marker); err != nil {return false}
		block.marker_end = len(doc.text)
		if _, err := append(&doc.text, " "); err != nil {return false}
	}
	if _, err := append(&doc.blocks, block); err != nil {return false}
	b.block = len(doc.blocks) - 1
	return true
}

@(private = "file")
live_line_block :: proc(kind: Block_Kind, at, end: int, level := 0) -> Block {
	return {kind = kind, level = level, task_source = NO_SOURCE, source_start = at, source_end = end}
}

@(private = "file", require_results)
live_text :: proc(b: ^Live_Builder, text: string, source, source_end: int, style: Style, link: int) -> bool {
	if text == "" {return true}
	doc := b.doc
	start := len(doc.text)
	if _, err := append(&doc.text, text); err != nil {return false}
	if _, err := append(&doc.spans, Span{start, len(doc.text), source, source_end, style, link}); err != nil {
		return false
	}
	doc.blocks[b.block].span_count += 1
	return true
}

// The spans that start in at..end, as a range of l.order; later lines start after them.
@(private = "file")
live_spans_in :: proc(b: ^Live_Builder, at, end: int) -> (first, last: int) {
	order := b.l.order[:]
	for b.cursor < len(order) && order[b.cursor].source < at {b.cursor += 1}
	first, last = b.cursor, b.cursor
	for last < len(order) && order[last].source < end {last += 1}
	b.cursor = last
	return
}

@(private = "file")
live_span :: proc(b: ^Live_Builder, index: int) -> Span {
	return b.l.parsed.spans[b.l.order[index].span]
}

@(private = "file")
live_owner :: proc(b: ^Live_Builder, index: int) -> Block {
	return b.l.parsed.blocks[b.l.owner[b.l.order[index].span]]
}

// A line shown as its source: what spans covered in their style, the markup between them muted. A
// `plain` line, code, shows in one style.
@(private = "file", require_results)
live_raw :: proc(b: ^Live_Builder, block: Block, first, last: int, plain: bool) -> bool {
	if !live_block_begin(b, block) {return false}
	at, end := block.source_start, block.source_end
	if plain {return live_text(b, b.source[at:end], at, end, {}, NO_LINK)}
	pen := at
	for i in first ..< last {
		span := live_span(b, i)
		start, stop := max(span.source, pen), min(span.source_end, end)
		if start > pen && !live_text(b, b.source[pen:start], pen, start, {.Markup}, NO_LINK) {return false}
		if stop > start && !live_text(b, b.source[start:stop], start, stop, span.style, span.link) {return false}
		pen = max(pen, stop)
	}
	return pen >= end || live_text(b, b.source[pen:end], pen, end, {.Markup}, NO_LINK)
}

// A line shown rendered: its text in its block's style, the markup gone, a list item's marker hanging
// before it.
@(private = "file", require_results)
live_rendered :: proc(b: ^Live_Builder, at, end, first, last: int, indent: int) -> bool {
	parsed := &b.l.parsed
	owner := live_owner(b, first)
	block := live_line_block(owner.kind == .Heading ? .Heading : .Paragraph, at, end, owner.level)
	block.quote_depth, block.list_depth = owner.quote_depth, owner.list_depth
	marker := ""
	// The item's marker shows on the line its text starts.
	starts := owner.span_count > 0 && parsed.spans[owner.first_span].source >= at
	if owner.marker_end > owner.marker_start && starts {
		marker = string(parsed.text[owner.marker_start:owner.marker_end])
		block.task, block.task_source = owner.task, owner.task_source
		live_list_seen(b, indent, owner.list_depth)
	}
	if !live_block_begin(b, block, marker) {return false}
	for i in first ..< last {
		span := live_span(b, i)
		text := string(parsed.text[span.start:span.end])
		source_end := span.source_end
		linear := span.end - span.start == span.source_end - span.source
		if source_end > end && linear {
			text = text[:end - span.source]
			source_end = end
		}
		if !live_text(b, text, span.source, source_end, span.style, span.link) {return false}
	}
	return true
}

@(private = "file")
live_list_seen :: proc(b: ^Live_Builder, indent, depth: int) {
	for len(b.l.lists) > 0 && b.l.lists[len(b.l.lists) - 1].indent >= indent {pop(&b.l.lists)}
	append(&b.l.lists, Live_List{indent, depth})
}

// The depth of an item with no text, from the items around it: as deep as one at its indent, else
// one deeper than the item it is indented under.
@(private = "file")
live_list_depth :: proc(b: ^Live_Builder, indent: int) -> int {
	lists := &b.l.lists
	for len(lists) > 0 && lists[len(lists) - 1].indent > indent {pop(lists)}
	depth := 1
	if len(lists) > 0 {
		top := lists[len(lists) - 1]
		depth = top.indent == indent ? top.depth : top.depth + 1
	}
	live_list_seen(b, indent, depth)
	return depth
}

// The columns of indentation before a list marker, a tab counting four.
@(private = "file")
live_indent :: proc(line: string, p: Line_Prefix) -> int {
	columns := 0
	for c in transmute([]u8)line[p.quote_end:] {
		switch c {
		case ' ': columns += 1
		case '\t': columns += 4 - columns % 4
		case: return columns
		}
	}
	return columns
}

@(private = "file")
fence_opens :: proc(rest: string) -> (Fence, bool) {
	if len(rest) < 3 || (rest[0] != '`' && rest[0] != '~') {return {}, false}
	count := 0
	for count < len(rest) && rest[count] == rest[0] {count += 1}
	if count < 3 {return {}, false}
	// A backtick fence's info string has no backticks.
	if rest[0] == '`' && strings.index_byte(rest[count:], '`') >= 0 {return {}, false}
	return {rest[0], count}, true
}

@(private = "file")
fence_closes :: proc(rest: string, fence: Fence) -> bool {
	count := 0
	for count < len(rest) && rest[count] == fence.mark {count += 1}
	return count >= fence.count && strings.trim_space(rest[count:]) == ""
}

// Three or more of one of - * _ and nothing else but spaces.
@(private = "file")
thematic_break :: proc(text: string) -> bool {
	mark: u8
	count := 0
	for c in transmute([]u8)text {
		switch c {
		case ' ', '\t':
		case '-', '*', '_':
			if mark != 0 && c != mark {return false}
			mark = c
			count += 1
		case:
			return false
		}
	}
	return count >= 3
}

// An ATX heading's level, or 0.
@(private = "file")
heading_level :: proc(text: string) -> int {
	rest := strings.trim_left(text, " ")
	level := 0
	for level < len(rest) && rest[level] == '#' {level += 1}
	if level == 0 || level > 6 {return 0}
	if level < len(rest) && rest[level] != ' ' && rest[level] != '\t' {return 0}
	return level
}

@(private = "file", require_results)
live_line :: proc(b: ^Live_Builder, at, line_end: int) -> bool {
	end := line_end
	if end > at && b.source[end - 1] == '\r' {end -= 1}
	line := b.source[at:end]
	first, last := live_spans_in(b, at, end)
	revealed := at <= b.to && end >= b.from
	previous := b.previous
	b.previous = first < last ? b.l.owner[b.l.order[first].span] : -1
	p := line_prefix(line)
	rest := strings.trim_left(line[p.quote_end:], " \t")
	block := live_line_block(.Paragraph, at, end)
	if b.fence.count > 0 {
		block.kind = .Code
		if fence_closes(rest, b.fence) {
			b.fence = {}
			return revealed ? live_raw(b, block, first, last, true) : live_block_begin(b, block)
		}
		return live_raw(b, block, first, last, true)
	}
	if fence, opens := fence_opens(rest); opens {
		b.fence = fence
		block.kind = .Code
		if revealed {return live_raw(b, block, first, last, true)}
		if !live_block_begin(b, block) {return false}
		info := strings.trim_space(rest[fence.count:])
		if info == "" {return true}
		start := at + int(uintptr(raw_data(info)) - uintptr(raw_data(line)))
		return live_text(b, info, start, start + len(info), {.Markup}, NO_LINK)
	}
	owner := first < last ? live_owner(b, first) : Block{kind = .Paragraph}
	if owner.kind == .Code {
		block.kind = .Code
		return live_raw(b, block, first, last, true)
	}
	if revealed {
		if owner.kind == .Heading {
			block.kind, block.level = .Heading, owner.level
		} else if level := heading_level(rest); first == last && level > 0 {
			block.kind, block.level = .Heading, level
		}
		return live_raw(b, block, first, last, false)
	}
	indent := live_indent(line, p)
	if first < last {return live_rendered(b, at, end, first, last, indent)}
	if strings.trim_space(line) == "" {
		// A blank line ends the lists above it, unless an item follows indented under them.
		return live_block_begin(b, block)
	}
	quotes := strings.count(line[:p.quote_end], ">")
	block.quote_depth = quotes
	body := line[p.quote_end:]
	setext := strings.trim_space(body)
	underline := setext != "" && (strings.trim_left(setext, "=") == "" || strings.trim_left(setext, "-") == "")
	if previous >= 0 && b.l.parsed.blocks[previous].kind == .Heading && underline {
		return live_raw(b, block, first, last, false)
	}
	if thematic_break(body) {
		block.kind = .Rule
		return live_block_begin(b, block)
	}
	if p.bullet || p.delimiter != 0 {
		block.list_depth = live_list_depth(b, indent)
		marker := "•"
		if p.delimiter != 0 {marker = strings.trim_space(line[p.quote_end:p.end])}
		if p.task {
			mark := strings.last_index_byte(line[:p.end], '[') + 1
			block.task = line[mark] == ' ' ? .Open : .Done
			block.task_source = at + mark
			marker = block.task == .Open ? "☐" : "☑"
		}
		return live_block_begin(b, block, marker)
	}
	if level := heading_level(rest); level > 0 {
		block.kind, block.level = .Heading, level
		return live_block_begin(b, block)
	}
	if rest == "" {return live_block_begin(b, block)}
	// Syntax with no text to show, such as a link reference definition, shows as written.
	block.quote_depth = 0
	return live_raw(b, block, first, last, false)
}

// The table starting on the line at..end: a block of `parsed` among its cells and where its last line
// ends, or a zero region when no table starts there.
@(private = "file")
live_table_region :: proc(b: ^Live_Builder, at, end: int) -> (cell, region: int) {
	if b.fence.count > 0 {return}
	order := b.l.order[:]
	index := b.cursor
	for index < len(order) && order[index].source < at {index += 1}
	if index >= len(order) || order[index].source >= end {return}
	owner := live_owner(b, index)
	if owner.kind != .Table_Cell || owner.property {return}
	cell = b.l.owner[order[index].span]
	region = end
	for region < len(b.source) {
		next := region + 1
		newline := strings.index_byte(b.source[next:], '\n')
		next_end := newline < 0 ? len(b.source) : next + newline
		line := b.source[next:next_end]
		if strings.trim_space(line) == "" || strings.index_byte(line, '|') < 0 {break}
		region = next_end
	}
	return cell, region
}

// A table, lines at..region: rendered whole, or as source whole while the caret is in it.
@(private = "file", require_results)
live_table :: proc(b: ^Live_Builder, cell, at, region: int) -> bool {
	if at <= b.to && region >= b.from {
		line := at
		for line <= region {
			newline := strings.index_byte(b.source[line:region], '\n')
			end := newline < 0 ? region : line + newline
			start := line
			if end > start && b.source[end - 1] == '\r' {end -= 1}
			first, last := live_spans_in(b, start, end)
			if !live_raw(b, live_line_block(.Code, start, end), first, last, true) {return false}
			if newline < 0 {break}
			line = start + newline + 1
		}
		_, _ = live_spans_in(b, region, region)
		return true
	}
	_, _ = live_spans_in(b, region, region)
	return live_cells(b, cell, at)
}

// Copies the cells of the table holding block `cell` of `parsed`, which sit together. `at` stands in
// for the file offset of a cell with no text.
@(private = "file", require_results)
live_cells :: proc(b: ^Live_Builder, cell, at: int) -> bool {
	parsed := &b.l.parsed
	table := parsed.blocks[cell].table
	first := cell
	for first > 0 && parsed.blocks[first - 1].kind == .Table_Cell && parsed.blocks[first - 1].table == table {
		first -= 1
	}
	if _, err := append(&b.doc.tables, parsed.tables[table]); err != nil {return false}
	copied := len(b.doc.tables) - 1
	for original in parsed.blocks[first:] {
		if original.kind != .Table_Cell || original.table != table {break}
		block := original
		block.table = copied
		block.marker_start, block.marker_end = 0, 0
		block.source_start, block.source_end = at, at
		spans := parsed.spans[original.first_span:][:original.span_count]
		for span in spans {
			if span.source == NO_SOURCE {continue}
			if block.source_start == at {block.source_start = span.source}
			block.source_end = span.source_end
		}
		if !live_block_begin(b, block, "", original.column > 0 ? "\t" : "\n") {return false}
		for span in spans {
			text := string(parsed.text[span.start:span.end])
			if !live_text(b, text, span.source, span.source_end, span.style, span.link) {return false}
		}
	}
	return true
}

// The frontmatter at..end: its properties table, or its lines as source while the caret is in it or
// when it holds no properties.
@(private = "file", require_results)
live_frontmatter :: proc(b: ^Live_Builder, at, end: int) -> bool {
	// The properties are the first table and their cells the first blocks (properties_append).
	properties := len(b.l.parsed.tables) > 0 && b.l.parsed.tables[0].properties
	revealed := at <= b.to && end > b.from
	if !revealed && properties {
		_, _ = live_spans_in(b, end, end)
		return live_cells(b, 0, at)
	}
	line := at
	for line < end {
		newline := strings.index_byte(b.source[line:end], '\n')
		stop := newline < 0 ? end : line + newline
		start := line
		if stop > start && b.source[stop - 1] == '\r' {stop -= 1}
		first, last := live_spans_in(b, start, stop)
		if !live_raw(b, live_line_block(.Code, start, stop), first, last, true) {return false}
		if newline < 0 {break}
		line = start + newline + 1
	}
	return true
}

// The block of a live document holding text offset `offset`.
@(private = "file")
live_block_at :: proc(doc: ^Document, offset: int) -> int {
	low, high := 0, len(doc.blocks)
	for low < high {
		middle := (low + high) / 2
		if doc.blocks[middle].marker_start <= offset {low = middle + 1} else {high = middle}
	}
	return max(low - 1, 0)
}

// The file offset shown at text offset `offset` of a live document; where markup hid the file's own
// text, the offset of the text after it.
live_source :: proc(doc: ^Document, offset: int) -> int {
	if len(doc.blocks) == 0 {return 0}
	block := doc.blocks[live_block_at(doc, offset)]
	last := block.source_end
	for span in doc.spans[block.first_span:][:block.span_count] {
		if span.source == NO_SOURCE {continue}
		if offset < span.start {return span.source}
		last = span.source_end
		if offset > span.end {continue}
		if span.end - span.start == span.source_end - span.source {return span.source + offset - span.start}
		return offset == span.end ? span.source_end : span.source
	}
	return last
}

// The text offset at which a live document shows file offset `source`: exact on a line shown as
// source, else the nearest text.
live_display :: proc(doc: ^Document, source: int) -> int {
	found := -1
	for block, index in doc.blocks {
		if block.source_start == NO_SOURCE || block.source_end < source {continue}
		found = index
		break
	}
	if found < 0 {return len(doc.text)}
	block := doc.blocks[found]
	content := block.marker_end > block.marker_start ? block.marker_end + 1 : block.marker_end
	if source < block.source_start {return content}
	spans := doc.spans[block.first_span:][:block.span_count]
	after := content
	for span in spans {
		if span.source == NO_SOURCE {continue}
		if source < span.source {return span.start}
		after = span.end
		if source > span.source_end {continue}
		if span.end - span.start == span.source_end - span.source {return span.start + source - span.source}
		return source == span.source_end ? span.end : span.start
	}
	return after
}

// The file offset of the text at text offset `offset` of a parsed document; where the parser made the
// text up, such as a list marker, the offset of the text after it.
document_source :: proc(doc: ^Document, offset: int) -> int {
	for span in doc.spans {
		if span.source == NO_SOURCE || span.end <= offset {continue}
		linear := span.end - span.start == span.source_end - span.source
		if offset >= span.start && linear {return span.source + offset - span.start}
		return span.source
	}
	return 0
}
