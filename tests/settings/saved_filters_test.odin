package settings_test

import "aio:settings"
import "core:fmt"
import "core:strings"
import "core:testing"

@(private)
saved_filters_parse :: proc(t: ^testing.T, value: string) -> (filters: string, diagnostics: int) {
	s, issues, err := settings.parse(fmt.tprintf("%s = %s", settings.SAVED_FILTERS_KEY, value))
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&issues)
	testing.expect_value(t, err, nil)
	return strings.clone(s.turns.saved_filters, context.temp_allocator), len(issues)
}

@(test)
saved_filters_cursor_yields_entries_in_order_and_a_pattern_keeps_its_bars :: proc(t: ^testing.T) {
	cursor := settings.saved_filters_scan("| !^vendor/; Docs | \\.(md|txt)$ !changelog")
	first, ok := settings.saved_filters_next(&cursor)
	testing.expect(t, ok)
	testing.expect_value(t, first.name, "")
	testing.expect_value(t, first.pattern, "!^vendor/")
	testing.expect_value(t, settings.saved_filter_label(first), "!^vendor/")
	second, more := settings.saved_filters_next(&cursor)
	testing.expect(t, more)
	testing.expect_value(t, second.name, "Docs")
	testing.expect_value(t, second.pattern, "\\.(md|txt)$ !changelog")
	testing.expect_value(t, settings.saved_filter_label(second), "Docs")
	_, ended := settings.saved_filters_next(&cursor)
	testing.expect(t, !ended)
	blank := settings.saved_filters_scan("  ")
	_, any := settings.saved_filters_next(&blank)
	testing.expect(t, !any)
}

@(test)
saved_filters_are_found_by_label_or_pattern_ignoring_case_in_the_label :: proc(t: ^testing.T) {
	value := "| !^vendor/; Odin | \\.odin$"
	filter, index, found := settings.saved_filters_find(value, "odin")
	testing.expect(t, found)
	testing.expect_value(t, index, 1)
	testing.expect_value(t, filter.pattern, "\\.odin$")
	filter, index, found = settings.saved_filters_find(value, "!^VENDOR/")
	testing.expect(t, found)
	testing.expect_value(t, index, 0)
	_, _, missing := settings.saved_filters_find(value, "Docs")
	testing.expect(t, !missing)
	_, at, by_pattern := settings.saved_filters_find_pattern(value, "\\.odin$")
	testing.expect(t, by_pattern)
	testing.expect_value(t, at, 1)
	_, _, none := settings.saved_filters_find_pattern(value, "odin")
	testing.expect(t, !none)
}

@(test)
saved_filters_text_round_trips_and_names_the_first_problem :: proc(t: ^testing.T) {
	drafts := [?]settings.Saved_Filter_Draft{
		{" ", " !^vendor/ ", true},
		{"Docs", "\\.md$", false},
		{"", "a|b c", true},
	}
	text, problem, err := settings.saved_filters_text(drafts[:], context.temp_allocator)
	testing.expect_value(t, err, nil)
	_, has_problem := problem.?
	testing.expect(t, !has_problem)
	testing.expect_value(t, text, "* | !^vendor/; Docs | \\.md$; * | a|b c")
	cursor := settings.saved_filters_scan(text)
	index := 0
	for filter in settings.saved_filters_next(&cursor) {
		testing.expect_value(t, filter.name, strings.trim_space(drafts[index].name))
		testing.expect_value(t, filter.pattern, strings.trim_space(drafts[index].pattern))
		index += 1
	}
	testing.expect_value(t, index, 3)
	cursor = settings.saved_filters_scan(text)
	defaults := [3]bool{true, false, true}
	index = 0
	for filter in settings.saved_filters_next(&cursor) {
		testing.expect_value(t, filter.default, defaults[index])
		index += 1
	}

	Case :: struct {
		drafts:  []settings.Saved_Filter_Draft,
		problem: settings.Saved_Filter_Problem,
	}
	cases := [?]Case {
		{{{"a;b", "x", false}}, .Name},
		{{{"a|b", "x", false}}, .Name},
		{{{"say \"hi\"", "x", false}}, .Name},
		{{{"Docs", "\\.md$", false}, {"docs", "x", false}}, .Duplicate},
		{{{"", "x", false}, {"X", "y", false}}, .Duplicate},
		{{{"x", "a", false}, {"", "x", false}}, .Duplicate},
		{{{"", "x", false}, {"", "x", false}}, .Duplicate},
		{{{"Docs", "", false}}, .Pattern},
		{{{"Docs", "a;b", false}}, .Pattern},
		{{{"", "a\"b", false}}, .Pattern},
		{{{"*x", "y", false}}, .Name},
	}
	for c in cases {
		_, got, _ := settings.saved_filters_text(c.drafts, context.temp_allocator)
		value, refused := got.?
		testing.expect(t, refused)
		testing.expect_value(t, value, c.problem)
	}
	long := strings.repeat("a", settings.SAVED_FILTER_PATTERN_MAX + 1, context.temp_allocator)
	_, got, _ := settings.saved_filters_text([]settings.Saved_Filter_Draft{{"", long, false}}, context.temp_allocator)
	value, refused := got.?
	testing.expect(t, refused)
	testing.expect_value(t, value, settings.Saved_Filter_Problem.Pattern)
}

