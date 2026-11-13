package markdown

import "base:runtime"
import "core:encoding/entity"
import "core:fmt"
import "core:strings"
import "core:unicode/utf8"

Style_Flag :: enum u8 {
	Strong,
	Emphasis,
	Code,
	Strike,
	Link,
	// Syntax the edit view shows on the caret's line only (live.odin).
	Markup,
}
Style :: bit_set[Style_Flag;u8]

NO_LINK :: -1
NO_SOURCE :: -1

// One run of text in one style. Offsets index Document.text; `source` and `source_end` are where the
// text sits in the parsed file, NO_SOURCE when the parser made it up (a soft break's space, a list
// marker). Equal lengths correspond byte for byte; otherwise, as for a decoded entity, only the ends do.
Span :: struct {
	start, end:         int,
	source, source_end: int,
	style:              Style,
	link:               int,
}

Block_Kind :: enum u8 {
	Paragraph,
	Heading,
	Code,
	Rule,
	Table_Cell,
}

Align :: enum u8 {
	Left,
	Center,
	Right,
}

// A task list item's checkbox. Its marker text (☐ or ☑) is only what the item copies as.
Task :: enum u8 {
	None,
	Open,
	Done,
}

// One flat block. Containers become depths on the blocks they hold, and the first block of a list
// item carries its marker.
Block :: struct {
	kind:                     Block_Kind,
	level:                    int,
	quote_depth, list_depth:  int,
	// Follows the previous block with no gap, as items of a tight list do.
	tight:                    bool,
	marker_start, marker_end: int,
	task:                     Task,
	// The file offset of a task's mark, the character between its brackets.
	task_source:              int,
	first_span, span_count:   int,
	table, row, column:       int,
	header:                   bool,
	// A cell of the frontmatter's properties table.
	property:                 bool,
	align:                    Align,
	// The file range the block shows, end exclusive; only the edit view's blocks set it (live.odin).
	source_start, source_end: int,
}

Table :: struct {
	columns, rows: int,
	// The frontmatter's key and value rows rather than a Markdown table.
	properties:    bool,
}

// What a link goes to: a URL or path as written, or an Obsidian wikilink's target, which names a note
// in the vault rather than a path beside the document.
Link :: struct {
	href: string,
	wiki: bool,
}

// `text` holds what the document reads as, including list markers and the separators between blocks,
// so a selection copies as plain text by slicing it.
Document :: struct {
	text:   [dynamic]u8,
	blocks: [dynamic]Block,
	spans:  [dynamic]Span,
	links:  [dynamic]Link,
	tables: [dynamic]Table,
	// Each file line is a block of its own and blocks sit flush, as an editor shows them (live.odin).
	live:   bool,
}

@(private)
List_State :: struct {
	ordered, tight: bool,
	next:           u32,
}

@(private)
Builder :: struct {
	doc:             ^Document,
	ctx:             runtime.Context,
	// The file as md4c reads it, from `base` on: `original` as parse was given it, or `rewritten`, the
	// same length, when embeds needed it (parse_into).
	source:          string,
	original:        string,
	rewritten:       []u8,
	base:            int,
	// Where the text last appended from the file ended in it.
	last_source_end: int,
	styles:          [Style_Flag]int,
	link_stack:      [dynamic]int,
	lists:           [dynamic]List_State,
	list_start:      bool,
	quote_depth:     int,
	marker:          [16]u8,
	marker_len:      int,
	task:            Task,
	task_source:     int,
	// A tight list item's text arrives with no paragraph around it.
	implicit:        bool,
	block_open:      bool,
	cell_header:     bool,
	cell_property:   bool,
	table_row:       int,
	table_column:    int,
	image_start:     [dynamic]int,
	image_source:    [dynamic]int,
	failed:          bool,
}

document_destroy :: proc(doc: ^Document) {
	for link in doc.links {delete(link.href)}
	delete(doc.text)
	delete(doc.blocks)
	delete(doc.spans)
	delete(doc.links)
	delete(doc.tables)
	doc^ = {}
}

