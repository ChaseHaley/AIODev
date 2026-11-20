package settings

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

SAVED_FILTERS_KEY :: "turns.saved_filters"

// The documented shape of a saved-filters value. The settings description and the diagnostic for a
// malformed value both show it, so a grammar change updates the example with the parser.
SAVED_FILTERS_EXAMPLE :: "* | !^vendor/; Source | src/ !_test"

SAVED_FILTERS_MAX :: 4096
SAVED_FILTER_NAME_MAX :: 32
SAVED_FILTER_PATTERN_MAX :: 120

// `;` ends a filter, `|` ends the name, `"` is the token's quote and a line break ends the setting, so
// no name can hold any of them. A pattern may hold `|`, which regular expressions use, but not `;` or a
// quote, since a filter without a name is labelled by its pattern.
@(private)
SAVED_FILTER_NAME_FORBIDDEN :: ";|\"\r\n\x00"
@(private)
SAVED_FILTER_PATTERN_FORBIDDEN :: ";\"\r\n\x00"

// One `[* ]name | pattern` entry, as slices of the value; `| pattern` has no name and shows its pattern, and
// a leading `*` marks a filter on by default, which new Agent changes panes start with. The pattern is the
// diff filter's grammar: space-separated regular expressions on a path, a term starting with `!` hiding what
// it matches.
Saved_Filter :: struct {
	name, pattern: string,
	default:       bool,
}

// A cursor over the `;`-separated filters. A blank value has no filters; anywhere else an empty item is
// malformed, which makes a trailing or doubled separator follow the same rule as an empty name.
Saved_Filters_Cursor :: struct {
	rest: string,
	done: bool,
}

@(require_results)
saved_filters_scan :: proc(value: string) -> Saved_Filters_Cursor {
	if strings.trim_space(value) == "" {return {done = true}}
	return {rest = value}
}

// Yields every entry in order. A setting value is checked when it is loaded, so the entries a running
// program reads are well formed.
@(require_results)
saved_filters_next :: proc(c: ^Saved_Filters_Cursor) -> (filter: Saved_Filter, ok: bool) {
	filter, _, ok = saved_filters_step(c)
	return
}

@(private, require_results)
saved_filters_step :: proc(c: ^Saved_Filters_Cursor) -> (filter: Saved_Filter, valid, more: bool) {
	if c.done {return {}, false, false}
	text := c.rest
	if end := strings.index_byte(text, ';'); end >= 0 {
		c.rest = text[end + 1:]
		text = text[:end]
	} else {
		c.done = true
	}
	filter, valid = saved_filter_parse(text)
	return filter, valid, true
}

@(private, require_results)
saved_filter_parse :: proc(text: string) -> (filter: Saved_Filter, valid: bool) {
	entry := strings.trim_space(text)
	if strings.has_prefix(entry, "*") {
		filter.default = true
		entry = entry[1:]
	}
	bar := strings.index_byte(entry, '|')
	if bar < 0 {return {name = strings.trim_space(entry), default = filter.default}, false}
	filter.name = strings.trim_space(entry[:bar])
	filter.pattern = strings.trim_space(entry[bar + 1:])
	valid = saved_filter_pattern_valid(filter.pattern)
	if filter.name != "" && !saved_filter_name_valid(filter.name) {valid = false}
	return
}

// A name is optional: up to SAVED_FILTER_NAME_MAX characters of one-line text without `;`, `|` or quotes, and
// not starting with `*`, which marks a filter on by default.
@(require_results)
saved_filter_name_valid :: proc(name: string) -> bool {
	if name == "" || len(name) > SAVED_FILTER_NAME_MAX || name[0] == '*' {return false}
	if strings.contains_any(name, SAVED_FILTER_NAME_FORBIDDEN) {return false}
	for r in name {
		if unicode.is_space(r) && r != ' ' {return false}
	}
	return true
}

@(require_results)
saved_filter_pattern_valid :: proc(pattern: string) -> bool {
	if pattern == "" || len(pattern) > SAVED_FILTER_PATTERN_MAX {return false}
	return !strings.contains_any(pattern, SAVED_FILTER_PATTERN_FORBIDDEN)
}

