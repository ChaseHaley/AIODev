package settings_test

import "core:strings"
import "core:fmt"
import "core:testing"
import "aio:settings"

@(test)
process_padding_groups_match_names_and_preserve_order :: proc(t: ^testing.T) {
	s, diagnostics, err := settings.parse(
		"window.padding = 8\nprocess.padding_groups = editors:0:nvim,vim.exe; tools:4:less,bat,nvim")
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&diagnostics)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(diagnostics), 0)
	for test in ([?]struct { name: string, padding: int, matched: bool }{
		{"NVIM.EXE", 0, true}, {"vim", 0, true}, {"less.exe", 4, true}, {"bat", 4, true},
		{"pwsh.exe", 8, false}, {"nvim-qt.exe", 8, false}, {"", 8, false},
	}) {
		padding, matched := settings.process_padding(&s, test.name)
		testing.expect(t, padding == test.padding, test.name)
		testing.expect(t, matched == test.matched, test.name)
	}
	updated, message, edit_error := settings.edit_text("# keep\nwindow.padding = 8\n",
		"process.padding_groups", "editors:0:nvim,vim")
	defer delete(updated)
	defer delete(message)
	testing.expect_value(t, edit_error, nil)
	testing.expect_value(t, message, "")
	testing.expect(t, strings.contains(updated, "# keep\nwindow.padding = 8\n"))
}

@(test)
window_and_process_padding_accept_the_same_content_range :: proc(t: ^testing.T) {
	entry := settings.schema_find("window.padding")
	if !testing.expect(t, entry != nil) {return}
	testing.expect_value(t, entry.valid, settings.CONTENT_PADDING_RANGE)
	minimum, maximum := int(entry.valid.minimum), int(entry.valid.maximum)
	for padding in ([?]int{minimum - 1, minimum, maximum, maximum + 1}) {
		source := fmt.tprintf(
			"window.padding = %d\nprocess.padding_groups = test:%d:nvim\n", padding, padding,
		)
		s, diagnostics, error := settings.parse(source)
		defer settings.destroy(&s)
		defer settings.diagnostics_destroy(&diagnostics)
		testing.expect_value(t, error, nil)
		accepted := padding >= minimum && padding <= maximum
		testing.expect_value(t, len(diagnostics), accepted ? 0 : 2)
		if accepted {
			actual, matched := settings.process_padding(&s, "nvim.exe")
			testing.expect(t, matched)
			testing.expect_value(t, actual, s.window.padding)
		}
	}
}

@(test)
process_padding_groups_reject_malformed_rules :: proc(t: ^testing.T) {
	for value in ([?]string{"missing", "group:-1:nvim", "group:1025:nvim", "group:zero:nvim",
		":0:nvim", "group:0:", "group:0:nvim,,vim", "group:0:C:\\nvim.exe", "group:0:vim*",
		"group:0:vim,", "group:0:vim;", "group:0:vim;;tools:4:less"}) {
		s, diagnostics, err := settings.parse(fmt.tprintf("process.padding_groups = %s", value))
		testing.expect_value(t, err, nil)
		testing.expect(t, len(diagnostics) == 1, value)
		testing.expect(t, s.process.padding_groups == "", value)
		settings.destroy(&s)
		settings.diagnostics_destroy(&diagnostics)
	}
}

@(test)
padding_groups_description_and_error_text_show_the_grammar_example :: proc(t: ^testing.T) {
	entry := settings.schema_find(settings.PADDING_GROUPS_KEY)
	if testing.expect(t, entry != nil) {
		testing.expect(t, strings.contains(entry.description, settings.PADDING_GROUPS_EXAMPLE))
	}
	s, diagnostics, err := settings.parse(
		settings.PADDING_GROUPS_KEY + " = " + settings.PADDING_GROUPS_EXAMPLE,
	)
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&diagnostics)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(diagnostics), 0)
	testing.expect_value(t, s.process.padding_groups, settings.PADDING_GROUPS_EXAMPLE)

	broken, broken_diagnostics, broken_error := settings.parse(
		settings.PADDING_GROUPS_KEY + " = broken",
	)
	defer settings.destroy(&broken)
	defer settings.diagnostics_destroy(&broken_diagnostics)
	testing.expect_value(t, broken_error, nil)
	testing.expect_value(t, len(broken_diagnostics), 1)
	testing.expect(
		t,
		strings.contains(broken_diagnostics[0].message, settings.PADDING_GROUPS_EXAMPLE),
	)
	testing.expect(t, strings.contains(broken_diagnostics[0].message, "0..1024"))
}