// Empties the document for a new parse, keeping its memory.
document_clear :: proc(doc: ^Document) {
	for link in doc.links {delete(link.href)}
	clear(&doc.text)
	clear(&doc.blocks)
	clear(&doc.spans)
	clear(&doc.links)
	clear(&doc.tables)
	doc.live = false
}

BOM :: "\xef\xbb\xbf"

// False only when memory runs out; any text parses to something. Span sources are offsets into
// `source` as given, byte order mark included.
@(require_results)
parse :: proc(source: string, doc: ^Document) -> bool {
	builder := Builder {
		doc = doc,
		ctx = context,
	}
	defer builder_destroy(&builder)
	if !parse_into(&builder, source) {
		document_destroy(doc)
		return false
	}
	return true
}

@(private)
builder_destroy :: proc(b: ^Builder) {
	delete(b.link_stack)
	delete(b.lists)
	delete(b.image_start)
	delete(b.image_source)
	delete(b.rewritten)
}

// Parses `source` onto the end of b.doc.
@(private, require_results)
parse_into :: proc(b: ^Builder, source: string) -> bool {
	if len(source) >= int(max(u32)) {return false}
	b.source, b.original = source, source
	// md4c reads the `![` of an embed, ![[note]], as an image's, so the embed reaches it as [[[note]],
	// the same length, and embed_bang_drop takes the extra bracket away again.
	if strings.contains(source, "![[") {
		rewritten, err := make([]u8, len(source))
		if err != nil {return false}
		copy(rewritten, source)
		for i := 0; i + 2 < len(rewritten); i += 1 {
			if rewritten[i] == '!' && rewritten[i + 1] == '[' && rewritten[i + 2] == '[' {rewritten[i] = '['}
		}
		b.source, b.rewritten = string(rewritten), rewritten
	}
	start := strings.has_prefix(source, BOM) ? len(BOM) : 0
	if front := frontmatter_end(b.source[start:]); front > 0 {
		if !properties_append(b, b.source[start:start + front]) {return false}
		start += front
	}
	b.base = start
	body := b.source[start:]
	parser := Md_Parser {
		flags       = MD_FLAGS,
		enter_block = on_enter_block,
		leave_block = on_leave_block,
		enter_span  = on_enter_span,
		leave_span  = on_leave_span,
		text        = on_text,
	}
	result := md_parse(raw_data(body), u32(len(body)), &parser, b)
	return result == 0 && !b.failed
}

// The length of a YAML block opening `text`: a first line of "---", through a closing "---" or "..."
// line. Zero when `text` opens with none, or never closes it.
frontmatter_end :: proc(text: string) -> int {
	line, rest, found := line_split(text)
	if !found || strings.trim_right(line, " \t\r") != "---" {return 0}
	for len(rest) > 0 {
		line, rest, _ = line_split(rest)
		closing := strings.trim_right(line, " \t\r")
		if closing == "---" || closing == "..." {return len(text) - len(rest)}
	}
	return 0
}

// The text before the first newline, and what follows it; `found` is false when there is none.
@(private)
line_split :: proc(text: string) -> (line, rest: string, found: bool) {
	index := strings.index_byte(text, '\n')
	if index < 0 {return text, "", false}
	return text[:index], text[index + 1:], true
}

// Where `part`, a slice of the file, starts in it.
@(private)
offset_in :: proc(b: ^Builder, part: string) -> int {
	return int(uintptr(raw_data(part)) - uintptr(raw_data(b.source)))
}

@(private)
Property_Value :: struct {
	text:   string,
	// An Obsidian wikilink's target; the text is its label.
	target: string,
}

@(private)
Property :: struct {
	key:    string,
	values: [dynamic]Property_Value,
}

// A value as Obsidian shows it: without quotes, and a lone [[wikilink]] as a link to its target.
@(private)
property_value :: proc(written: string) -> Property_Value {
	text := strings.trim_space(written)
	if len(text) >= 2 && (text[0] == '"' || text[0] == '\'') && text[len(text) - 1] == text[0] {
		text = text[1:len(text) - 1]
	}
	if strings.has_prefix(text, "[[") && strings.has_suffix(text, "]]") && len(text) > 4 {
		inner := text[2:len(text) - 2]
		if bar := strings.index_byte(inner, '|'); bar >= 0 {return {inner[bar + 1:], inner[:bar]}}
		return {inner, inner}
	}
	return {text, ""}
}

