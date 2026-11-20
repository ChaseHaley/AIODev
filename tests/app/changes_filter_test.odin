package app_test

import "aio:ui"
import "core:strings"
import "core:testing"
import app "../../src"

@(private = "file")
PATHS :: [?]string{"src/foo.odin", "src/foo.json", "tests/foo_test.odin", "docs/bar.md", "README.md"}

// The paths the filter `text` shows, space-separated, and what setting it reported.
@(private = "file")
filter_shows :: proc(text: string) -> (shown: string, ok: bool, error: string) {
	f: app.Changes_Filter
	defer app.changes_filter_destroy(&f)
	ok, error = app.changes_filter_set(&f, text)
	b := strings.builder_make(context.temp_allocator)
	for path in PATHS {
		if !app.changes_filter_shows(&f, path) {continue}
		if strings.builder_len(b) > 0 {strings.write_byte(&b, ' ')}
		strings.write_string(&b, path)
	}
	return strings.to_string(b), ok, error
}

@(test)
the_diff_filter_keeps_paths_matching_every_term_and_no_excluded_one :: proc(t: ^testing.T) {
	Case :: struct {
		text, shown: string,
	}
	every := "src/foo.odin src/foo.json tests/foo_test.odin docs/bar.md README.md"
	cases := []Case {
		{"", every},
		{"   ", every},
		{"foo", "src/foo.odin src/foo.json tests/foo_test.odin"},
		{"FOO", "src/foo.odin src/foo.json tests/foo_test.odin"},
		{"foo !.json", "src/foo.odin tests/foo_test.odin"},
		{"!test", "src/foo.odin src/foo.json docs/bar.md README.md"},
		{"src odin", "src/foo.odin"},
		{"bar|readme", "docs/bar.md README.md"},
		{`\.md$ !^docs/`, "README.md"},
		// A lone ! is no term.
		{"! foo", "src/foo.odin src/foo.json tests/foo_test.odin"},
	}
	for c in cases {
		shown, ok, error := filter_shows(c.text)
		testing.expectf(t, ok, "%q is valid", c.text)
		testing.expect_value(t, error, "")
		testing.expectf(t, shown == c.shown, "%q shows %q, not %q", c.text, shown, c.shown)
	}
}

@(test)
an_invalid_diff_filter_hides_nothing_and_names_the_term :: proc(t: ^testing.T) {
	every := "src/foo.odin src/foo.json tests/foo_test.odin docs/bar.md README.md"
	shown, ok, error := filter_shows("foo [")
	testing.expect(t, !ok)
	testing.expect_value(t, error, "Invalid regular expression: [")
	testing.expect_value(t, shown, every)
	shown, ok, error = filter_shows("!(")
	testing.expect(t, !ok)
	testing.expect_value(t, error, "Invalid regular expression: !(")
	testing.expect_value(t, shown, every)

	// A filter set again after a failure works as usual.
	f: app.Changes_Filter
	defer app.changes_filter_destroy(&f)
	_, _ = app.changes_filter_set(&f, "[")
	again, again_error := app.changes_filter_set(&f, "json")
	testing.expect(t, again)
	testing.expect_value(t, again_error, "")
	testing.expect(t, app.changes_filter_shows(&f, "a.json"))
	testing.expect(t, !app.changes_filter_shows(&f, "a.odin"))
}

@(test)
a_renamed_file_matches_the_diff_filter_by_either_path :: proc(t: ^testing.T) {
	Case :: struct {
		text:  string,
		shows: bool,
	}
	cases := []Case {
		{"old_name", true},
		{"new_name", true},
		{"!old_name", false},
		{"!new_name", false},
		// Each plain term may match either path.
		{"old_name new_name", true},
		{"new_name !old_name", false},
		{"other", false},
	}
	for c in cases {
		f: app.Changes_Filter
		ok, _ := app.changes_filter_set(&f, c.text)
		testing.expect(t, ok)
		shows := app.changes_filter_shows(&f, "src/new_name.odin", "src/old_name.odin")
		testing.expectf(t, shows == c.shows, "%q shows the rename: %v", c.text, shows)
		// Without the old path only the new one counts.
		if c.text == "!old_name" {testing.expect(t, app.changes_filter_shows(&f, "src/new_name.odin"))}
		app.changes_filter_destroy(&f)
	}
}

@(private = "file")
LIBRARY :: "#00000001 No vendor | !^vendor/; #00000002 Odin | \\.odin$; #00000003 Bad | [; #00000004 | !docs/"

@(private = "file")
TOKEN_PATHS :: [?]string{"src/a.odin", "vendor/b.odin", "docs/c.md"}

// The paths the filter `text` shows against `library`, space-separated, and its tokens.
@(private = "file")
tokens_show :: proc(
	text: string,
	pending_from := -1,
	pending_to := -1,
	library := LIBRARY,
) -> (
	shown: string,
	ok: bool,
	error: string,
	tokens: [dynamic]ui.Filter_Token,
) {
	f: app.Changes_Filter
	defer app.changes_filter_destroy(&f)
	ok, error = app.changes_filter_set(&f, text, library, &tokens, pending_from, pending_to)
	b := strings.builder_make(context.temp_allocator)
	for path in TOKEN_PATHS {
		if !app.changes_filter_shows(&f, path) {continue}
		if strings.builder_len(b) > 0 {strings.write_byte(&b, ' ')}
		strings.write_string(&b, path)
	}
	return strings.to_string(b), ok, error, tokens
}