@(test)
padding_group_names_validation_accepts_are_the_names_lookup_matches :: proc(t: ^testing.T) {
	s, diagnostics, err := settings.parse(
		"window.padding = 8\nprocess.padding_groups = odd:3:my app,weird'name,a.b,vim",
	)
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&diagnostics)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(diagnostics), 0)
	for name in ([?]string{"my app", "WEIRD'NAME", "a.b", "VIM.EXE"}) {
		padding, matched := settings.process_padding(&s, name)
		testing.expect(t, matched && padding == 3, name)
	}
}

@(test)
padding_group_lookup_skips_a_malformed_group_that_validation_rejects :: proc(t: ^testing.T) {
	s := settings.Settings{}
	s.window.padding = 8
	s.process.padding_groups = "bad:0:vim*; tools:4:bat"
	padding, matched := settings.process_padding(&s, "bat")
	testing.expect(t, matched && padding == 4)
	padding, matched = settings.process_padding(&s, "vim*")
	testing.expect(t, !matched && padding == 8)

	parsed, diagnostics, err := settings.parse(
		fmt.tprintf("%s = %s", settings.PADDING_GROUPS_KEY, s.process.padding_groups),
	)
	defer settings.destroy(&parsed)
	defer settings.diagnostics_destroy(&diagnostics)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(diagnostics), 1)
}

@(test)
padding_groups_text_encodes_what_the_parser_reads_and_names_the_first_refused_field :: proc(t: ^testing.T) {
	groups := [?]settings.Padding_Draft{
		{name = " editors ", padding = " 0 ", programs = []string{"nvim", " vim.exe "}},
		{name = "tools", padding = "1024", programs = []string{"less"}},
	}
	text, problem, err := settings.padding_groups_text(groups[:], context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect(t, problem == nil)
	testing.expect_value(t, text, "editors:0:nvim,vim.exe;tools:1024:less")
	s, diagnostics, parse_error := settings.parse(fmt.tprintf("%s = %s", settings.PADDING_GROUPS_KEY, text))
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&diagnostics)
	testing.expect_value(t, parse_error, nil)
	testing.expect_value(t, len(diagnostics), 0)
	padding, matched := settings.process_padding(&s, "VIM")
	testing.expect(t, matched && padding == 0)

	Case :: struct {
		group:   settings.Padding_Draft,
		problem: settings.Padding_Problem,
	}
	for c in ([?]Case{
		{{name = "a", padding = "0", programs = []string{"x;y"}}, .Program},
		{{name = "a", padding = "0", programs = []string{"foo,bar"}}, .Program},
		{{name = "a", padding = "0", programs = []string{"*.exe"}}, .Program},
		{{name = "a", padding = "0", programs = []string{"nvim", "NVIM.exe"}}, .Duplicate_Program},
		{{name = "a;b", padding = "0", programs = []string{"nvim"}}, .Name},
		{{name = " ", padding = "0", programs = []string{"nvim"}}, .Name},
		{{name = "a", padding = "1025", programs = []string{"nvim"}}, .Padding},
		{{name = "a", padding = "0"}, .No_Programs},
	}) {
		drafts := []settings.Padding_Draft{c.group}
		refused, refusal, refused_error := settings.padding_groups_text(drafts, context.temp_allocator)
		testing.expect_value(t, refused_error, nil)
		testing.expect_value(t, refused, "")
		got, has_problem := refusal.?
		testing.expect(t, has_problem && got == c.problem, c.group.name)
	}
}