@(private)
property_values_add :: proc(values: ^[dynamic]Property_Value, written: string) {
	text := strings.trim_space(written)
	if text == "" {return}
	// An inline list, [a, b], is one value per item.
	if len(text) >= 2 && text[0] == '[' && text[len(text) - 1] == ']' && !strings.has_prefix(text, "[[") {
		items := text[1:len(text) - 1]
		for item in strings.split_iterator(&items, ",") {
			if value := property_value(item); value.text != "" {append(values, value)}
		}
		return
	}
	append(values, property_value(text))
}

// The frontmatter as a two-column table of keys and values. Only the YAML Obsidian writes is read:
// `key: value` lines, `- item` lists under a key and inline [a, b] lists. Anything else nested joins
// the value it follows.
@(private, require_results)
properties_append :: proc(b: ^Builder, front: string) -> bool {
	rows := make([dynamic]Property, context.temp_allocator)
	_, rest, _ := line_split(front)
	for len(rest) > 0 {
		line: string
		line, rest, _ = line_split(rest)
		line = strings.trim_right(line, " \t\r")
		trimmed := strings.trim_left(line, " \t")
		if trimmed == "" || trimmed == "---" || trimmed == "..." || trimmed[0] == '#' {continue}
		nested := line[0] == ' ' || line[0] == '\t' || strings.has_prefix(line, "- ") || line == "-"
		if !nested {
			colon := strings.index(line, ": ")
			if colon < 0 && strings.has_suffix(line, ":") {colon = len(line) - 1}
			if colon > 0 {
				row := Property {
					key    = line[:colon],
					values = make([dynamic]Property_Value, context.temp_allocator),
				}
				property_values_add(&row.values, line[colon + 1:])
				append(&rows, row)
				continue
			}
		}
		if len(rows) == 0 {continue}
		item := strings.has_prefix(trimmed, "- ") ? trimmed[2:] : trimmed
		property_values_add(&rows[len(rows) - 1].values, item)
	}
	if len(rows) == 0 {return true}
	if _, err := append(&b.doc.tables, Table{columns = 2, rows = len(rows), properties = true}); err != nil {
		return false
	}
	b.cell_property = true
	defer b.cell_property = false
	for row, index in rows {
		b.table_row = index
		b.table_column = 0
		if !block_begin(b, .Table_Cell) {return false}
		if !text_append(b, row.key, offset_in(b, row.key)) {return false}
		block_end(b)
		b.table_column = 1
		if !block_begin(b, .Table_Cell) {return false}
		for value, i in row.values {
			if i > 0 && !text_append(b, ", ") {return false}
			if value.target != "" {
				href, err := strings.clone(value.target)
				if err != nil || !link_add(b, href, true) {return false}
			}
			if !text_append(b, value.text, offset_in(b, value.text)) {return false}
			if value.target != "" {link_pop(b)}
		}
		block_end(b)
	}
	return true
}

@(private)
fail :: proc(b: ^Builder) -> i32 {
	b.failed = true
	return 1
}

@(private)
separator :: proc(b: ^Builder, kind: Block_Kind, tight: bool) -> bool {
	if len(b.doc.text) == 0 {return true}
	text := "\n\n"
	if kind == .Table_Cell {
		text = b.table_column > 0 ? "\t" : "\n"
	} else if tight {
		text = "\n"
	}
	_, err := append(&b.doc.text, text)
	return err == nil
}

