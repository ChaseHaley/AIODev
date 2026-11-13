package settings_test

import "aio:settings"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// Each retired toggle is left out, set true or set false.
@(private = "file")
TOGGLE_VALUES :: [3]string{"", "true", "false"}

// Writes the `values[i]`-th value of each key; an empty value leaves the key out.
@(private = "file")
toggle_combination :: proc(keys: []string, code: int, values: []string) -> string {
	choices := TOGGLE_VALUES
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "font.size = 13\n")
	rest := code
	for key, i in keys {
		values[i] = choices[rest % len(choices)]
		rest /= len(choices)
		if values[i] != "" {fmt.sbprintf(&b, "%s = %s\n", key, values[i])}
	}
	return strings.to_string(b)
}

// Migrates and parses `source` as load does, expecting a clean file that a second migration leaves
// alone. The caller destroys the settings.
@(private = "file")
toggle_load :: proc(t: ^testing.T, source: string) -> (s: settings.Settings, updated: string, ok: bool) {
	migrated: bool
	err: runtime.Allocator_Error
	updated, migrated, err = settings.migrate_settings_text(source, context.temp_allocator)
	if !testing.expect_value(t, err, nil) {return}
	diagnostics: [dynamic]settings.Diagnostic
	s, diagnostics, err = settings.parse(updated)
	defer settings.diagnostics_destroy(&diagnostics)
	if !testing.expect_value(t, err, nil) {return}
	testing.expectf(t, len(diagnostics) == 0, "%q has %d diagnostics", updated, len(diagnostics))
	again, again_migrated, again_error := settings.migrate_settings_text(updated, context.temp_allocator)
	testing.expect_value(t, again_error, nil)
	testing.expectf(t, !again_migrated && again == updated, "%q migrates again", updated)
	return s, updated, true
}

// Every combination of the four surface toggles keeps what each showed; a missing toggle was on.
@(test)
status_surface_toggles_migrate_into_show_status_on :: proc(t: ^testing.T) {
	keys := []string {
		"status.tab_indicators",
		"status.active_tab_indicator",
		"status.pane_headers",
		"status.workspace_picker",
	}
	values: [4]string
	for code in 0 ..< 81 {
		source := toggle_combination(keys, code, values[:])
		s, updated, ok := toggle_load(t, source)
		if !ok {continue}
		expected: settings.Status_Surfaces
		for value, i in values {
			if value != "false" {expected += {settings.Status_Surface(i)}}
		}
		testing.expectf(t, s.status.surfaces == expected, "%q gave %v", updated, s.status.surfaces)
		settings.destroy(&s)
	}
}

// Every combination of the five show toggles keeps which states were listed; a missing toggle was on.
@(test)
status_show_toggles_migrate_into_show_statuses :: proc(t: ^testing.T) {
	keys := []string {
		"status.show_working",
		"status.show_blocked",
		"status.show_done",
		"status.show_error",
		"status.show_idle",
	}
	values: [5]string
	for code in 0 ..< 243 {
		source := toggle_combination(keys, code, values[:])
		s, updated, ok := toggle_load(t, source)
		if !ok {continue}
		expected: settings.Status_Show_States
		for value, i in values {
			if value != "false" {expected += {settings.Status_Show_State(i)}}
		}
		testing.expectf(t, s.status.show == expected, "%q gave %v", updated, s.status.show)
		settings.destroy(&s)
	}
}

// The old status.taskbar master turned progress off whatever the state toggles said; on, each state
// toggle decided, missing ones on.
@(test)
status_taskbar_master_and_states_migrate_into_taskbar_progress :: proc(t: ^testing.T) {
	keys := []string {
		"status.taskbar",
		"status.taskbar_working",
		"status.taskbar_blocked",
		"status.taskbar_error",
	}
	values: [4]string
	for code in 0 ..< 81 {
		source := toggle_combination(keys, code, values[:])
		s, updated, ok := toggle_load(t, source)
		if !ok {continue}
		expected: settings.Status_Taskbar_States
		if values[0] != "false" {
			for value, i in values[1:] {
				if value != "false" {expected += {settings.Status_Taskbar_State(i)}}
			}
		}
		testing.expectf(t, s.status.taskbar == expected, "%q gave %v", updated, s.status.taskbar)
		settings.destroy(&s)
	}
}

// Every combination of the three confirmation toggles keeps which questions were asked.
@(test)
confirm_toggles_migrate_into_confirm_before :: proc(t: ^testing.T) {
	keys := []string{"tab.confirm_close", "pane.confirm_shell_switch", "terminal.confirm_multiline_paste"}
	values: [3]string
	for code in 0 ..< 27 {
		source := toggle_combination(keys, code, values[:])
		s, updated, ok := toggle_load(t, source)
		if !ok {continue}
		expected: settings.Confirm_Prompts
		for value, i in values {
			if value != "false" {expected += {settings.Confirm_Prompt(i)}}
		}
		testing.expectf(t, s.interface.confirm == expected, "%q gave %v", updated, s.interface.confirm)
		settings.destroy(&s)
	}
}