@(test)
saved_filters_setting_defaults_to_none_and_refuses_malformed_values :: proc(t: ^testing.T) {
	value, issues := saved_filters_parse(t, "")
	testing.expect_value(t, value, "")
	testing.expect_value(t, issues, 0)
	value, issues = saved_filters_parse(t, "| !^vendor/; Odin | \\.odin$")
	testing.expect_value(t, value, "| !^vendor/; Odin | \\.odin$")
	testing.expect_value(t, issues, 0)
	for bad in ([?]string{"no pattern", "Odin | ", "A | x; a | y", "| x; X | y", "A | x;"}) {
		value, issues = saved_filters_parse(t, bad)
		testing.expect_value(t, value, "")
		testing.expect_value(t, issues, 1)
	}
}

@(test)
filter_words_find_tokens_and_leave_the_rest_plain :: proc(t: ^testing.T) {
	text := `~@"!tests/ !_test" @\.odin$ ui !json  @"half @ "a b"c @`
	Expected :: struct {
		text:       string,
		token, off: bool,
		name:       string,
	}
	expected := [?]Expected {
		{`~@"!tests/ !_test"`, true, true, "!tests/ !_test"},
		{`@\.odin$`, true, false, "\\.odin$"},
		{"ui", false, false, ""},
		{"!json", false, false, ""},
		{`@"half`, false, false, ""},
		{"@", false, false, ""},
		{`"a`, false, false, ""},
		{`b"c`, false, false, ""},
		{"@", false, false, ""},
	}
	at, index := 0, 0
	for {
		word, ok := settings.filter_word_next(text, at)
		if !ok {break}
		if !testing.expect(t, index < len(expected), "more words than expected") {return}
		testing.expect_value(t, text[word.start:word.end], expected[index].text)
		testing.expect_value(t, word.token, expected[index].token)
		testing.expect_value(t, word.off, expected[index].off)
		testing.expect_value(t, word.name, expected[index].name)
		at, index = word.end, index + 1
	}
	testing.expect_value(t, index, len(expected))
}

@(test)
filter_token_format_quotes_only_labels_with_spaces_and_parses_back :: proc(t: ^testing.T) {
	buffer: [160]u8
	Case :: struct {
		label: string,
		off:   bool,
		text:  string,
	}
	cases := [?]Case {
		{"Odin", false, "@Odin"},
		{"Odin", true, "~@Odin"},
		{"!^vendor/", false, "@!^vendor/"},
		{"\\.(md|txt)$", true, "~@\\.(md|txt)$"},
		{"!tests/ !_test", false, `@"!tests/ !_test"`},
		{"No vendor", true, `~@"No vendor"`},
	}
	for c in cases {
		text := settings.filter_token_format(buffer[:], c.label, c.off)
		testing.expect_value(t, text, c.text)
		word, ok := settings.filter_word_next(text, 0)
		testing.expect(t, ok && word.token)
		testing.expect_value(t, word.name, c.label)
		testing.expect_value(t, word.off, c.off)
		testing.expect_value(t, word.end, len(text))
	}
}

@(test)
new_panes_start_with_every_default_filter_as_an_on_token_in_order :: proc(t: ^testing.T) {
	text, err := settings.saved_filters_default_text(
		"* | !^vendor/; Odin | \\.odin$; * Source | src/ !_test; * Two words | a",
		context.temp_allocator,
	)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, text, `@!^vendor/ @Source @"Two words"`)
	none, _ := settings.saved_filters_default_text("Odin | b", context.temp_allocator)
	testing.expect_value(t, none, "")
	nothing, _ := settings.saved_filters_default_text("", context.temp_allocator)
	testing.expect_value(t, nothing, "")
}
