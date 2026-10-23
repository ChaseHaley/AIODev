package settings_test

import "core:fmt"
import "core:strings"
import "core:testing"
import "aio:settings"

@(test)
line_scanner_reports_raw_lines_bom_and_eol :: proc(t: ^testing.T) {
	text := "\xef\xbb\xbf# keep\r\nfont.size = 12\r\n\r\nshell.command =\r\nlast"
	scanner := settings.line_scanner_init(text)
	testing.expect_value(t, scanner.bom, true)
	testing.expect_value(t, scanner.eol, "\r\n")

	first, first_ok := settings.line_next(&scanner)
	if !testing.expect(t, first_ok) {return}
	testing.expect_value(t, first.number, 1)
	testing.expect_value(t, first.raw, "# keep\r\n")
	testing.expect_value(t, first.text, "# keep")
	testing.expect_value(t, first.eol, "\r\n")
	testing.expect_value(t, first.split, false)

	second, second_ok := settings.line_next(&scanner)
	if !testing.expect(t, second_ok) {return}
	testing.expect_value(t, second.number, 2)
	testing.expect_value(t, second.key, "font.size")
	testing.expect_value(t, second.value, "12")
	testing.expect_value(t, second.eol, "\r\n")
	testing.expect_value(t, second.split, true)

	blank, blank_ok := settings.line_next(&scanner)
	if !testing.expect(t, blank_ok) {return}
	testing.expect_value(t, blank.number, 3)
	testing.expect_value(t, blank.raw, "\r\n")
	testing.expect_value(t, blank.text, "")
	testing.expect_value(t, blank.eol, "\r\n")

	empty, empty_ok := settings.line_next(&scanner)
	if !testing.expect(t, empty_ok) {return}
	testing.expect_value(t, empty.number, 4)
	testing.expect_value(t, empty.key, "shell.command")
	testing.expect_value(t, empty.value, "")
	testing.expect_value(t, empty.split, true)

	last, last_ok := settings.line_next(&scanner)
	if !testing.expect(t, last_ok) {return}
	testing.expect_value(t, last.number, 5)
	testing.expect_value(t, last.raw, "last")
	testing.expect_value(t, last.text, "last")
	testing.expect_value(t, last.eol, "")
	_, end_ok := settings.line_next(&scanner)
	testing.expect_value(t, end_ok, false)
}

@(test)
line_scanner_uses_lf_without_bom :: proc(t: ^testing.T) {
	scanner := settings.line_scanner_init("a = 1\nb")
	testing.expect_value(t, scanner.bom, false)
	testing.expect_value(t, scanner.eol, "\n")
	first, first_ok := settings.line_next(&scanner)
	if !testing.expect(t, first_ok) {return}
	testing.expect_value(t, first.raw, "a = 1\n")
	testing.expect_value(t, first.eol, "\n")
	second, second_ok := settings.line_next(&scanner)
	if !testing.expect(t, second_ok) {return}
	testing.expect_value(t, second.raw, "b")
	testing.expect_value(t, second.eol, "")
	testing.expect_value(t, second.key, "")
	testing.expect_value(t, second.split, false)
}

@(test)
grammar_reads_comments_empty_values_and_quoted_strings :: proc(t: ^testing.T) {
	text := "# font.size = 10\ncolors.selection_foreground =\nfont.family = \"  Mono  \"\n"
	scanner := settings.line_scanner_init(text)
	comment, comment_ok := settings.line_next(&scanner)
	if !testing.expect(t, comment_ok) {return}
	testing.expect_value(t, comment.text, "# font.size = 10")
	testing.expect_value(t, comment.key, "# font.size")
	testing.expect_value(t, comment.split, true)
	empty, empty_ok := settings.line_next(&scanner)
	if !testing.expect(t, empty_ok) {return}
	testing.expect_value(t, empty.key, "colors.selection_foreground")
	testing.expect_value(t, empty.value, "")
	testing.expect_value(t, empty.split, true)
	quoted, quoted_ok := settings.line_next(&scanner)
	if !testing.expect(t, quoted_ok) {return}
	testing.expect_value(t, quoted.key, "font.family")
	testing.expect_value(t, quoted.value, "\"  Mono  \"")

	parsed, diagnostics, parse_error := settings.parse(text)
	defer settings.destroy(&parsed)
	defer settings.diagnostics_destroy(&diagnostics)
	testing.expect_value(t, parse_error, nil)
	testing.expect_value(t, len(diagnostics), 0)
	testing.expect_value(t, parsed.font.size, 12)
	testing.expect_value(t, parsed.font.family, "  Mono  ")
	testing.expect_value(t, parsed.colors.selection_foreground, nil)
}

