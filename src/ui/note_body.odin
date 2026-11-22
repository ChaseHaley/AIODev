package ui

import "cosmos:render"
import "aio:syntax"
import "core:math"
import "core:strings"
import "core:unicode/utf8"

// The text of a saved note, read-only: paragraphs with **bold** and `inline code`, fenced code blocks in
// mono with the diff's syntax colours, and ```suggestion blocks drawn as a small diff of the replaced
// lines against the new ones. One layout at a width gives the height and the painted rows, so a card is
// painted at the height it was measured. Code lines wrap where they run out of room, as the paragraphs do.

// How a run of a paragraph's text is set.
Note_Style :: enum u8 {
	Plain,
	Bold,
	Code,
}

Note_Block_Kind :: enum u8 {
	Paragraph,
	Code,
	Suggestion,
}

// A part of a note's text: a paragraph, or a fenced block with the word after its opening fence. `text` is
// the paragraph as written, with its line breaks at either end, or the block's body without the line break
// before its closing fence.
Note_Block :: struct {
	kind: Note_Block_Kind,
	text: string,
	lang: string,
}

// Splits a note's text into blocks, one at a time and without allocating. A fence opens with three
// backticks, a language word and the rest of its line, and closes at the next three backticks; one that
// never closes is text.
Note_Scan :: struct {
	rest:        string,
	pending:     Note_Block,
	has_pending: bool,
}