@(private)
block_begin :: proc(b: ^Builder, kind: Block_Kind, level := 0, align := Align.Left) -> bool {
	count := len(b.lists)
	tight := count > 0 && b.lists[count - 1].tight
	// A list's first item sits as close to what comes before as the list around it allows.
	if b.list_start {
		tight = count > 1 && b.lists[count - 2].tight
		b.list_start = false
	}
	if !separator(b, kind, tight) {return false}
	block := Block {
		kind         = kind,
		level        = level,
		quote_depth  = b.quote_depth,
		list_depth   = len(b.lists),
		tight        = tight,
		first_span   = len(b.doc.spans),
		align        = align,
		task_source  = NO_SOURCE,
		source_start = NO_SOURCE,
		source_end   = NO_SOURCE,
	}
	if kind == .Table_Cell {
		block.table = len(b.doc.tables) - 1
		block.row, block.column, block.header = b.table_row, b.table_column, b.cell_header
		block.property = b.cell_property
	}
	if b.marker_len > 0 {
		block.marker_start, block.task, block.task_source = len(b.doc.text), b.task, b.task_source
		if _, err := append(&b.doc.text, string(b.marker[:b.marker_len])); err != nil {return false}
		block.marker_end = len(b.doc.text)
		if _, err := append(&b.doc.text, " "); err != nil {return false}
		b.marker_len, b.task = 0, .None
	}
	_, err := append(&b.doc.blocks, block)
	b.block_open = err == nil
	return err == nil
}

@(private)
block_end :: proc(b: ^Builder) {
	b.block_open, b.implicit = false, false
	if len(b.doc.blocks) == 0 {return}
	block := &b.doc.blocks[len(b.doc.blocks) - 1]
	defer block.span_count = len(b.doc.spans) - block.first_span
	if block.kind != .Code || len(b.doc.spans) == block.first_span {return}
	// md4c ends every code line with a newline; the last one only separates it from nothing.
	last := &b.doc.spans[len(b.doc.spans) - 1]
	if last.end > last.start && b.doc.text[last.end - 1] == '\n' {
		last.end -= 1
		if last.source != NO_SOURCE {last.source_end -= 1}
		pop(&b.doc.text)
		if last.end == last.start {pop(&b.doc.spans)}
	}
}

@(private)
implicit_end :: proc(b: ^Builder) {
	if b.implicit {block_end(b)}
}

@(private)
marker_set :: proc(b: ^Builder, detail: ^Md_Li_Detail) {
	list := &b.lists[len(b.lists) - 1]
	text: string
	b.task = .None
	if detail.is_task != 0 {
		b.task = detail.task_mark == ' ' ? .Open : .Done
		b.task_source = b.base + int(detail.task_mark_offset)
		text = b.task == .Open ? "☐" : "☑"
		if list.ordered {list.next += 1}
	} else if list.ordered {
		text = fmt.bprintf(b.marker[:], "%d.", list.next)
		list.next += 1
	} else {
		text = "•"
	}
	b.marker_len = copy(b.marker[:], text)
}

@(private)
on_enter_block :: proc "c" (type: i32, detail, user: rawptr) -> i32 {
	b := (^Builder)(user)
	context = b.ctx
	kind := Md_Block(type)
	implicit_end(b)
	ok := true
	#partial switch kind {
	case .Quote:
		b.quote_depth += 1
	case .Ul:
		_, err := append(&b.lists, List_State{tight = (^Md_Ul_Detail)(detail).is_tight != 0})
		ok = err == nil
		b.list_start = true
	case .Ol:
		ol := (^Md_Ol_Detail)(detail)
		_, err := append(&b.lists, List_State{ordered = true, tight = ol.is_tight != 0, next = ol.start})
		ok = err == nil
		b.list_start = true
	case .Li:
		marker_set(b, (^Md_Li_Detail)(detail))
	case .Hr:
		ok = block_begin(b, .Rule)
		block_end(b)
	case .H:
		ok = block_begin(b, .Heading, int((^Md_H_Detail)(detail).level))
	case .Code, .Html:
		ok = block_begin(b, .Code)
	case .P:
		ok = block_begin(b, .Paragraph)
	case .Table:
		table := (^Md_Table_Detail)(detail)
		_, err := append(
			&b.doc.tables,
			Table{columns = int(table.col_count), rows = int(table.head_row_count + table.body_row_count)},
		)
		ok = err == nil
		b.table_row = -1
	case .Tr:
		b.table_row += 1
		b.table_column = 0
	case .Th, .Td:
		b.cell_header = kind == .Th
		align := Align.Left
		#partial switch (^Md_Td_Detail)(detail).align {
		case .Center: align = .Center
		case .Right: align = .Right
		}
		ok = block_begin(b, .Table_Cell, 0, align)
	}
	return ok ? 0 : fail(b)
}

