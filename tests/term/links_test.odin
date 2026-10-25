package term_test

import "core:fmt"
import "core:strings"
import "core:testing"
import "aio:ghostty"
import "aio:term"

Link_Source :: struct {
	terminal: ghostty.Terminal,
	columns:  int,
	rows:     int,
}

link_source :: proc(
	t: ^testing.T,
	text: string,
	columns, rows: int,
) -> (
	Link_Source,
	bool,
) {
	source := Link_Source{columns = columns, rows = rows}
	if !testing.expect_value(
		t,
		ghostty.terminal_new(nil, &source.terminal, u16(columns), u16(rows)),
		ghostty.Result.Success,
	) {
		return {}, false
	}
	ghostty.terminal_vt_write(source.terminal, raw_data(text), uint(len(text)))
	return source, true
}

link_source_destroy :: proc(source: ^Link_Source) {
	ghostty.terminal_free(source.terminal)
	source^ = {}
}

link_map :: proc(t: ^testing.T, source: Link_Source) -> (term.Link_Map, bool) {
	m: term.Link_Map
	if !testing.expect(t, term.link_map_create(&m)) {
		return {}, false
	}
	if !testing.expect(
		t,
		term.link_map_scan_terminal(&m, source.terminal, source.columns, source.rows),
	) {
		term.link_map_destroy(&m)
		return {}, false
	}
	return m, true
}

@(test)
osc8_links_are_read_and_scheme_filtered :: proc(t: ^testing.T) {
	source, ok := link_source(
		t,
		"\x1b]8;;https://example.com/a\x1b\\LINK\x1b]8;;\x1b\\" +
		"\x1b[2;1H\x1b]8;;file:///C:/Windows\x1b\\BAD\x1b]8;;\x1b\\" +
		"\x1b[3;1H\x1b]8;;http://second.example\x1b\\OK\x1b]8;;\x1b\\",
		24,
		3,
	)
	if !ok {return}
	defer link_source_destroy(&source)
	m, scanned := link_map(t, source)
	if !scanned {return}
	defer term.link_map_destroy(&m)
	range, uri, found := term.link_at(&m, 0, 0)
	testing.expect(t, found)
	testing.expect_value(t, uri, "https://example.com/a")
	testing.expect_value(t, range, term.Link_Range{0, 0, 0, 3})
	_, _, beyond := term.link_at(&m, 4, 0)
	testing.expect(t, !beyond)
	_, _, refused := term.link_at(&m, 0, 1)
	testing.expect(t, !refused, "a file: OSC 8 target must stay inert")
	_, http_uri, http_found := term.link_at(&m, 0, 2)
	testing.expect(t, http_found)
	testing.expect_value(t, http_uri, "http://second.example")
	testing.expect_value(t, len(m.spans), 2)
}

@(test)
osc8_takes_precedence_over_detected_urls :: proc(t: ^testing.T) {
	source, ok := link_source(
		t,
		"\x1b]8;;https://osc.example\x1b\\https://plain.example\x1b]8;;\x1b\\",
		40,
		2,
	)
	if !ok {return}
	defer link_source_destroy(&source)
	m, scanned := link_map(t, source)
	if !scanned {return}
	defer term.link_map_destroy(&m)
	_, uri, found := term.link_at(&m, 0, 0)
	testing.expect(t, found)
	testing.expect_value(t, uri, "https://osc.example")
	testing.expect_value(t, len(m.spans), 1)

	blocked, blocked_ok := link_source(
		t,
		"\x1b]8;;file:///C:/x\x1b\\https://\x1b]8;;\x1b\\plain.example",
		40,
		2,
	)
	if !blocked_ok {return}
	defer link_source_destroy(&blocked)
	blocked_map, blocked_scanned := link_map(t, blocked)
	if !blocked_scanned {return}
	defer term.link_map_destroy(&blocked_map)
	testing.expect_value(t, len(blocked_map.spans), 0)
}

@(test)
plain_urls_join_soft_wraps_and_trim_prose :: proc(t: ^testing.T) {
	source, ok := link_source(t, "see https://example.com/abcd, done", 24, 3)
	if !ok {return}
	defer link_source_destroy(&source)
	m, scanned := link_map(t, source)
	if !scanned {return}
	defer term.link_map_destroy(&m)
	range, uri, found := term.link_at(&m, 4, 0)
	testing.expect(t, found)
	testing.expect_value(t, uri, "https://example.com/abcd")
	testing.expect_value(t, range, term.Link_Range{0, 1, 4, 3})
	_, tail_uri, tail_found := term.link_at(&m, 0, 1)
	testing.expect(t, tail_found)
	testing.expect_value(t, tail_uri, "https://example.com/abcd")
	_, _, punctuation := term.link_at(&m, 5, 1)
	testing.expect(t, !punctuation)
}

