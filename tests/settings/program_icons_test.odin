package settings_test

import "core:fmt"
import "core:strings"
import "core:testing"
import "aio:settings"

@(test)
program_icon_files_match_names_and_the_first_entry_wins :: proc(t: ^testing.T) {
	s, diagnostics, err := settings.parse(
		`tabs.program_icon_files = "codex = ~/icons/codex.png; NVIM.exe=D:\icons\nvim.png; codex=other.png"`,
	)
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&diagnostics)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(diagnostics), 0)
	for test in ([?]struct {
			name, path: string,
			found:      bool,
		} {
			{"codex", "~/icons/codex.png", true},
			{"Codex.exe", "~/icons/codex.png", true},
			{"nvim", `D:\icons\nvim.png`, true},
			{"vim", "", false},
			{"", "", false},
		}) {
		path, found := settings.program_icon_file(&s, test.name)
		testing.expect_value(t, found, test.found)
		testing.expect_value(t, path, test.path)
	}
}

@(test)
program_icon_files_reject_malformed_entries :: proc(t: ^testing.T) {
	for value in ([?]string{"codex", "=a.png", "codex=", "co:dex=a.png", "codex=a.png;", "a=b;;c=d"}) {
		s, diagnostics, err := settings.parse(fmt.tprintf("tabs.program_icon_files = \"%s\"", value))
		testing.expect_value(t, err, nil)
		testing.expect(t, len(diagnostics) == 1, value)
		testing.expect(t, s.tabs.program_icon_files == "", value)
		settings.destroy(&s)
		settings.diagnostics_destroy(&diagnostics)
	}
}

@(test)
program_icon_files_description_shows_an_example_the_parser_accepts :: proc(t: ^testing.T) {
	entry := settings.schema_find(settings.PROGRAM_ICON_FILES_KEY)
	if testing.expect(t, entry != nil) {
		testing.expect(t, strings.contains(entry.description, settings.PROGRAM_ICON_FILES_EXAMPLE))
	}
	s, diagnostics, err := settings.parse(
		settings.PROGRAM_ICON_FILES_KEY + " = \"" + settings.PROGRAM_ICON_FILES_EXAMPLE + "\"",
	)
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&diagnostics)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(diagnostics), 0)
	testing.expect_value(t, s.tabs.program_icon_files, settings.PROGRAM_ICON_FILES_EXAMPLE)
}
