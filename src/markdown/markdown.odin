package markdown

import "base:runtime"
import "core:encoding/entity"
import "core:fmt"
import "core:strings"

Style_Flag :: enum u8 {
	Strong,
	Emphasis,
	Code,
	Strike,
	Link,
}
Style :: bit_set[Style_Flag;u8]

NO_LINK :: -1

// One run of text in one style. Offsets index Document.text.
Span :: struct {
	start, end: int,
	style:      Style,
	link:       int,
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

// One flat block. Containers become depths on the blocks they hold, and the first block of a list
// item carries its marker.
Block :: struct {
	kind:                     Block_Kind,
	level:                    int,
	quote_depth, list_depth:  int,
	// Follows the previous block with no gap, as items of a tight list do.
	tight:                    bool,
	marker_start, marker_end: int,
	first_span, span_count:   int,
	table, row, column:       int,
	header:                   bool,
	align:                    Align,
}

Table :: struct {
	columns, rows: int,
}

// `text` holds what the document reads as, including list markers and the separators between blocks,
// so a selection copies as plain text by slicing it.
Document :: struct {
	text:   [dynamic]u8,
	blocks: [dynamic]Block,
	spans:  [dynamic]Span,
	links:  [dynamic]string,
	tables: [dynamic]Table,
}

@(private)
List_State :: struct {
	ordered, tight: bool,
	next:           u32,
}

@(private)
Builder :: struct {
	doc:           ^Document,
	ctx:           runtime.Context,
	styles:        [Style_Flag]int,
	link_stack:    [dynamic]int,
	lists:         [dynamic]List_State,
	list_start:    bool,
	quote_depth:   int,
	marker:        [16]u8,
	marker_len:    int,
	// A tight list item's text arrives with no paragraph around it.
	implicit:      bool,
	block_open:    bool,
	cell_header:   bool,
	table_row:     int,
	table_column:  int,
	image_start:   [dynamic]int,
	image_source:  [dynamic]int,
	failed:        bool,
}

document_destroy :: proc(doc: ^Document) {
	for link in doc.links {delete(link)}
	delete(doc.text)
	delete(doc.blocks)
	delete(doc.spans)
	delete(doc.links)
	delete(doc.tables)
	doc^ = {}
}

// False only when memory runs out; any text parses to something.
@(require_results)
parse :: proc(source: string, doc: ^Document) -> bool {
	source := source
	if strings.has_prefix(source, "\xef\xbb\xbf") {source = source[3:]}
	if len(source) >= int(max(u32)) {return false}
	builder := Builder {
		doc = doc,
		ctx = context,
	}
	defer delete(builder.link_stack)
	defer delete(builder.lists)
	defer delete(builder.image_start)
	defer delete(builder.image_source)
	parser := Md_Parser {
		flags       = MD_FLAGS,
		enter_block = on_enter_block,
		leave_block = on_leave_block,
		enter_span  = on_enter_span,
		leave_span  = on_leave_span,
		text        = on_text,
	}
	result := md_parse(raw_data(source), u32(len(source)), &parser, &builder)
	if result != 0 || builder.failed {
		document_destroy(doc)
		return false
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
		kind        = kind,
		level       = level,
		quote_depth = b.quote_depth,
		list_depth  = len(b.lists),
		tight       = tight,
		first_span  = len(b.doc.spans),
		align       = align,
	}
	if kind == .Table_Cell {
		block.table = len(b.doc.tables) - 1
		block.row, block.column, block.header = b.table_row, b.table_column, b.cell_header
	}
	if b.marker_len > 0 {
		block.marker_start = len(b.doc.text)
		if _, err := append(&b.doc.text, string(b.marker[:b.marker_len])); err != nil {return false}
		block.marker_end = len(b.doc.text)
		if _, err := append(&b.doc.text, " "); err != nil {return false}
		b.marker_len = 0
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
	block.span_count = len(b.doc.spans) - block.first_span
	if block.kind != .Code || block.span_count == 0 {return}
	// md4c ends every code line with a newline; the last one only separates it from nothing.
	last := &b.doc.spans[len(b.doc.spans) - 1]
	if last.end > last.start && b.doc.text[last.end - 1] == '\n' {
		last.end -= 1
		pop(&b.doc.text)
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
	if detail.is_task != 0 {
		text = detail.task_mark == ' ' ? "☐" : "☑"
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
			Table{int(table.col_count), int(table.head_row_count + table.body_row_count)},
		)
		ok = err == nil
		b.table_row = -1
	case .Tr:
		b.table_row += 1
		b.table_column = 0
	case .Th, .Td:
		b.cell_header = kind == .Th
		align := Align.Left
		switch (^Md_Td_Detail)(detail).align {
		case 2: align = .Center
		case 3: align = .Right
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

@(private)
attribute_text :: proc(attribute: Md_Attribute) -> (string, bool) {
	out := strings.builder_make()
	offset := u32(0)
	for i := 0; offset < attribute.size; i += 1 {
		next := attribute.substr_offsets[i + 1]
		part := string(attribute.text[offset:next])
		if attribute.substr_types[i] == .Entity {
			write_entity(&out, part)
		} else {
			strings.write_string(&out, part)
		}
		offset = next
	}
	return strings.to_string(out), true
}

@(private)
write_entity :: proc(out: ^strings.Builder, text: string) {
	name := strings.trim_suffix(strings.trim_prefix(text, "&"), ";")
	decoded, count, ok := entity.xml_decode_entity(name)
	if !ok {
		strings.write_string(out, text)
		return
	}
	for i in 0 ..< count {strings.write_rune(out, decoded[i])}
}

@(private)
link_push :: proc(b: ^Builder, attribute: Md_Attribute) -> bool {
	href, ok := attribute_text(attribute)
	if !ok {return false}
	if _, err := append(&b.doc.links, href); err != nil {
		delete(href)
		return false
	}
	_, err := append(&b.link_stack, len(b.doc.links) - 1)
	b.styles[.Link] += 1
	return err == nil
}

@(private)
link_pop :: proc(b: ^Builder) {
	pop(&b.link_stack)
	b.styles[.Link] -= 1
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
	case .A:
		link_pop(b)
	case .Img:
		// An image with no description still needs something to show and open.
		start, source := pop(&b.image_start), pop(&b.image_source)
		if len(b.doc.text) == start && !text_append(b, b.doc.links[source]) {return fail(b)}
		link_pop(b)
	}
	return 0
}

@(private)
text_append :: proc(b: ^Builder, text: string) -> bool {
	if len(text) == 0 {return true}
	if !b.block_open {
		if !block_begin(b, .Paragraph) {return false}
		b.implicit = true
	}
	style: Style
	for count, flag in b.styles {if count > 0 {style += {flag}}}
	link := len(b.link_stack) > 0 ? b.link_stack[len(b.link_stack) - 1] : NO_LINK
	start := len(b.doc.text)
	if _, err := append(&b.doc.text, text); err != nil {return false}
	block := b.doc.blocks[len(b.doc.blocks) - 1]
	if len(b.doc.spans) > block.first_span {
		last := &b.doc.spans[len(b.doc.spans) - 1]
		if last.end == start && last.style == style && last.link == link {
			last.end = len(b.doc.text)
			return true
		}
	}
	_, err := append(&b.doc.spans, Span{start, len(b.doc.text), style, link})
	return err == nil
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
		out := strings.builder_make(context.temp_allocator)
		write_entity(&out, string(text[:size]))
		ok = text_append(b, strings.to_string(out))
	case:
		ok = text_append(b, string(text[:size]))
	}
	return ok ? 0 : fail(b)
}