@(test)
hard_line_break_ends_a_target :: proc(t: ^testing.T) {
	source, ok := link_source(t, "https://example.com/very\r\nlong", 40, 2)
	if !ok {return}
	defer link_source_destroy(&source)
	m, scanned := link_map(t, source)
	if !scanned {return}
	defer term.link_map_destroy(&m)
	_, uri, found := term.link_at(&m, 0, 0)
	testing.expect(t, found)
	testing.expect_value(t, uri, "https://example.com/very")
	_, _, continuation := term.link_at(&m, 0, 1)
	testing.expect(t, !continuation, "a hard break splits one URL into two texts")
}

@(test)
osc8_link_wraps_as_one_range :: proc(t: ^testing.T) {
	text :=
		"\x1b]8;;https://example.com/wrap\x1b\\" +
		"xxxxxxxxxxxxxxxxxxxx" +
		"\x1b]8;;\x1b\\"
	source, ok := link_source(t, text, 12, 3)
	if !ok {return}
	defer link_source_destroy(&source)
	m, scanned := link_map(t, source)
	if !scanned {return}
	defer term.link_map_destroy(&m)
	range, uri, found := term.link_at(&m, 0, 0)
	testing.expect(t, found)
	testing.expect_value(t, uri, "https://example.com/wrap")
	testing.expect_value(t, range, term.Link_Range{0, 1, 0, 7})
	_, tail_uri, tail_found := term.link_at(&m, 7, 1)
	testing.expect(t, tail_found)
	testing.expect_value(t, tail_uri, "https://example.com/wrap")
	testing.expect_value(t, len(m.spans), 1)
}

@(test)
a_url_starting_above_the_viewport_is_clickable_where_drawn :: proc(t: ^testing.T) {
	text := "https://example.com/" + "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	source, ok := link_source(t, text, 20, 3)
	if !ok {return}
	defer link_source_destroy(&source)
	m, scanned := link_map(t, source)
	if !scanned {return}
	defer term.link_map_destroy(&m)
	_, uri, found := term.link_at(&m, 0, 0)
	testing.expect(t, found, "the visible tail of a URL above the viewport is still a target")
	testing.expect_value(t, uri, text)
}

@(test)
a_url_running_below_the_viewport_keeps_its_full_target :: proc(t: ^testing.T) {
	text := strings.builder_make()
	defer strings.builder_destroy(&text)
	for line in 0 ..< 8 {
		fmt.sbprintf(&text, "line%d\r\n", line)
	}
	fmt.sbprint(&text, "https://example.com/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
	fmt.sbprint(&text, "\r\ntail")
	source, ok := link_source(t, strings.to_string(text), 20, 3)
	if !ok {return}
	defer link_source_destroy(&source)
	ghostty.terminal_scroll_viewport(source.terminal, {tag = .Delta, value = {delta = -3}})
	m, scanned := link_map(t, source)
	if !scanned {return}
	defer term.link_map_destroy(&m)
	_, uri, found := term.link_at(&m, 0, 2)
	testing.expect(t, found, "the visible start of a URL continuing below is a target")
	testing.expect_value(t, uri, "https://example.com/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
}

@(test)
hover_hit_testing_follows_scrollback :: proc(t: ^testing.T) {
	text := strings.builder_make()
	defer strings.builder_destroy(&text)
	for line in 0 ..< 12 {
		if line == 8 {
			fmt.sbprintf(&text, "https://example.com/tail")
		} else {
			fmt.sbprintf(&text, "line%d", line)
		}
		if line != 11 {
			fmt.sbprint(&text, "\r\n")
		}
	}
	source, ok := link_source(t, strings.to_string(text), 40, 6)
	if !ok {return}
	defer link_source_destroy(&source)
	ghostty.terminal_scroll_viewport(source.terminal, {tag = .Delta, value = {delta = -3}})
	m, scanned := link_map(t, source)
	if !scanned {return}
	defer term.link_map_destroy(&m)
	_, uri, found := term.link_at(&m, 0, 5)
	testing.expect(t, found, "the URL row moved to viewport row 5 after scrolling")
	testing.expect_value(t, uri, "https://example.com/tail")
	_, _, other := term.link_at(&m, 0, 4)
	testing.expect(t, !other)
}