@(private)
on_leave_block :: proc "c" (type: i32, detail, user: rawptr) -> i32 {
	b := (^Builder)(user)
	context = b.ctx
	kind := Md_Block(type)
	#partial switch kind {
	case .Quote:
		b.quote_depth -= 1
	case .Ul, .Ol:
		implicit_end(b)
		pop(&b.lists)
	case .Li:
		implicit_end(b)
		// An empty item still shows its marker.
		if b.marker_len > 0 {
			ok := block_begin(b, .Paragraph)
			block_end(b)
			if !ok {return fail(b)}
		}
	case .H, .Code, .Html, .P:
		block_end(b)
	case .Th, .Td:
		block_end(b)
		b.table_column += 1
	}
	return 0
}

// Owned text of an attribute with its entities decoded; false when memory runs out.
@(private)
attribute_text :: proc(attribute: Md_Attribute) -> (string, bool) {
	out: [dynamic]u8
	offset := u32(0)
	for i := 0; offset < attribute.size; i += 1 {
		next := attribute.substr_offsets[i + 1]
		part := string(attribute.text[offset:next])
		buffer: [8]u8
		if attribute.substr_types[i] == .Entity {part = entity_text(&buffer, part)}
		if _, err := append(&out, part); err != nil {
			delete(out)
			return "", false
		}
		offset = next
	}
	return string(out[:]), true
}

// What an entity reads as, decoded into `buffer`; an unknown entity reads as written.
@(private)
entity_text :: proc(buffer: ^[8]u8, text: string) -> string {
	name := strings.trim_suffix(strings.trim_prefix(text, "&"), ";")
	decoded, count, ok := entity.xml_decode_entity(name)
	if !ok {return text}
	length := 0
	for i in 0 ..< count {
		bytes, size := utf8.encode_rune(decoded[i])
		length += copy(buffer[length:], bytes[:size])
	}
	return string(buffer[:length])
}

// Takes ownership of `href`, freeing it on failure.
@(private)
link_add :: proc(b: ^Builder, href: string, wiki: bool) -> bool {
	if _, err := append(&b.doc.links, Link{href, wiki}); err != nil {
		delete(href)
		return false
	}
	_, err := append(&b.link_stack, len(b.doc.links) - 1)
	b.styles[.Link] += 1
	return err == nil
}

@(private)
link_push :: proc(b: ^Builder, attribute: Md_Attribute, wiki := false) -> bool {
	href, ok := attribute_text(attribute)
	return ok && link_add(b, href, wiki)
}

@(private)
link_pop :: proc(b: ^Builder) {
	pop(&b.link_stack)
	b.styles[.Link] -= 1
}

// An embed, ![[note]], shows as a link to its target. Its '!' reached md4c as '[' (parse_into), which
// md4c took for text; that bracket goes.
@(private)
embed_bang_drop :: proc(b: ^Builder) {
	end := b.last_source_end
	if end < 1 || b.original[end - 1] != '!' || !strings.has_prefix(b.original[end:], "[[") {return}
	if len(b.doc.spans) == 0 || len(b.doc.blocks) == 0 {return}
	last := &b.doc.spans[len(b.doc.spans) - 1]
	if last.end != len(b.doc.text) || last.source_end != end || last.end == last.start {return}
	if len(b.doc.spans) <= b.doc.blocks[len(b.doc.blocks) - 1].first_span {return}
	pop(&b.doc.text)
	last.end -= 1
	last.source_end -= 1
	if last.end == last.start {pop(&b.doc.spans)}
}