@(private = "file")
is_word_byte :: proc(c: u8) -> bool {
	return c == '_' || (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

// The first complete fenced block of `s`: where its opening fence starts, the block and where it ends.
@(private = "file")
note_fence_find :: proc(s: string) -> (open: int, block: Note_Block, end: int, found: bool) {
	open = strings.index(s, "```")
	if open < 0 {return}
	after := s[open + 3:]
	lang_end := 0
	for lang_end < len(after) && is_word_byte(after[lang_end]) {lang_end += 1}
	line_end := strings.index_byte(after[lang_end:], '\n')
	if line_end < 0 {return}
	body_from := lang_end + line_end + 1
	close := strings.index(after[body_from:], "```")
	if close < 0 {return}
	block.lang = after[:lang_end]
	block.kind = block.lang == "suggestion" ? .Suggestion : .Code
	block.text = strings.trim_suffix(after[body_from:][:close], "\n")
	return open, block, open + 3 + body_from + close + 3, true
}

note_block_next :: proc(s: ^Note_Scan) -> (block: Note_Block, ok: bool) {
	if s.has_pending {
		s.has_pending = false
		return s.pending, true
	}
	if s.rest == "" {return}
	open, fenced, end, found := note_fence_find(s.rest)
	if !found {
		block = {
			kind = .Paragraph,
			text = s.rest,
		}
		s.rest = ""
		return block, true
	}
	before := s.rest[:open]
	s.rest = s.rest[end:]
	if before == "" {return fenced, true}
	s.pending, s.has_pending = fenced, true
	return {kind = .Paragraph, text = before}, true
}

// The syntax language a fence word names, else `fallback`: a language's name or a file extension.
@(private = "file")
note_language :: proc(word: string, fallback: syntax.Language) -> syntax.Language {
	switch word {
	case "":
		return fallback
	case "python":
		return .Python
	case "javascript":
		return .JavaScript
	case "typescript":
		return .TypeScript
	case "rust":
		return .Rust
	case "powershell":
		return .PowerShell
	case "shell":
		return .Shell
	}
	if language := syntax.language_for_path(strings.concatenate({"x.", word}, context.temp_allocator));
	   language != .None {
		return language
	}
	return fallback
}

// What a row of the laid-out body is: a line of a paragraph, a suggestion's heading, a line of a code block,
// or a line a suggestion removes or adds.
Note_Row_Kind :: enum u8 {
	Text,
	Header,
	Code,
	Removed,
	Added,
}

// A run of a paragraph's text in one style, `x` from the body's left edge. A code run's width includes the
// padding of its chip.
Note_Piece :: struct {
	text:     string,
	style:    Note_Style,
	x, width: f32,
}

// One row of the body, `y` from its top. A text row's pieces are `first` and the `count` after it in the
// layout's pieces. A code, removed or added row has its line's `text` and that line's number in the block's
// body, or in the replaced lines for a removed row, which find its syntax colours; `frame` is the block it
// is in, -1 for text.
Note_Row :: struct {
	kind:         Note_Row_Kind,
	y, height:    f32,
	first, count: int,
	text:         string,
	// Where `text` starts in its line, for a row that continues a line which ran past the room.
	base:         int,
	line, frame:  int,
}

// The box a fenced block or suggestion is drawn in. `body` is the block's text, which the syntax colours
// come from.
Note_Frame :: struct {
	kind:       Note_Block_Kind,
	lang, body: string,
	y, height:  f32,
}

// The syntax colours of one frame: those of its code, and for a suggestion those of the lines it replaces.
Note_Frame_Spans :: struct {
	code, removed: syntax.File_Lines,
}

Note_Layout :: struct {
	rows:     [dynamic]Note_Row,
	pieces:   [dynamic]Note_Piece,
	frames:   [dynamic]Note_Frame,
	// The replaced lines a suggestion shows, which the caller keeps while it draws.
	original: []string,
	// The colours of each frame's code, from note_body_highlight; a frame without an entry is plain.
	spans:    []Note_Frame_Spans,
	width:    f32,
	height:   f32,
}

// One word of a paragraph line: its text, its style and the spaces before it. A code span is one word.
@(private = "file")
Inline_Word :: struct {
	text:   string,
	style:  Note_Style,
	spaces: int,
}

@(private = "file")
Inline_Scan :: struct {
	rest:    string,
	// What is left of a bold span being read word by word.
	bold:    string,
	in_bold: bool,
}

// The text between `open` and the next `close` when `s` starts with a span: not empty, and for bold without
// a star in it. `length` is the whole span's.
@(private = "file")
span_between :: proc(s: string, open, close: string) -> (inner: string, length: int, ok: bool) {
	if !strings.has_prefix(s, open) {return}
	end := strings.index(s[len(open):], close)
	if end <= 0 {return}
	inner = s[len(open):][:end]
	if open == "**" && strings.contains_rune(inner, '*') {return}
	return inner, len(open) + end + len(close), true
}

@(private = "file")
inline_next :: proc(s: ^Inline_Scan) -> (word: Inline_Word, ok: bool) {
	from := s.in_bold ? &s.bold : &s.rest
	spaces := 0
	for spaces < len(from^) && from^[spaces] == ' ' {spaces += 1}
	from^ = from^[spaces:]
	if from^ == "" {
		if !s.in_bold {return}
		s.in_bold = false
		word, ok = inline_next(s)
		word.spaces += spaces
		return word, ok
	}
	if s.in_bold {
		if inner, length, found := span_between(s.bold, "`", "`"); found {
			s.bold = s.bold[length:]
			if s.bold == "" {s.in_bold = false}
			return {inner, .Code, spaces}, true
		}
		// A bold word ends at a space or where a code span may start.
		end := 1
		for end < len(s.bold) && s.bold[end] != ' ' && s.bold[end] != '`' {end += 1}
		word = {s.bold[:end], .Bold, spaces}
		s.bold = s.bold[end:]
		if s.bold == "" {s.in_bold = false}
		return word, true
	}
	if inner, length, found := span_between(s.rest, "`", "`"); found {
		s.rest = s.rest[length:]
		return {inner, .Code, spaces}, true
	}
	if inner, length, found := span_between(s.rest, "**", "**"); found {
		s.rest = s.rest[length:]
		s.bold, s.in_bold = inner, true
		word, ok = inline_next(s)
		word.spaces += spaces
		return word, ok
	}
	// A plain word ends at a space or where a span may start; a marker that opens it is text.
	end := 1
	for end < len(s.rest) {
		c := s.rest[end]
		if c == ' ' || c == '`' || strings.has_prefix(s.rest[end:], "**") {break}
		end += 1
	}
	word = {s.rest[:end], .Plain, spaces}
	s.rest = s.rest[end:]
	return word, true
}

// The fonts and sizes a body is laid out and drawn with.
@(private = "file")
Note_Metrics :: struct {
	body, strong, mono:              Text,
	// The padding of an inline code chip, a code row's height, the padding inside a code frame, the gap
	// between blocks, a suggestion's heading and a space.
	chip, row, pad, gap, head, space: f32,
	// The diff font's metrics and how much room a code row's text has, which a code line wraps at.
	code:                            Code_Font,
	room:                            f32,
}

@(private = "file")
word_width :: proc(m: ^Note_Metrics, text: string, style: Note_Style) -> f32 {
	switch style {
	case .Plain:
		return text_width(&m.body, text)
	case .Bold:
		return text_width(&m.strong, text)
	case .Code:
		return text_width(&m.mono, text) + 2 * m.chip
	}
	return 0
}

// The bytes of the start of `text` that fit `limit`, at least one rune.
@(private = "file")
cut_fit :: proc(m: ^Note_Metrics, text: string, style: Note_Style, limit: f32) -> int {
	used := f32(0)
	for r, at in text {
		size := utf8.rune_size(r)
		used += word_width(m, text[at:at + size], style) - (style == .Code ? 2 * m.chip : 0)
		if used > limit - (style == .Code ? 2 * m.chip : 0) && at > 0 {return at}
	}
	return len(text)
}

// Lays one line of a paragraph into rows of pieces no wider than the layout, from `y`; returns where the
// next row starts. A word wider than a row is cut where it runs out.
@(private = "file")
paragraph_line :: proc(l: ^Note_Layout, m: ^Note_Metrics, line: string, y: f32) -> f32 {
	y := y
	height := m.body.line_height
	first, x := len(l.pieces), f32(0)
	end_row :: proc(l: ^Note_Layout, first: int, y, height: f32) {
		row := Note_Row {
			kind   = .Text,
			y      = y,
			height = height,
			first  = first,
			count  = len(l.pieces) - first,
			frame  = -1,
		}
		_, _ = append(&l.rows, row)
	}
	scan := Inline_Scan {
		rest = line,
	}
	for {
		word, ok := inline_next(&scan)
		if !ok {break}
		sep := x > 0 ? f32(word.spaces) * m.space : 0
		text, w := word.text, word_width(m, word.text, word.style)
		if x > 0 && x + sep + w > l.width {
			end_row(l, first, y, height)
			y, first, x, sep = y + height, len(l.pieces), 0, 0
		}
		for w > l.width && len(text) > 1 {
			cut := cut_fit(m, text, word.style, l.width)
			if cut >= len(text) {break}
			piece := Note_Piece {
				text  = text[:cut],
				style = word.style,
				x     = x + sep,
				width = word_width(m, text[:cut], word.style),
			}
			_, _ = append(&l.pieces, piece)
			end_row(l, first, y, height)
			y, first, x, sep = y + height, len(l.pieces), 0, 0
			text = text[cut:]
			w = word_width(m, text, word.style)
		}
		_, _ = append(&l.pieces, Note_Piece{text = text, style = word.style, x = x + sep, width = w})
		x += sep + w
	}
	end_row(l, first, y, height)
	return y + height
}

// How much room the text of a code row has in a body `width` wide: what is left of the width after the
// padding at both ends and the sign's column. A digit is the sign's width.
@(private = "file")
note_code_room :: proc(width, digit, scale: f32) -> f32 {
	return max(0, width - 2 * SPACE_2 * scale - digit - SPACE_1 * scale)
}

// Lays line `index` of a block, which finds its syntax colours, as code rows from `y`: one row, or several
// where it runs past the room, each starting where the one before it ran out. Returns where the next row
// starts.
@(private = "file")
code_rows_append :: proc(
	l: ^Note_Layout, m: ^Note_Metrics, kind: Note_Row_Kind, y: f32, line: string, index, frame: int,
) -> f32 {
	y, base := y, 0
	for {
		rest := line[base:]
		cut := code_fit(&m.mono, m.code, rest, m.room)
		row := Note_Row {
			kind   = kind,
			y      = y,
			height = m.row,
			text   = rest[:cut],
			base   = base,
			line   = index,
			frame  = frame,
		}
		_, _ = append(&l.rows, row)
		y += m.row
		base += cut
		if base >= len(line) {return y}
	}
}

// Lays `source` out in `width`, in `allocator`: temporary memory for a layout drawn at once, or the
// memory of a cache that keeps it. The layout points into `source` and `original`, which the caller keeps
// as long as the layout. `text` is the interface text and `mono` the diff's; `original` is the new-side
// lines a suggestion replaces, shown as removed rows above its own lines as added ones.
note_body_layout :: proc(
	text, mono: ^Text, source: string, original: []string, width, scale: f32,
	allocator := context.temp_allocator,
) -> Note_Layout {
	m := Note_Metrics {
		body   = text_styled(text, .Body),
		strong = text_styled(text, .Strong),
		mono   = mono^,
	}
	m.chip = SPACE_1 * scale
	m.row = f32(max(1, int(mono.line_height) + int(math.round(2 * scale))))
	m.pad = math.round(SPACE_1 * scale)
	m.gap = math.round(SPACE_1 * scale)
	m.head = math.round(HEIGHT_COMPACT * scale)
	m.space = text_width(&m.body, " ")
	m.code = code_font(mono)
	m.room = note_code_room(width, m.code.cell, scale)
	l := Note_Layout {
		rows     = make([dynamic]Note_Row, allocator),
		pieces   = make([dynamic]Note_Piece, allocator),
		frames   = make([dynamic]Note_Frame, allocator),
		original = original,
		width    = width,
	}
	y := f32(0)
	started := false
	scan := Note_Scan {
		rest = source,
	}
	for block in note_block_next(&scan) {
		paragraph := strings.trim(block.text, "\n")
		if block.kind == .Paragraph && paragraph == "" {continue}
		if started {y += m.gap}
		started = true
		if block.kind == .Paragraph {
			rest := paragraph
			for line in strings.split_iterator(&rest, "\n") {
				y = paragraph_line(&l, &m, strings.trim_right(line, "\r"), y)
			}
			continue
		}
		frame := len(l.frames)
		top := y
		if block.kind == .Suggestion {
			_, _ = append(&l.rows, Note_Row{kind = .Header, y = y, height = m.head, frame = frame})
			y += m.head
			for line, i in original {
				y = code_rows_append(&l, &m, .Removed, y, line, i, frame)
			}
		} else {
			y += m.pad
		}
		body := block.text
		for line, i in strings.split(body, "\n", allocator) {
			kind: Note_Row_Kind = block.kind == .Suggestion ? .Added : .Code
			y = code_rows_append(&l, &m, kind, y, strings.trim_right(line, "\r"), i, frame)
		}
		y += m.pad
		laid := Note_Frame {
			kind   = block.kind,
			lang   = block.lang,
			body   = body,
			y      = top,
			height = y - top,
		}
		_, _ = append(&l.frames, laid)
	}
	l.height = y
	return l
}

// Gives each frame of `l` the syntax colours of its code, and a suggestion's those of the lines it
// replaces, in `allocator`. `language` is the note's file's, for blocks that name none. Colours are found
// once here, not per frame drawn.
note_body_highlight :: proc(l: ^Note_Layout, language: syntax.Language, allocator := context.temp_allocator) {
	l.spans = make([]Note_Frame_Spans, len(l.frames), allocator)
	for frame, i in l.frames {
		l.spans[i].code, _ = syntax.highlight(note_language(frame.lang, language), frame.body, allocator)
		if frame.kind == .Suggestion && len(l.original) > 0 {
			joined := strings.join(l.original, "\n", context.temp_allocator)
			l.spans[i].removed, _ = syntax.highlight(language, joined, allocator)
		}
	}
}

@(private = "file")
spans_of :: proc(file: syntax.File_Lines, line: int) -> []syntax.Span {
	return line >= 0 && line < len(file.lines) ? file.lines[line] : nil
}

// Draws the rows of `l` from `origin`, the body's top left, in the rows between `top` and `bottom`.
// `inks` is the diff's, built for the theme.
note_body_draw :: proc(
	list: ^render.Draw_List,
	text, mono: ^Text,
	theme: Theme,
	inks: ^Changes_Inks,
	l: ^Note_Layout,
	origin: [2]f32,
	scale, top, bottom: f32,
) -> render.Build_Status {
	body := text_styled(text, .Body)
	strong := text_styled(text, .Strong)
	detail := text_styled(text, .Detail)
	chip := SPACE_1 * scale
	radius := RADIUS_CONTROL * scale
	code := code_font(mono)
	digit := code.cell
	sign_x := origin.x + SPACE_2 * scale
	text_x := sign_x + digit + SPACE_1 * scale
	room := note_code_room(l.width, digit, scale)
	// A frame's rows are drawn over its fill and under its outline, which the second pass puts on top.
	for frame in l.frames {
		y := origin.y + frame.y
		if y >= bottom || y + frame.height <= top {continue}
		fill := render.Rect{origin.x, y, l.width, frame.height}
		draw_rect(list, {rect = fill, color = theme.code_background, radius = radius})
	}
	for row in l.rows {
		y := origin.y + row.y
		if y >= bottom {break}
		if y + row.height <= top {continue}
		spans, removed_spans: syntax.File_Lines
		if row.frame >= 0 && row.frame < len(l.spans) {
			spans, removed_spans = l.spans[row.frame].code, l.spans[row.frame].removed
		}
		switch row.kind {
		case .Text:
			baseline := baseline_in(y, row.height, &body)
			for piece in l.pieces[row.first:][:row.count] {
				x := origin.x + piece.x
				switch piece.style {
				case .Plain:
					if r := draw_text(&body, list, piece.text, x, baseline, theme.text); r != .Ok {return r}
				case .Bold:
					if r := draw_text(&strong, list, piece.text, x, baseline, theme.text); r != .Ok {return r}
				case .Code:
					high := mono.line_height
					at := render.Rect{x, y + (row.height - high) / 2, piece.width, high}
					draw_rect(list, {rect = at, color = theme.code_background, radius = radius})
					if r := draw_text(mono, list, piece.text, x + chip, baseline, theme.text); r != .Ok {return r}
				}
			}
		case .Header:
			size := ICON_INDICATOR * scale
			icon_draw(list, .Pencil, {sign_x, y, size, row.height}, theme.muted, ICON_INDICATOR, scale)
			label := "Suggested change"
			label_x := sign_x + size + SPACE_1 * scale
			baseline := baseline_in(y, row.height, &detail)
			if r := draw_text(&detail, list, label, label_x, baseline, theme.muted); r != .Ok {return r}
		case .Code, .Removed, .Added:
			background: Changes_Background = .Context
			sign: string
			sign_ink := -1
			file := spans
			#partial switch row.kind {
			case .Removed:
				background, sign, sign_ink, file = .Removed, "-", CHANGES_INK_REMOVED_SIGN, removed_spans
				draw_rect(list, {rect = {origin.x, y, l.width, row.height}, color = theme.diff_removed})
			case .Added:
				background, sign, sign_ink = .Added, "+", CHANGES_INK_ADDED_SIGN
				draw_rect(list, {rect = {origin.x, y, l.width, row.height}, color = theme.diff_added})
			}
			table := &inks.table[background]
			baseline := baseline_in(y, row.height, mono)
			if sign != "" && row.base == 0 {
				if r := draw_text(mono, list, sign, sign_x, baseline, table[sign_ink]); r != .Ok {return r}
			}
			line := Code_Line {
				text     = row.text,
				base     = row.base,
				spans    = spans_of(file, row.line),
				font     = code,
				x        = text_x,
				width    = room,
				top      = y,
				height   = row.height,
				baseline = baseline,
				scale    = scale,
				inks     = table,
				plain    = CHANGES_INK_TEXT,
			}
			if r := code_line_draw(list, mono, line); r != .Ok {return r}
		}
	}
	for frame in l.frames {
		y := origin.y + frame.y
		if y >= bottom || y + frame.height <= top {continue}
		outline := render.Rect{origin.x, y, l.width, frame.height}
		draw_rect(list, {rect = outline, color = theme.border, radius = radius, stroke = scale})
	}
	return .Ok
}
