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