@(test)
value_encoder_covers_every_schema_kind :: proc(t: ^testing.T) {
	Cases :: struct {
		key, value, expected: string,
	}
	cases := [?]Cases{
		{"font.family", "  Mono  ", "\"  Mono  \""},
		{"font.family", "", "\"\""},
		{"pane.gap", "5", "5"},
		{"font.size", "12.5", "12.5"},
		{"cursor.blink", "true", "true"},
		{"theme.name", "tide", "tide"},
		{"colors.cursor", "#ABCDEF", "#abcdef"},
		{"colors.foreground", "", ""},
	}
	for c in cases {
		entry := settings.schema_find(c.key)
		if !testing.expect(t, entry != nil) {continue}
		b, build_error := strings.builder_make()
		if !testing.expect_value(t, build_error, nil) {continue}
		encode_error := settings.encode_value(&b, entry^, c.value)
		testing.expect_value(t, encode_error, nil)
		testing.expect_value(t, strings.to_string(b), c.expected)
		strings.builder_destroy(&b)
	}

	b, build_error := strings.builder_make()
	if !testing.expect_value(t, build_error, nil) {return}
	defer strings.builder_destroy(&b)
	color_entry := settings.Schema_Entry{kind = settings.Kind.Color}
	testing.expect_value(t, settings.encode_value(&b, color_entry, "rgb(255, 136, 0)"), nil)
	testing.expect_value(t, strings.to_string(b), "#ff8800")
}

@(test)
default_text_quotes_string_values :: proc(t: ^testing.T) {
	text, text_error := settings.default_text()
	defer delete(text)
	testing.expect_value(t, text_error, nil)
	testing.expect(t, strings.contains(text, "font.family = \"Cascadia Mono\"\n"))
	testing.expect(t, strings.contains(text, "shell.command = \"pwsh.exe -NoLogo\"\n"))
}

@(test)
encoded_defaults_parse_without_diagnostics :: proc(t: ^testing.T) {
	for entry in settings.SCHEMA {
		b, build_error := strings.builder_make()
		if !testing.expect_value(t, build_error, nil) {return}
		encode_error := settings.encode_value(&b, entry, entry.default_value)
		testing.expect_value(t, encode_error, nil)
		text := fmt.tprintf("%s = %s\n", entry.key, strings.to_string(b))
		strings.builder_destroy(&b)
		parsed, diagnostics, parse_error := settings.parse(text)
		testing.expectf(t, parse_error == nil, "%s: %v", entry.key, parse_error)
		testing.expectf(t, len(diagnostics) == 0, "%s wrote a diagnostic", entry.key)
		settings.destroy(&parsed)
		settings.diagnostics_destroy(&diagnostics)
	}
}

@(test)
grammar_reports_duplicate_positions_and_callers_keep_policies :: proc(t: ^testing.T) {
	text := "font.size = 10\nfont.size = 12\n"
	scanner := settings.line_scanner_init(text)
	first, first_ok := settings.line_next(&scanner)
	second, second_ok := settings.line_next(&scanner)
	testing.expect(t, first_ok && second_ok)
	testing.expect_value(t, first.number, 1)
	testing.expect_value(t, second.number, 2)
	testing.expect_value(t, first.key, "font.size")
	testing.expect_value(t, second.key, first.key)

	parsed, diagnostics, parse_error := settings.parse(text)
	defer settings.destroy(&parsed)
	defer settings.diagnostics_destroy(&diagnostics)
	testing.expect_value(t, parse_error, nil)
	testing.expect_value(t, len(diagnostics), 1)
	if len(diagnostics) == 1 {
		testing.expect_value(t, diagnostics[0].line, 2)
		testing.expect_value(t, diagnostics[0].key, "font.size")
		testing.expect_value(t, diagnostics[0].kind, settings.Diagnostic_Kind.Duplicate_Key)
		testing.expect_value(
			t,
			diagnostics[0].message,
			`duplicate key "font.size"; last value wins`,
		)
	}
	testing.expect_value(t, parsed.font.size, 12)

	updated, message, edit_error := settings.edit_text(text, "font.size", "14")
	defer delete(updated)
	defer delete(message)
	testing.expect_value(t, edit_error, nil)
	testing.expect_value(t, message, "")
	testing.expect_value(t, updated, "font.size = 14\n")
}