// The text a token for `filter` carries and the field shows: its name, or its pattern while it has none.
@(require_results)
saved_filter_label :: proc(filter: Saved_Filter) -> string {
	return filter.name == "" ? filter.pattern : filter.name
}

// The filter a token labelled `label` names, compared without case, and its position; false when none.
@(require_results)
saved_filters_find :: proc(value, label: string) -> (filter: Saved_Filter, index: int, found: bool) {
	cursor := saved_filters_scan(value)
	for next in saved_filters_next(&cursor) {
		if strings.equal_fold(saved_filter_label(next), label) {return next, index, true}
		index += 1
	}
	return {}, -1, false
}

// The filter whose pattern is exactly `pattern`, and its position; false when none.
@(require_results)
saved_filters_find_pattern :: proc(
	value, pattern: string,
) -> (
	filter: Saved_Filter,
	index: int,
	found: bool,
) {
	cursor := saved_filters_scan(value)
	for next in saved_filters_next(&cursor) {
		if next.pattern == pattern {return next, index, true}
		index += 1
	}
	return {}, -1, false
}

// What an edited filter cannot store, reported for the first filter that has one: its name, its pattern, or
// a label (its name, else its pattern) that an earlier filter has.
Saved_Filter_Problem :: enum u8 {
	Name,
	Duplicate,
	Pattern,
	Too_Long,
}

// One edited filter; each field is the raw text typed for it.
Saved_Filter_Draft :: struct {
	name, pattern: string,
	default:       bool,
}

// Encodes edited filters in the grammar saved_filters_next reads back, or reports the first field of the
// first filter it cannot store; a refused draft encodes nothing.
@(require_results)
saved_filters_text :: proc(
	filters: []Saved_Filter_Draft,
	allocator := context.allocator,
) -> (
	text: string,
	problem: Maybe(Saved_Filter_Problem),
	err: runtime.Allocator_Error,
) {
	for filter, index in filters {
		if problem = saved_filter_check(filter, filters[:index]); problem != nil {return}
	}
	builder := strings.builder_make(allocator) or_return
	for filter, index in filters {
		if index > 0 {strings.write_string(&builder, "; ")}
		if filter.default {strings.write_string(&builder, "* ")}
		if name := strings.trim_space(filter.name); name != "" {
			strings.write_string(&builder, name)
			strings.write_byte(&builder, ' ')
		}
		strings.write_string(&builder, "| ")
		strings.write_string(&builder, strings.trim_space(filter.pattern))
	}
	if strings.builder_len(builder) > SAVED_FILTERS_MAX {
		strings.builder_destroy(&builder)
		return "", Saved_Filter_Problem.Too_Long, nil
	}
	return strings.to_string(builder), nil, nil
}

@(private, require_results)
saved_filter_check :: proc(
	filter: Saved_Filter_Draft, before: []Saved_Filter_Draft,
) -> Maybe(Saved_Filter_Problem) {
	name, pattern := strings.trim_space(filter.name), strings.trim_space(filter.pattern)
	if name != "" && !saved_filter_name_valid(name) {return Saved_Filter_Problem.Name}
	if !saved_filter_pattern_valid(pattern) {return Saved_Filter_Problem.Pattern}
	label := name == "" ? pattern : name
	for earlier in before {
		earlier_name := strings.trim_space(earlier.name)
		if earlier_name == "" {earlier_name = strings.trim_space(earlier.pattern)}
		if strings.equal_fold(earlier_name, label) {return Saved_Filter_Problem.Duplicate}
	}
	return nil
}

@(private, require_results)
saved_filters_valid :: proc(value: string) -> bool {
	if len(value) > SAVED_FILTERS_MAX {return false}
	cursor := saved_filters_scan(value)
	index := 0
	for {
		filter, valid, more := saved_filters_step(&cursor)
		if !more {break}
		if !valid {return false}
		label := saved_filter_label(filter)
		if _, earlier, found := saved_filters_find(value, label); found && earlier != index {return false}
		index += 1
	}
	return true
}

