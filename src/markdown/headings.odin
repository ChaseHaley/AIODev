package markdown

import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

// The text a block reads as, from its first span to its last; a list marker is not part of it.
block_text :: proc(doc: ^Document, block: Block) -> (text: string, start: int) {
	if block.span_count == 0 {return "", block.marker_end}
	first := doc.spans[block.first_span]
	last := doc.spans[block.first_span + block.span_count - 1]
	return string(doc.text[first.start:last.end]), first.start
}

// The document offset of the heading `name` refers to. A heading matches when both read the same once
// case, punctuation and the spaces or hyphens between words are set aside, so Obsidian's
// `#Heading Text`, a percent-encoded `#Heading%20Text` and GitHub's `#heading-text` all find it.
heading_find :: proc(doc: ^Document, name: string) -> (offset: int, found: bool) {
	wanted := slug(percent_decoded(name, context.temp_allocator), context.temp_allocator)
	if wanted == "" {return 0, false}
	for block in doc.blocks {
		if block.kind != .Heading {continue}
		text, start := block_text(doc, block)
		if slug(text, context.temp_allocator) == wanted {return start, true}
	}
	return 0, false
}

// Letters and digits in lower case, with one hyphen for each run of anything else between them.
@(private)
slug :: proc(text: string, allocator := context.allocator) -> string {
	out := strings.builder_make(allocator)
	gap := false
	for r in text {
		if unicode.is_letter(r) || unicode.is_digit(r) {
			if gap && strings.builder_len(out) > 0 {strings.write_byte(&out, '-')}
			strings.write_rune(&out, unicode.to_lower(r))
			gap = false
		} else {
			gap = true
		}
	}
	return strings.to_string(out)
}

// `%XX` escapes decoded; anything malformed stays as written.
@(private)
percent_decoded :: proc(text: string, allocator := context.allocator) -> string {
	if strings.index_byte(text, '%') < 0 {return text}
	out := make([dynamic]u8, 0, len(text), allocator)
	for i := 0; i < len(text); i += 1 {
		if text[i] == '%' && i + 2 < len(text) && hex(text[i + 1]) >= 0 && hex(text[i + 2]) >= 0 {
			append(&out, u8(hex(text[i + 1]) * 16 + hex(text[i + 2])))
			i += 2
			continue
		}
		append(&out, text[i])
	}
	if !utf8.valid_string(string(out[:])) {return text}
	return string(out[:])
}

@(private)
hex :: proc(c: u8) -> int {
	switch c {
	case '0' ..= '9': return int(c - '0')
	case 'a' ..= 'f': return int(c - 'a') + 10
	case 'A' ..= 'F': return int(c - 'A') + 10
	}
	return -1
}