@(test)
saved_filter_tokens_add_their_terms_and_combine_with_the_text_and_each_other :: proc(t: ^testing.T) {
	Case :: struct {
		text, shown: string,
	}
	cases := [?]Case {
		{"@00000002", "src/a.odin vendor/b.odin"},
		{"@00000002 @00000001", "src/a.odin"},
		{"~@00000002 @00000001", "src/a.odin docs/c.md"},
		{"@00000001 src", "src/a.odin"},
		{"@00000002 !src", "vendor/b.odin"},
		{"@00000004", "src/a.odin vendor/b.odin"},
		{"@00000004 ~@00000004 @00000002", "src/a.odin vendor/b.odin"},
		{"@Nope", "src/a.odin vendor/b.odin docs/c.md"},
		{"@Odin", "src/a.odin vendor/b.odin docs/c.md"},
		{"~@Nope ~@00000002", "src/a.odin vendor/b.odin docs/c.md"},
	}
	for c in cases {
		shown, ok, error, tokens := tokens_show(c.text)
		defer delete(tokens)
		testing.expect(t, ok, error)
		testing.expect_value(t, shown, c.shown)
	}
}

@(test)
a_token_refers_to_its_filter_by_id_so_a_rename_keeps_it_and_shows_the_new_name :: proc(t: ^testing.T) {
	text := "@00000002 ~@00000001"
	shown, ok, _, tokens := tokens_show(text)
	defer delete(tokens)
	testing.expect(t, ok)
	testing.expect_value(t, shown, "src/a.odin vendor/b.odin")
	if !testing.expect_value(t, len(tokens), 2) {return}
	testing.expect_value(t, tokens[0].name, "Odin")
	testing.expect_value(t, tokens[1].name, "No vendor")

	renamed := "#00000001 Without vendor files | !^vendor/; #00000002 Not like the pattern | \\.odin$; #00000003 Bad | ["
	shown_renamed, ok_renamed, error, renamed_tokens := tokens_show(text, library = renamed)
	defer delete(renamed_tokens)
	testing.expect(t, ok_renamed, error)
	testing.expect_value(t, shown_renamed, shown)
	if !testing.expect_value(t, len(renamed_tokens), 2) {return}
	testing.expect_value(t, renamed_tokens[0].name, "Not like the pattern")
	testing.expect_value(t, renamed_tokens[0].id, "00000002")
	testing.expect_value(t, renamed_tokens[0].state, ui.Filter_Token_State.Known)
	testing.expect_value(t, renamed_tokens[1].name, "Without vendor files")

	edited := "#00000001 No vendor | !^vendor/; #00000002 Odin | \\.odin$ !src; #00000003 Bad | ["
	shown_edited, _, _, edited_tokens := tokens_show("@00000002", library = edited)
	defer delete(edited_tokens)
	testing.expect_value(t, shown_edited, "vendor/b.odin")

	_, _, _, unnamed := tokens_show("@00000004")
	defer delete(unnamed)
	if !testing.expect_value(t, len(unnamed), 1) {return}
	testing.expect_value(t, unnamed[0].name, "!docs/")
}

@(test)
a_token_names_its_filter_by_state_and_an_invalid_saved_pattern_hides_nothing :: proc(t: ^testing.T) {
	shown, ok, error, tokens := tokens_show("@00000002 @00000009 @00000003")
	defer delete(tokens)
	testing.expect(t, !ok)
	testing.expect_value(t, shown, "src/a.odin vendor/b.odin docs/c.md")
	testing.expect(t, strings.contains(error, "saved filter Bad"), error)
	if !testing.expect_value(t, len(tokens), 3) {return}
	testing.expect_value(t, tokens[0].state, ui.Filter_Token_State.Known)
	testing.expect_value(t, tokens[1].state, ui.Filter_Token_State.Unknown)
	testing.expect_value(t, tokens[1].name, "00000009")
	testing.expect_value(t, tokens[2].state, ui.Filter_Token_State.Invalid)
}

@(test)
tokens_keep_their_byte_spans_and_an_at_being_typed_is_neither_a_token_nor_a_term :: proc(t: ^testing.T) {
	text := "ui ~@00000001  @00000002"
	shown, ok, _, tokens := tokens_show(text)
	defer delete(tokens)
	testing.expect(t, ok)
	testing.expect_value(t, shown, "")
	if !testing.expect_value(t, len(tokens), 2) {return}
	testing.expect_value(
		t,
		tokens[0],
		ui.Filter_Token{start = 3, end = 13, id = "00000001", name = "No vendor", off = true},
	)
	testing.expect_value(t, text[tokens[1].start:tokens[1].end], "@00000002")
	testing.expect_value(t, tokens[1].name, "Odin")

	typed, typed_ok, _, pending := tokens_show("@Od", 0, 3)
	defer delete(pending)
	testing.expect(t, typed_ok)
	testing.expect_value(t, len(pending), 0)
	testing.expect_value(t, typed, "src/a.odin vendor/b.odin docs/c.md")
}
