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
	cursor := settings.saved_filters_scan("No vendor | !^vendor/; Docs | \\.(md|txt)$ !changelog")
	first, ok := settings.saved_filters_next(&cursor)
	testing.expect(t, ok)
	testing.expect_value(t, first.name, "No vendor")
	testing.expect_value(t, first.pattern, "!^vendor/")
	second, more := settings.saved_filters_next(&cursor)
	testing.expect(t, more)
	testing.expect_value(t, second.name, "Docs")
	testing.expect_value(t, second.pattern, "\\.(md|txt)$ !changelog")
	_, ended := settings.saved_filters_next(&cursor)
	testing.expect(t, !ended)
	blank := settings.saved_filters_scan("  ")
	_, any := settings.saved_filters_next(&blank)
	testing.expect(t, !any)
}

@(test)
saved_filters_find_ignores_case :: proc(t: ^testing.T) {
	value := "No vendor | !^vendor/; Odin | \\.odin$"
	filter, index, found := settings.saved_filters_find(value, "odin")
	testing.expect(t, found)
	testing.expect_value(t, index, 1)
	testing.expect_value(t, filter.pattern, "\\.odin$")
	_, _, missing := settings.saved_filters_find(value, "Docs")
	testing.expect(t, !missing)
}

@(test)
saved_filters_text_round_trips_and_names_the_first_problem :: proc(t: ^testing.T) {
	drafts := [?]settings.Saved_Filter_Draft{{" No vendor ", " !^vendor/ "}, {"Docs", "\\.md$"}}
	text, problem, err := settings.saved_filters_text(drafts[:], context.temp_allocator)
	testing.expect_value(t, err, nil)
	_, has_problem := problem.?
	testing.expect(t, !has_problem)
	testing.expect_value(t, text, "No vendor | !^vendor/; Docs | \\.md$")

	Case :: struct {
		drafts:  []settings.Saved_Filter_Draft,
		problem: settings.Saved_Filter_Problem,
	}
	cases := [?]Case {
		{{{"", "x"}}, .Name},
		{{{"a;b", "x"}}, .Name},
		{{{"a|b", "x"}}, .Name},
		{{{"say \"hi\"", "x"}}, .Name},
		{{{"Docs", "\\.md$"}, {"docs", "x"}}, .Duplicate},
		{{{"Docs", ""}}, .Pattern},
		{{{"Docs", "a;b"}}, .Pattern},
	}
	for c in cases {
		_, got, _ := settings.saved_filters_text(c.drafts, context.temp_allocator)
		value, refused := got.?
		testing.expect(t, refused)
		testing.expect_value(t, value, c.problem)
	}
}

@(test)
saved_filters_setting_defaults_to_none_and_refuses_malformed_values :: proc(t: ^testing.T) {
	value, issues := saved_filters_parse(t, "")
	testing.expect_value(t, value, "")
	testing.expect_value(t, issues, 0)
	value, issues = saved_filters_parse(t, "No vendor | !^vendor/; Odin | \\.odin$")
	testing.expect_value(t, value, "No vendor | !^vendor/; Odin | \\.odin$")
	testing.expect_value(t, issues, 0)
	for bad in ([?]string{"no pattern", "Odin | ", "A | x; a | y", "A | x;", "| x"}) {
		value, issues = saved_filters_parse(t, bad)
		testing.expect_value(t, value, "")
		testing.expect_value(t, issues, 1)
	}
}

@(test)
filter_words_find_tokens_and_leave_the_rest_plain :: proc(t: ^testing.T) {
	text := `~@"No vendor" @Odin ui !json  @"half @ "a b"c @`
	Expected :: struct {
		text:        string,
		token, off:  bool,
		name:        string,
	}
	expected := [?]Expected {
		{`~@"No vendor"`, true, true, "No vendor"},
		{"@Odin", true, false, "Odin"},
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
filter_token_format_quotes_only_names_with_spaces_and_parses_back :: proc(t: ^testing.T) {
	buffer: [64]u8
	Case :: struct {
		name: string,
		off:  bool,
		text: string,
	}
	cases := [?]Case{{"Odin", false, "@Odin"}, {"Odin", true, "~@Odin"}, {"No vendor", false, `@"No vendor"`}, {"No vendor", true, `~@"No vendor"`}}
	for c in cases {
		text := settings.filter_token_format(buffer[:], c.name, c.off)
		testing.expect_value(t, text, c.text)
		word, ok := settings.filter_word_next(text, 0)
		testing.expect(t, ok && word.token)
		testing.expect_value(t, word.name, c.name)
		testing.expect_value(t, word.off, c.off)
		testing.expect_value(t, word.end, len(text))
	}
}