// Select filled in and selected the last search with or without keep; keep alone filled it in.
@(test)
find_toggles_migrate_into_find_reopen :: proc(t: ^testing.T) {
	keys := []string{"terminal.find_keep_query", "terminal.find_select_query"}
	values: [2]string
	for code in 0 ..< 9 {
		source := toggle_combination(keys, code, values[:])
		s, updated, ok := toggle_load(t, source)
		if !ok {continue}
		expected := settings.Find_Reopen.Empty
		if values[0] == "true" {expected = .Last}
		if values[1] == "true" {expected = .Last_Selected}
		testing.expectf(t, s.terminal.find_reopen == expected, "%q gave %v", updated, s.terminal.find_reopen)
		settings.destroy(&s)
	}
}

// A file written with every old default migrates to the new defaults, and one with every toggle
// off turns every new setting off.
@(test)
toggle_migration_keeps_all_defaults_and_all_off :: proc(t: ^testing.T) {
	keys := [?]string {
		"tab.confirm_close",
		"status.tab_indicators",
		"status.active_tab_indicator",
		"status.pane_headers",
		"status.workspace_picker",
		"status.taskbar",
		"status.show_working",
		"status.show_blocked",
		"status.show_done",
		"status.show_error",
		"status.show_idle",
		"status.taskbar_working",
		"status.taskbar_blocked",
		"status.taskbar_error",
		"pane.confirm_shell_switch",
		"terminal.confirm_multiline_paste",
		"terminal.find_keep_query",
		"terminal.find_select_query",
	}
	defaults := strings.builder_make(context.temp_allocator)
	off := strings.builder_make(context.temp_allocator)
	for key in keys {
		entry := strings.has_prefix(key, "terminal.find_") ? "false" : "true"
		fmt.sbprintf(&defaults, "%s = %s\n", key, entry)
		fmt.sbprintf(&off, "%s = false\n", key)
	}
	s, updated, ok := toggle_load(t, strings.to_string(defaults))
	if !ok {return}
	testing.expect_value(t, updated,
		"interface.confirm = close_split_tab, shell_switch, multiline_paste\n" +
		"status.surfaces = tabs, active_tab, pane_headers, workspace_picker\n" +
		"status.taskbar = working, blocked, error\n" +
		"status.show = working, blocked, done, error, idle\n" +
		"terminal.find_reopen = empty\n")
	expected, defaults_error := settings.defaults()
	testing.expect_value(t, defaults_error, nil)
	testing.expect_value(t, s.status, expected.status)
	testing.expect_value(t, s.interface, expected.interface)
	testing.expect_value(t, s.terminal, expected.terminal)
	settings.destroy(&expected)
	settings.destroy(&s)

	none, none_text, none_ok := toggle_load(t, strings.to_string(off))
	if !none_ok {return}
	defer settings.destroy(&none)
	testing.expect_value(t, none_text,
		"interface.confirm = none\n" +
		"status.surfaces = none\n" +
		"status.taskbar = none\n" +
		"status.show = none\n" +
		"terminal.find_reopen = empty\n")
}

// A file that already sets a new key keeps it: the family's old lines go, whatever they said.
// status.taskbar is the new key once its value is not true or false.
@(test)
toggle_migration_keeps_a_new_key_over_old_lines :: proc(t: ^testing.T) {
	source := "status.pane_headers = false\n" +
		"status.surfaces = tabs\n" +
		"status.taskbar_working = false\n" +
		"status.taskbar = working\n" +
		"terminal.find_reopen = last\n" +
		"# Start find with the last search filled in.\n" +
		"terminal.find_select_query = true\n" +
		"font.size = 13\n"
	s, updated, ok := toggle_load(t, source)
	if !ok {return}
	defer settings.destroy(&s)
	testing.expect_value(t, updated,
		"status.surfaces = tabs\n" +
		"status.taskbar = working\n" +
		"terminal.find_reopen = last\n" +
		"font.size = 13\n")
	testing.expect_value(t, s.status.surfaces, settings.Status_Surfaces{.Tabs})
	testing.expect_value(t, s.status.taskbar, settings.Status_Taskbar_States{.Working})
	testing.expect_value(t, s.terminal.find_reopen, settings.Find_Reopen.Last)
}

// The old parser kept the last of repeated keys and replaced an invalid value with the default.
@(test)
toggle_migration_keeps_the_last_value_and_defaults_invalid_ones :: proc(t: ^testing.T) {
	source := "status.show_idle = false\n" +
		"status.show_idle = true\n" +
		"status.show_done = true\n" +
		"status.show_done = false\n" +
		"tab.confirm_close = false\n" +
		"tab.confirm_close = yes\n" +
		"terminal.find_keep_query = \"true\"\n"
	s, _, ok := toggle_load(t, source)
	if !ok {return}
	defer settings.destroy(&s)
	testing.expect_value(t, s.status.show, settings.Status_Show_States{.Working, .Blocked, .Error, .Idle})
	testing.expect_value(t, s.interface.confirm,
		settings.Confirm_Prompts{.Close_Split_Tab, .Shell_Switch, .Multiline_Paste})
	testing.expect_value(t, s.terminal.find_reopen, settings.Find_Reopen.Empty)
}

