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
	cursor := settings.saved_filters_scan("#00000001 | !^vendor/; #00000002 * Docs | \\.(md|txt)$ !changelog")
	first, ok := settings.saved_filters_next(&cursor)
	testing.expect(t, ok)
	testing.expect_value(t, first.id, "00000001")
	testing.expect_value(t, first.default, false)
	testing.expect_value(t, first.name, "")
	testing.expect_value(t, first.pattern, "!^vendor/")
	testing.expect_value(t, settings.saved_filter_label(first), "!^vendor/")
	second, more := settings.saved_filters_next(&cursor)
	testing.expect(t, more)
	testing.expect_value(t, second.id, "00000002")
	testing.expect_value(t, second.default, true)
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
saved_filters_are_found_by_id_label_or_pattern_ignoring_case_in_the_label :: proc(t: ^testing.T) {
	value := "#00000001 | !^vendor/; #00000002 Odin | \\.odin$"
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
	filter, index, found = settings.saved_filters_find_id(value, "00000002")
	testing.expect(t, found)
	testing.expect_value(t, index, 1)
	testing.expect_value(t, filter.name, "Odin")
	_, _, unknown := settings.saved_filters_find_id(value, "Odin")
	testing.expect(t, !unknown)
}

@(test)
saved_filters_text_round_trips_and_names_the_first_problem :: proc(t: ^testing.T) {
	drafts := [?]settings.Saved_Filter_Draft {
		{"00000001", " ", " !^vendor/ ", true},
		{"0a0b0c0d", "Docs", "\\.md$", false},
		{"ffffffff", "", "a|b c", true},
	}
	text, problem, err := settings.saved_filters_text(drafts[:], context.temp_allocator)
	testing.expect_value(t, err, nil)
	_, has_problem := problem.?
	testing.expect(t, !has_problem)
	testing.expect_value(t, text, "#00000001 * | !^vendor/; #0a0b0c0d Docs | \\.md$; #ffffffff * | a|b c")
	cursor := settings.saved_filters_scan(text)
	index := 0
	defaults := [3]bool{true, false, true}
	for filter in settings.saved_filters_next(&cursor) {
		testing.expect_value(t, filter.id, drafts[index].id)
		testing.expect_value(t, filter.name, strings.trim_space(drafts[index].name))
		testing.expect_value(t, filter.pattern, strings.trim_space(drafts[index].pattern))
		testing.expect_value(t, filter.default, defaults[index])
		index += 1
	}
	testing.expect_value(t, index, 3)

	Case :: struct {
		drafts:  []settings.Saved_Filter_Draft,
		problem: settings.Saved_Filter_Problem,
	}
	cases := [?]Case {
		{{{"00000001", "a;b", "x", false}}, .Name},
		{{{"00000001", "a|b", "x", false}}, .Name},
		{{{"00000001", "say \"hi\"", "x", false}}, .Name},
		{{{"00000001", "*x", "y", false}}, .Name},
		{{{"00000001", "#x", "y", false}}, .Name},
		{{{"00000001", "Docs", "\\.md$", false}, {"00000002", "docs", "x", false}}, .Duplicate},
		{{{"00000001", "", "x", false}, {"00000002", "X", "y", false}}, .Duplicate},
		{{{"00000001", "x", "a", false}, {"00000002", "", "x", false}}, .Duplicate},
		{{{"00000001", "", "x", false}, {"00000002", "", "x", false}}, .Duplicate},
		{{{"00000001", "Docs", "", false}}, .Pattern},
		{{{"00000001", "Docs", "a;b", false}}, .Pattern},
		{{{"00000001", "", "a\"b", false}}, .Pattern},
		{{{"", "Docs", "x", false}}, .Id},
		{{{"0000000", "Docs", "x", false}}, .Id},
		{{{"0000000G", "Docs", "x", false}}, .Id},
		{{{"0000000A", "Docs", "x", false}}, .Id},
		{{{"00000001", "Docs", "x", false}, {"00000001", "More", "y", false}}, .Id},
	}
	for c in cases {
		_, got, _ := settings.saved_filters_text(c.drafts, context.temp_allocator)
		value, refused := got.?
		testing.expect(t, refused)
		testing.expect_value(t, value, c.problem)
	}
	long := strings.repeat("a", settings.SAVED_FILTER_PATTERN_MAX + 1, context.temp_allocator)
	_, got, _ := settings.saved_filters_text(
		[]settings.Saved_Filter_Draft{{"00000001", "", long, false}},
		context.temp_allocator,
	)
	value, refused := got.?
	testing.expect(t, refused)
	testing.expect_value(t, value, settings.Saved_Filter_Problem.Pattern)
}

