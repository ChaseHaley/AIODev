package line_match_test

import "aio:line_match"
import "aio:search"
import "core:testing"

@(private)
Found :: struct {
	first, end: int,
	ok:         bool,
}

@(private)
first_match :: proc(m: ^line_match.Matcher, line: string) -> Found {
	line_match.begin(m, line)
	first, end, ok := line_match.next(m)
	return {first, end, ok}
}

// One matcher serves every line of a search, so a line without a match must not stop the lines after it.
@(test)
regex_keeps_matching_after_a_line_without_a_match :: proc(t: ^testing.T) {
	m: line_match.Matcher
	testing.expect_value(t, line_match.init(&m, "bar|readme", {regex = true}), line_match.Init_Result.Ok)
	defer line_match.destroy(&m)
	testing.expect_value(t, first_match(&m, "docs/bar.md"), Found{5, 8, true})
	testing.expect_value(t, first_match(&m, "src/foo.json"), Found{})
	testing.expect_value(t, first_match(&m, "README.md"), Found{0, 6, true})
	testing.expect_value(t, first_match(&m, "nothing here"), Found{})
	testing.expect_value(t, first_match(&m, "x/readme"), Found{2, 8, true})
}

@(test)
regex_finds_every_match_in_a_line_after_a_miss :: proc(t: ^testing.T) {
	m: line_match.Matcher
	testing.expect_value(t, line_match.init(&m, `a\d`, {regex = true}), line_match.Init_Result.Ok)
	defer line_match.destroy(&m)
	testing.expect_value(t, first_match(&m, "zzz"), Found{})
	line_match.begin(&m, "a1 b a2 a3")
	expected := [?]Found{{0, 2, true}, {5, 7, true}, {8, 10, true}, {}}
	for want in expected {
		first, end, ok := line_match.next(&m)
		testing.expect_value(t, Found{first, end, ok}, want)
	}
}

@(test)
literal_search_is_unchanged :: proc(t: ^testing.T) {
	m: line_match.Matcher
	testing.expect_value(t, line_match.init(&m, "Json", search.Options{}), line_match.Init_Result.Ok)
	defer line_match.destroy(&m)
	testing.expect_value(t, first_match(&m, "a.md"), Found{})
	testing.expect_value(t, first_match(&m, "src/foo.JSON"), Found{8, 12, true})
}