// A file shaped like a real one, with comments, a BOM, CRLF and an old notify toggle, is rewritten on
// disk where each family first appeared, and loads with the values it had.
@(test)
toggle_migration_load_rewrites_a_real_file :: proc(t: ^testing.T) {
	directory, directory_error := os.mkdir_temp("tests/settings", "toggles-", context.allocator)
	if !testing.expect_value(t, directory_error, nil) {return}
	defer delete(directory)
	defer testing.expect_value(t, os.remove_all(directory), nil)
	path := strings.concatenate({directory, "/settings.ini"}, context.temp_allocator)
	source := "\xef\xbb\xbf# Ask before a running pane's shell is replaced, losing its session.\r\n" +
		"pane.confirm_shell_switch = false\r\n" +
		"pane.minimum_rows = 5\r\n" +
		"\r\n" +
		"# Ask before closing a tab that has more than one pane.\r\n" +
		"tab.confirm_close = true\r\n" +
		"\r\n" +
		"status.enabled = true\r\n" +
		"# Show a spinner, progress bar or symbol on tabs whose programs are working.\r\n" +
		"status.tab_indicators = true\r\n" +
		"# Also show tab status on the tab you are looking at.\r\n" +
		"status.active_tab_indicator = false\r\n" +
		"status.pane_headers = true\r\n" +
		"status.panel_side = left\r\n" +
		"# Show progress, blocked and failed work on the window's taskbar button.\r\n" +
		"status.taskbar = true\r\n" +
		"# Show programs that are working.\r\n" +
		"status.show_working = true\r\n" +
		"status.show_idle = false\r\n" +
		"# How to notify you when a program needs you.\r\n" +
		"status.notify_blocked = banner, sound\r\n" +
		"status.sound_error = false\r\n" +
		"# Include this state in the taskbar progress indicator.\r\n" +
		"status.taskbar_working = false\r\n" +
		"status.taskbar_error = true\r\n" +
		"terminal.copy_on_select = false\r\n" +
		"# Ask before pasting line breaks the shell would run as separate commands.\r\n" +
		"terminal.confirm_multiline_paste = true\r\n" +
		"# Start find with the last search filled in.\r\n" +
		"terminal.find_keep_query = true\r\n" +
		"terminal.minimum_contrast = 4.5"
	if !testing.expect_value(t, os.write_entire_file(path, source), nil) {return}
	s, diagnostics, created, migrated, migration_error, err := settings.load(path)
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&diagnostics)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, created, false)
	testing.expect_value(t, migrated, true)
	testing.expect_value(t, migration_error, settings.Save_Error.None)
	testing.expect_value(t, len(diagnostics), 0)
	comment :: proc(key: string) -> string {
		return strings.concatenate({"# ", settings.schema_find(key).description, "\r\n"}, context.temp_allocator)
	}
	expected := strings.concatenate({
		"\xef\xbb\xbf", comment("interface.confirm"),
		"interface.confirm = close_split_tab, multiline_paste\r\n",
		"pane.minimum_rows = 5\r\n",
		"\r\n",
		"\r\n",
		"status.enabled = true\r\n",
		comment("status.surfaces"),
		"status.surfaces = tabs, pane_headers, workspace_picker\r\n",
		"status.panel_side = left\r\n",
		comment("status.taskbar"),
		"status.taskbar = blocked, error\r\n",
		comment("status.show"),
		"status.show = working, blocked, done, error\r\n",
		"# How to notify you when a program needs you.\r\n",
		"status.notify_blocked = banner, sound\r\n",
		"status.notify_error = banner\r\n",
		"terminal.copy_on_select = false\r\n",
		comment("terminal.find_reopen"),
		"terminal.find_reopen = last\r\n",
		"terminal.minimum_contrast = 4.5",
	}, context.temp_allocator)
	data, read_error := os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, read_error, nil)
	testing.expect_value(t, string(data), expected)
	testing.expect_value(t, s.interface.confirm, settings.Confirm_Prompts{.Close_Split_Tab, .Multiline_Paste})
	testing.expect_value(t, s.status.surfaces, settings.Status_Surfaces{.Tabs, .Pane_Headers, .Workspace_Picker})
	testing.expect_value(t, s.status.taskbar, settings.Status_Taskbar_States{.Blocked, .Error})
	testing.expect_value(t, s.status.show, settings.Status_Show_States{.Working, .Blocked, .Done, .Error})
	testing.expect_value(t, s.status.notify_error, settings.Status_Channels{.Banner})
	testing.expect_value(t, s.terminal.find_reopen, settings.Find_Reopen.Last)
}