@(test)
a_filters_id_is_stable_through_rename_edit_and_reorder_and_new_ids_are_unique :: proc(t: ^testing.T) {
	library := "#00000001 Odin | \\.odin$; #00000002 * Docs | \\.md$; #00000003 | src/"
	edited := [?]settings.Saved_Filter_Draft {
		{"00000003", "Source", "src/ !_test", false},
		{"00000001", "Odin files", "\\.odin$", true},
		{"00000002", "Docs", "\\.md$", true},
	}
	text, problem, _ := settings.saved_filters_text(edited[:], context.temp_allocator)
	_, refused := problem.?
	testing.expect(t, !refused)
	Renamed :: struct {
		id, label: string,
	}
	for expected in ([?]Renamed{{"00000001", "Odin files"}, {"00000002", "Docs"}, {"00000003", "Source"}}) {
		filter, _, found := settings.saved_filters_find_id(text, expected.id)
		testing.expect(t, found)
		testing.expect_value(t, settings.saved_filter_label(filter), expected.label)
	}
	_, at, _ := settings.saved_filters_find_id(text, "00000003")
	testing.expect_value(t, at, 0)
	_, before, _ := settings.saved_filters_find_id(library, "00000003")
	testing.expect_value(t, before, 2)

	seen := make(map[string]bool, 256, context.temp_allocator)
	taken := edited[:]
	for _ in 0 ..< 200 {
		id := settings.saved_filter_id_make(taken)
		testing.expectf(t, settings.saved_filter_id_valid(id), "%q is not an id", id)
		testing.expectf(t, !(id in seen), "%q made twice", id)
		for filter in taken {testing.expect(t, filter.id != id)}
		seen[id] = true
	}
}

@(test)
saved_filters_setting_defaults_to_none_and_refuses_malformed_values :: proc(t: ^testing.T) {
	value, issues := saved_filters_parse(t, "")
	testing.expect_value(t, value, "")
	testing.expect_value(t, issues, 0)
	good := "#00000001 | !^vendor/; #00000002 Odin | \\.odin$"
	value, issues = saved_filters_parse(t, good)
	testing.expect_value(t, value, good)
	testing.expect_value(t, issues, 0)
	bad_values := [?]string {
		"no pattern",
		"#00000001 Odin | ",
		"#00000001 A | x; #00000002 a | y",
		"#00000001 | x; #00000002 X | y",
		"#00000001 A | x;",
		"Odin | x",
		"#00000001 A | x; #00000001 B | y",
		"#0000001 A | x",
		"#0000000g A | x",
		"#00000001",
	}
	for bad in bad_values {
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
		{"4f9c2a1b", false, "@4f9c2a1b"},
		{"4f9c2a1b", true, "~@4f9c2a1b"},
		{"Odin", false, "@Odin"},
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
new_panes_start_with_every_default_filter_as_an_on_token_by_id_in_order :: proc(t: ^testing.T) {
	text, err := settings.saved_filters_default_text(
		"#00000001 * | !^vendor/; #00000002 Odin | \\.odin$; #00000003 * Source | src/ !_test; #00000004 * Two words | a",
		context.temp_allocator,
	)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, text, "@00000001 @00000003 @00000004")
	none, _ := settings.saved_filters_default_text("#00000001 Odin | b", context.temp_allocator)
	testing.expect_value(t, none, "")
	nothing, _ := settings.saved_filters_default_text("", context.temp_allocator)
	testing.expect_value(t, nothing, "")
}

@(test)
text_from_before_ids_names_filters_by_id_and_drops_those_that_are_gone :: proc(t: ^testing.T) {
	library := "#00000001 Odin | \\.odin$; #00000002 No vendor | !^vendor/; #00000003 | src/"
	Case :: struct {
		text, expected: string,
	}
	cases := [?]Case {
		{"@Odin", "@00000001"},
		{"~@odin", "~@00000001"},
		{ `@"No vendor" ui @Gone !json`, "@00000002 ui !json"},
		{"@00000003  @00000001", "@00000003 @00000001"},
		{"@00000009 @src/", "@00000003"},
		{"~@00000002", "~@00000002"},
		{"@\"unclosed @", "@\"unclosed @"},
		{"", ""},
	}
	for c in cases {
		got, err := settings.filter_text_ids(library, c.text, context.temp_allocator)
		testing.expect_value(t, err, nil)
		testing.expect_value(t, got, c.expected)
	}
}

@(test)
the_diagnostic_for_a_malformed_value_shows_the_whole_grammar_and_its_example :: proc(t: ^testing.T) {
	s, issues, err := settings.parse(fmt.tprintf("%s = Odin | x", settings.SAVED_FILTERS_KEY))
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&issues)
	testing.expect_value(t, err, nil)
	if !testing.expect_value(t, len(issues), 1) {return}
	testing.expect(t, strings.contains(issues[0].message, "#id name | pattern"), issues[0].message)
	testing.expect(t, strings.has_suffix(issues[0].message, settings.SAVED_FILTERS_EXAMPLE + "."), issues[0].message)
}