@(private)
on_enter_span :: proc "c" (type: i32, detail, user: rawptr) -> i32 {
	b := (^Builder)(user)
	context = b.ctx
	ok := true
	#partial switch Md_Span(type) {
	case .Em:
		b.styles[.Emphasis] += 1
	case .Strong:
		b.styles[.Strong] += 1
	case .Code:
		b.styles[.Code] += 1
	case .Del:
		b.styles[.Strike] += 1
	case .A:
		ok = link_push(b, (^Md_A_Detail)(detail).href)
	case .Img:
		ok = link_push(b, (^Md_Img_Detail)(detail).src)
		if ok {
			_, start_error := append(&b.image_start, len(b.doc.text))
			_, source_error := append(&b.image_source, len(b.doc.links) - 1)
			ok = start_error == nil && source_error == nil
		}
	case .Wikilink:
		embed_bang_drop(b)
		ok = link_push(b, (^Md_Wikilink_Detail)(detail).target, true)
	}
	return ok ? 0 : fail(b)
}

@(private)
on_leave_span :: proc "c" (type: i32, detail, user: rawptr) -> i32 {
	b := (^Builder)(user)
	context = b.ctx
	#partial switch Md_Span(type) {
	case .Em:
		b.styles[.Emphasis] -= 1
	case .Strong:
		b.styles[.Strong] -= 1
	case .Code:
		b.styles[.Code] -= 1
	case .Del:
		b.styles[.Strike] -= 1
	case .A, .Wikilink:
		link_pop(b)
	case .Img:
		// An image with no description still needs something to show and open.
		start, source := pop(&b.image_start), pop(&b.image_source)
		if len(b.doc.text) == start && !text_append(b, b.doc.links[source].href) {return fail(b)}
		link_pop(b)
	}
	return 0
}

// Appends text in the current style. `source` is where it sits in the file, through `source_end`
// when its length there differs.
@(private)
text_append :: proc(b: ^Builder, text: string, source := NO_SOURCE, source_end := NO_SOURCE) -> bool {
	if len(text) == 0 {return true}
	if !b.block_open {
		if !block_begin(b, .Paragraph) {return false}
		b.implicit = true
	}
	source_end := source_end
	if source == NO_SOURCE {
		source_end = NO_SOURCE
	} else if source_end == NO_SOURCE {
		source_end = source + len(text)
	}
	if source != NO_SOURCE {b.last_source_end = source_end}
	style: Style
	for count, flag in b.styles {if count > 0 {style += {flag}}}
	link := len(b.link_stack) > 0 ? b.link_stack[len(b.link_stack) - 1] : NO_LINK
	start := len(b.doc.text)
	if _, err := append(&b.doc.text, text); err != nil {return false}
	block := b.doc.blocks[len(b.doc.blocks) - 1]
	if len(b.doc.spans) > block.first_span {
		last := &b.doc.spans[len(b.doc.spans) - 1]
		// Runs join only where the file's text does too, so every offset in one maps back to the file.
		joins := last.source == NO_SOURCE && source == NO_SOURCE
		if source != NO_SOURCE && last.source_end == source {
			joins = source_end - source == len(text) && last.source_end - last.source == last.end - last.start
		}
		if last.end == start && last.style == style && last.link == link && joins {
			last.end = len(b.doc.text)
			last.source_end = source_end
			return true
		}
	}
	_, err := append(&b.doc.spans, Span{start, len(b.doc.text), source, source_end, style, link})
	return err == nil
}

// Where md4c's text sits in the file, or NO_SOURCE for text it made up.
@(private)
source_of :: proc(b: ^Builder, text: [^]u8, size: u32) -> int {
	base := uintptr(raw_data(b.source))
	at := uintptr(text)
	if at < base || at + uintptr(size) > base + uintptr(len(b.source)) {return NO_SOURCE}
	return int(at - base)
}

@(private)
on_text :: proc "c" (type: Md_Text, text: [^]u8, size: u32, user: rawptr) -> i32 {
	b := (^Builder)(user)
	context = b.ctx
	ok := true
	#partial switch type {
	case .Null_Char:
		ok = text_append(b, "�")
	case .Br:
		ok = text_append(b, "\n")
	case .Soft_Br:
		ok = text_append(b, " ")
	case .Entity:
		buffer: [8]u8
		source := source_of(b, text, size)
		end := source == NO_SOURCE ? NO_SOURCE : source + int(size)
		ok = text_append(b, entity_text(&buffer, string(text[:size])), source, end)
	case:
		ok = text_append(b, string(text[:size]), source_of(b, text, size))
	}
	return ok ? 0 : fail(b)
}
