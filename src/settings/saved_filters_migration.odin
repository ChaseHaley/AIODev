package settings

import "base:runtime"
import "core:strings"

// Two changes to how saved filters are stored, both folded in when the file loads. turns.diff_filter was
// the filter a new Agent changes pane started with; saved filters took its place, each carrying an "on by
// default" mark, so the key is retired. And a saved filter is identified by an id, which an entry written
// before ids existed (or typed in by hand without one) is given here.
@(private = "file")
RETIRED_DIFF_FILTER_KEY :: "turns.diff_filter"

// The name a default filter gets when its pattern is already another filter's name.
@(private = "file")
MIGRATED_FILTER_NAME :: "Default filter"

@(private = "file")
Migrated_Filter :: struct {
	id, name, pattern: string,
	default:           bool,
}

// Gives every saved filter without an id one, and folds what the retired key held into the saved filters.
// Each token in it that is on and names a saved filter by its label marks that filter on by default; the
// plain terms become a saved filter, named by those terms and marked on by default (or mark the saved filter
// that already has that pattern). The key is dropped with the comment directly above it. A file whose saved
// filters cannot be read is left as it is.
@(require_results)
migrate_saved_filters_text :: proc(
	text: string,
	allocator := context.allocator,
) -> (
	updated: string,
	migrated: bool,
	err: runtime.Allocator_Error,
) {
	retired, library := "", ""
	found, has_library := false, false
	scanner := line_scanner_init(text)
	for {
		line, ok := line_next(&scanner)
		if !ok {break}
		if !line.split {continue}
		switch line.key {
		case RETIRED_DIFF_FILTER_KEY:
			found = true
			retired, _ = text_value_decode(line.value)
		case SAVED_FILTERS_KEY:
			has_library = true
			library, _ = text_value_decode(line.value)
		}
	}
	if !saved_filters_valid(library, ids_required = false) {return "", false, nil}

	filters := make([dynamic]Migrated_Filter, context.temp_allocator)
	cursor := saved_filters_scan(library)
	missing := false
	for filter in saved_filters_next(&cursor) {
		_, _ = append(&filters, Migrated_Filter{filter.id, filter.name, filter.pattern, filter.default})
		if filter.id == "" {missing = true}
	}
	if !found && !missing {return "", false, nil}
	plain := make([dynamic]string, context.temp_allocator)
	at := 0
	for {
		word, more := filter_word_next(retired, at)
		if !more {break}
		at = word.end
		if !word.token {
			_, _ = append(&plain, retired[word.start:word.end])
			continue
		}
		if word.off {continue}
		for &filter in filters {
			if strings.equal_fold(word.name, filter.name == "" ? filter.pattern : filter.name) {
				filter.default = true
			}
		}
	}
	pattern := strings.join(plain[:], " ", context.temp_allocator)
	if pattern != "" && saved_filter_pattern_valid(pattern) {
		known := false
		for &filter in filters {
			if filter.pattern == pattern {
				filter.default, known = true, true
			}
		}
		if !known {
			name := ""
			for filter in filters {
				if strings.equal_fold(filter.name == "" ? filter.pattern : filter.name, pattern) {
					name = MIGRATED_FILTER_NAME
				}
			}
			_, _ = append(&filters, Migrated_Filter{"", name, pattern, true})
		}
	}
	drafts := make([]Saved_Filter_Draft, len(filters), context.temp_allocator)
	for filter, i in filters {drafts[i] = {filter.id, filter.name, filter.pattern, filter.default}}
	for &draft in drafts {
		if draft.id == "" {draft.id = saved_filter_id_make(drafts)}
	}
	value, problem, text_error := saved_filters_text(drafts, context.temp_allocator)
	if text_error != nil {return "", false, text_error}
	if _, refused := problem.?; refused {return "", false, nil}
	write_library := len(filters) > 0 && (value != library || !has_library)

	builder := strings.builder_make(allocator) or_return
	defer strings.builder_destroy(&builder)
	rescanner := line_scanner_init(text)
	if rescanner.bom {write_parts(&builder, UTF8_BOM) or_return}
	written := false
	held: string
	for {
		line, ok := line_next(&rescanner)
		if !ok {break}
		if line.split && line.key == RETIRED_DIFF_FILTER_KEY {
			if write_library && !has_library && !written {
				if held != "" {
					description := schema_find(SAVED_FILTERS_KEY).description
					write_parts(&builder, "# ", description, line.eol) or_return
				}
				write_parts(&builder, SAVED_FILTERS_KEY, " = \"", value, "\"", line.eol) or_return
				written = true
			}
			held = ""
			continue
		}
		if held != "" {write_parts(&builder, held) or_return}
		held = ""
		if line.split && line.key == SAVED_FILTERS_KEY && write_library {
			write_parts(&builder, SAVED_FILTERS_KEY, " = \"", value, "\"", line.eol) or_return
			continue
		}
		if strings.has_prefix(line.text, "#") {held = line.raw} else {write_parts(&builder, line.raw) or_return}
	}
	if held != "" {write_parts(&builder, held) or_return}
	updated = strings.clone(strings.to_string(builder), allocator) or_return
	return updated, true, nil
}