// Built from the parser's own limits and example, so the diagnostic cannot describe a grammar the
// parser does not accept.
@(private, require_results)
saved_filters_rules :: proc(buffer: []u8) -> string {
	return fmt.bprintf(
		buffer,
		"Each filter is name | pattern, and the name may be left out; a leading * marks a filter new Agent " +
		"changes panes start with. A name is up to %d characters without " +
		"; | or quotes. A pattern is regular expressions on a path, a term starting with ! hiding what it " +
		"matches, up to %d characters without ; or quotes. A filter's name, or its pattern when it has no " +
		"name, is used once. A value looks like %s.",
		SAVED_FILTER_NAME_MAX,
		SAVED_FILTER_PATTERN_MAX,
		SAVED_FILTERS_EXAMPLE,
	)
}

// A saved filter in the diff filter's text: `@name`, or `@"two words"` for a name with spaces, and a `~`
// before the `@` for one that is off. The text around tokens is the filter's own terms.
Filter_Word :: struct {
	// Byte offsets of the word, `start` at its first byte and `end` after its last.
	start, end: int,
	// A token: `name` is the saved filter it names, without quotes, and `off` marks it dimmed.
	token, off: bool,
	name:       string,
}

@(private)
filter_space :: proc(text: string, at: int) -> (width: int, space: bool) {
	r, size := utf8.decode_rune_in_string(text[at:])
	return size, unicode.is_space(r)
}

// The first word of `text` at or after `at`: where it starts and ends, and whether it is a token. A word
// is a run of non-space text, or a quoted token name with the spaces inside it. `@"` with no closing quote,
// an empty name and a closing quote followed by more text are plain words, so a stray quote costs one term
// rather than the rest of the text.
@(require_results)
filter_word_next :: proc(text: string, at: int) -> (word: Filter_Word, ok: bool) {
	start := at
	for start < len(text) {
		size, space := filter_space(text, start)
		if !space {break}
		start += size
	}
	if start >= len(text) {return {}, false}
	end := start
	for end < len(text) {
		size, space := filter_space(text, end)
		if space {break}
		end += size
	}
	word = {
		start = start,
		end   = end,
	}
	rest := text[start:end]
	off := strings.has_prefix(rest, "~@")
	prefix := off ? 2 : 1
	if !off && !strings.has_prefix(rest, "@") {return word, true}
	body := text[start + prefix:]
	if strings.has_prefix(body, "\"") {
		close := strings.index_byte(body[1:], '"')
		if close < 1 {return word, true}
		stop := start + prefix + 1 + close + 1
		if stop < len(text) {
			if _, space := filter_space(text, stop); !space {return word, true}
		}
		word.end, word.token, word.off, word.name = stop, true, off, body[1:1 + close]
		return word, true
	}
	name := rest[prefix:]
	if name == "" || strings.contains_rune(name, '"') {return word, true}
	word.token, word.off, word.name = true, off, name
	return word, true
}

// Writes the token for `name` into `buffer` and returns it: bare when the name has no spaces, quoted when
// it has. The buffer must hold the name and four more bytes.
@(require_results)
filter_token_format :: proc(buffer: []u8, name: string, off: bool) -> string {
	quoted := strings.contains_any(name, " \t")
	n := 0
	put :: proc(buffer: []u8, n: ^int, text: string) {
		n^ += copy(buffer[n^:], text)
	}
	if off {put(buffer, &n, "~")}
	put(buffer, &n, "@")
	if quoted {put(buffer, &n, "\"")}
	put(buffer, &n, name)
	if quoted {put(buffer, &n, "\"")}
	return string(buffer[:n])
}

// The text a new Agent changes pane starts with: every filter marked on by default as an on token, in order.
@(require_results)
saved_filters_default_text :: proc(
	value: string,
	allocator := context.allocator,
) -> (
	text: string,
	err: runtime.Allocator_Error,
) {
	builder := strings.builder_make(allocator) or_return
	buffer: [SAVED_FILTER_PATTERN_MAX + 8]u8
	cursor := saved_filters_scan(value)
	for filter in saved_filters_next(&cursor) {
		if !filter.default {continue}
		if strings.builder_len(builder) > 0 {strings.write_byte(&builder, ' ')}
		strings.write_string(&builder, filter_token_format(buffer[:], saved_filter_label(filter), false))
	}
	return strings.to_string(builder), nil
}
