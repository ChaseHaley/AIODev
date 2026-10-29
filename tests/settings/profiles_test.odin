package settings_test

import "core:os"
import "core:strings"
import "core:testing"
import "aio:settings"

@(test)
defaults_include_built_in_profile :: proc(t: ^testing.T) {
	s, err := settings.defaults()
	testing.expect_value(t, err, nil)
	defer settings.destroy(&s)
	builtin := settings.profile_find(&s.profiles, settings.PROFILE_DEFAULT_ID)
	if !testing.expect(t, builtin != nil) {return}
	testing.expect_value(t, builtin.command, settings.DEFAULT_PROFILE_COMMAND)
	testing.expect_value(t, builtin.directory, settings.DEFAULT_PROFILE_DIRECTORY)
	testing.expect_value(t, builtin.name, "PowerShell 7")
	testing.expect_value(t, s.shell.default_profile, settings.PROFILE_DEFAULT_ID)
	testing.expect_value(t, s.shell.command, settings.DEFAULT_PROFILE_COMMAND)
}

@(test)
profiles_inherit_and_order :: proc(t: ^testing.T) {
	fixture :: `shell.directory = D:\work
profile.pwsh.name = PowerShell 7
profile.pwsh.command = pwsh.exe -NoLogo
profile.cmd.command = cmd.exe
profile.cmd.directory = C:\Windows
profile.cmd.hidden = true
profile.order = pwsh, cmd
`
	s, diagnostics, err := settings.parse(fixture)
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&diagnostics)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(diagnostics), 0)
	pwsh := settings.profile_find(&s.profiles, "pwsh")
	cmd := settings.profile_find(&s.profiles, "cmd")
	if !testing.expect(t, pwsh != nil && cmd != nil) {return}
	testing.expect_value(t, pwsh.name, "PowerShell 7")
	testing.expect_value(t, pwsh.directory, `D:\work`)
	testing.expect_value(t, pwsh.icon, "")
	testing.expect_value(t, cmd.directory, `C:\Windows`)
	testing.expect_value(t, cmd.hidden, true)
	testing.expect_value(t, s.profiles.default_id, settings.PROFILE_DEFAULT_ID)

	ordered := make([]int, len(s.profiles.items), context.temp_allocator)
	count := settings.profiles_in_order(&s.profiles, ordered)
	testing.expect_value(t, count, 3)
	testing.expect_value(t, s.profiles.items[ordered[0]].id, "pwsh")
	testing.expect_value(t, s.profiles.items[ordered[1]].id, "cmd")
	testing.expect_value(t, s.profiles.items[ordered[2]].id, "default")

	visible := make([]int, len(s.profiles.items), context.temp_allocator)
	count = settings.profiles_in_order(&s.profiles, visible, visible_only = true)
	testing.expect_value(t, count, 2)
	testing.expect_value(t, s.profiles.items[visible[0]].id, "pwsh")
	testing.expect_value(t, s.profiles.items[visible[1]].id, "default")
}

@(test)
profile_diagnostics_do_not_block_startup :: proc(t: ^testing.T) {
	fixture :: `profile.ABC.command = cmd.exe
profile.pwsh.comand = cmd.exe
profile.pwsh.command =
profile.pwsh.hidden = yes
profile.pwsh.name =
profile.order = pwsh, , pwsh, ABC
profile.too.many.extra = x
`
	s, diagnostics, err := settings.parse(fixture)
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&diagnostics)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(diagnostics), 8)
	testing.expect_value(t, s.profiles.items[0].id, settings.PROFILE_DEFAULT_ID)
	pwsh := settings.profile_find(&s.profiles, "pwsh")
	if testing.expect(t, pwsh != nil) {
		testing.expect_value(t, pwsh.command, "")
		testing.expect_value(t, pwsh.hidden, false)
	}
	kinds: [8]settings.Diagnostic_Kind
	for d, i in diagnostics {kinds[i] = d.kind}
	testing.expect_value(t, kinds[0], settings.Diagnostic_Kind.Unknown_Key)
	testing.expect_value(t, kinds[1], settings.Diagnostic_Kind.Unknown_Key)
	testing.expect_value(t, kinds[2], settings.Diagnostic_Kind.Invalid_Value)
	testing.expect_value(t, kinds[3], settings.Diagnostic_Kind.Invalid_Value)
	testing.expect_value(t, kinds[4], settings.Diagnostic_Kind.Invalid_Value)
}

@(test)
profile_resolution_falls_back_to_default :: proc(t: ^testing.T) {
	s, diagnostics, err := settings.parse(`profile.pwsh.command = pwsh.exe -NoLogo
profile.empty.hidden = true
shell.default_profile = pwsh
`)
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&diagnostics)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(diagnostics), 0)
	profile, requested := settings.profile_resolve(&s, "pwsh")
	testing.expect(t, requested)
	testing.expect_value(t, profile.id, "pwsh")
	profile, requested = settings.profile_resolve(&s, "")
	testing.expect(t, requested)
	testing.expect_value(t, profile.id, "pwsh")
	profile, requested = settings.profile_resolve(&s, "missing")
	testing.expect(t, !requested)
	testing.expect_value(t, profile.id, "pwsh")
	profile, requested = settings.profile_resolve(&s, "empty")
	testing.expect(t, !requested)
	testing.expect_value(t, profile.id, "pwsh")
	profile, requested = settings.profile_resolve(&s, "default")
	testing.expect(t, requested)
	testing.expect_value(t, profile.id, "default")
}

@(test)
profile_detection_fills_unset_fields_and_rebuilds :: proc(t: ^testing.T) {
	s, diagnostics, err := settings.parse(`profile.ubuntu.hidden = true
profile.pwsh.name = My PowerShell
`)
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&diagnostics)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(diagnostics), 0)
	testing.expect_value(t, settings.profile_detect(
		&s,
		{"ubuntu", "Ubuntu", "wsl.exe -d Ubuntu", "~"},
	), nil)
	ubuntu := settings.profile_find(&s.profiles, "ubuntu")
	if testing.expect(t, ubuntu != nil) {
		testing.expect_value(t, ubuntu.command, "wsl.exe -d Ubuntu")
		testing.expect_value(t, ubuntu.name, "Ubuntu")
		testing.expect_value(t, ubuntu.hidden, true)
		testing.expect_value(t, ubuntu.detected, false)
	}
	testing.expect_value(t, settings.profile_detect(
		&s,
		{"pwsh", "PowerShell 7", "pwsh.exe -NoLogo", "~"},
	), nil)
	pwsh := settings.profile_find(&s.profiles, "pwsh")
	if testing.expect(t, pwsh != nil) {
		testing.expect_value(t, pwsh.name, "My PowerShell")
		testing.expect_value(t, pwsh.command, "pwsh.exe -NoLogo")
		testing.expect_value(t, pwsh.detected, false)
	}
	settings.profiles_begin_detection(&s.profiles)
	testing.expect(t, settings.profile_find(&s.profiles, "ubuntu") != nil)
	pwsh = settings.profile_find(&s.profiles, "pwsh")
	testing.expect(t, pwsh != nil)
	testing.expect_value(t, pwsh.command, "pwsh.exe -NoLogo")
}

@(test)
detected_only_profiles_are_replaced_on_reload :: proc(t: ^testing.T) {
	s, diagnostics, err := settings.parse("")
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&diagnostics)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, settings.profile_detect(
		&s,
		{"cmd", "Command Prompt", "cmd.exe", "~"},
	), nil)
	cmd := settings.profile_find(&s.profiles, "cmd")
	if !testing.expect(t, cmd != nil) {return}
	testing.expect(t, cmd.detected)
	settings.profiles_begin_detection(&s.profiles)
	testing.expect(t, settings.profile_find(&s.profiles, "cmd") == nil)
}

@(test)
migration_rewrites_legacy_shell_keys :: proc(t: ^testing.T) {
	source := "# keep\r\nshell.command = cmd.exe /k echo hi\r\n" +
		`shell.directory = D:\work` + "\r\nfont.size = 12\r\n"
	updated, migrated, err := settings.migrate_text(source)
	defer delete(updated)
	testing.expect_value(t, err, nil)
	testing.expect(t, migrated)
	testing.expect(t, strings.has_prefix(updated, "# keep\r\n"))
	testing.expect(t, strings.contains(updated, `profile.default.command = "cmd.exe /k echo hi"`))
	testing.expect(t, strings.contains(updated, `profile.default.directory = "D:\work"`))
	testing.expect(t, strings.contains(updated, "shell.default_profile = default\r\n"))
	testing.expect(t, strings.contains(updated, "profile.order = default\r\n"))
	testing.expect(t, !strings.contains(updated, "shell.command = cmd.exe"))
	testing.expect(t, strings.contains(updated, "font.size = 12\r\n"))

	s, diagnostics, parse_error := settings.parse(updated)
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&diagnostics)
	testing.expect_value(t, parse_error, nil)
	testing.expect_value(t, len(diagnostics), 0)
	testing.expect_value(t, s.shell.command, "cmd.exe /k echo hi")
	testing.expect_value(t, s.shell.directory, `D:\work`)
	builtin := settings.profile_find(&s.profiles, settings.PROFILE_DEFAULT_ID)
	if testing.expect(t, builtin != nil) {
		testing.expect_value(t, builtin.command, "cmd.exe /k echo hi")
	}

	again, again_migrated, again_error := settings.migrate_text(updated)
	defer delete(again)
	testing.expect_value(t, again_error, nil)
	testing.expect_value(t, again_migrated, false)
	testing.expect_value(t, again, "")
}

@(test)
migration_keeps_existing_default_profile_keys :: proc(t: ^testing.T) {
	source := "profile.default.command = \"pwsh.exe -NoLogo\"\nshell.command = cmd.exe\n"
	updated, migrated, err := settings.migrate_text(source)
	defer delete(updated)
	testing.expect_value(t, err, nil)
	testing.expect(t, migrated)
	testing.expect_value(t, strings.count(updated, "profile.default.command"), 1)
	parsed, diagnostics, parse_error := settings.parse(updated)
	defer settings.destroy(&parsed)
	defer settings.diagnostics_destroy(&diagnostics)
	testing.expect_value(t, parse_error, nil)
	testing.expect_value(t, len(diagnostics), 0)
	testing.expect_value(t, parsed.shell.command, "pwsh.exe -NoLogo")
}

@(test)
load_migrates_once :: proc(t: ^testing.T) {
	directory, directory_error := os.mkdir_temp("tests/settings", "profiles-", context.allocator)
	testing.expect_value(t, directory_error, nil)
	if directory_error != nil {return}
	defer delete(directory)
	defer testing.expect_value(t, os.remove_all(directory), nil)
	path, path_error := strings.concatenate({directory, "/settings.ini"})
	testing.expect_value(t, path_error, nil)
	if path_error != nil {return}
	defer delete(path)
	legacy := "shell.command = cmd.exe\r\nshell.directory = C:\\\r\nfont.size = 12\r\n"
	testing.expect_value(t, os.write_entire_file(path, legacy), nil)
	s, diagnostics, created, migrated, migration_error, err := settings.load(path)
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&diagnostics)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, created, false)
	testing.expect(t, migrated)
	testing.expect_value(t, migration_error, settings.Save_Error.None)
	testing.expect_value(t, len(diagnostics), 0)
	testing.expect_value(t, s.shell.command, "cmd.exe")
	text, read_error := os.read_entire_file(path, context.allocator)
	defer delete(text)
	testing.expect_value(t, read_error, nil)
	testing.expect(t, strings.contains(string(text), `profile.default.command = "cmd.exe"`))
	testing.expect(t, !strings.contains(string(text), "shell.command"))

	second, second_diagnostics, second_created, second_migrated, second_migration_error, second_error :=
		settings.load(path)
	defer settings.destroy(&second)
	defer settings.diagnostics_destroy(&second_diagnostics)
	testing.expect_value(t, second_error, nil)
	testing.expect_value(t, second_created, false)
	testing.expect_value(t, second_migrated, false)
	testing.expect_value(t, second_migration_error, settings.Save_Error.None)
}

@(test)
profile_editor_writes_dynamic_keys :: proc(t: ^testing.T) {
	text, message, err := settings.edit_text("", "profile.pwsh.name", "PowerShell 7")
	defer delete(text)
	defer delete(message)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, message, "")
	parsed, diagnostics, parse_error := settings.parse(text)
	defer settings.destroy(&parsed)
	defer settings.diagnostics_destroy(&diagnostics)
	testing.expect_value(t, parse_error, nil)
	testing.expect_value(t, len(diagnostics), 0)
	testing.expect(t, settings.profile_find(&parsed.profiles, "pwsh") != nil)
	testing.expect_value(t, settings.profile_find(&parsed.profiles, "pwsh").name, "PowerShell 7")

	for pair in ([?][2]string{
		{"profile.cmd.hidden", "true"},
		{"profile.order", "default, pwsh"},
		{"profile.ubuntu.command", "wsl.exe -d Ubuntu"},
	}) {
		updated, m, e := settings.edit_text(text, pair[0], pair[1])
		testing.expect_value(t, e, nil)
		testing.expect_value(t, m, "")
		parsed_again, d, parse_again := settings.parse(updated)
		testing.expect_value(t, parse_again, nil)
		testing.expect_value(t, len(d), 0)
		settings.destroy(&parsed_again)
		settings.diagnostics_destroy(&d)
		delete(updated)
		delete(m)
	}

	for pair in ([?][2]string{
		{"profile.ABC.command", "cmd.exe"},
		{"profile.pwsh.unknown", "x"},
		{"profile.pwsh.command", ""},
		{"profile.pwsh.hidden", "yes"},
		{"profile.order", "pwsh,,pwsh"},
	}) {
		edited, m, e := settings.edit_text("", pair[0], pair[1])
		testing.expect_value(t, e, nil)
		testing.expect_value(t, edited, "")
		testing.expect(t, m != "")
		delete(edited)
		delete(m)
	}
}

@(test)
profile_names_are_unique_case_insensitively_and_ignore_self :: proc(t: ^testing.T) {
	s, diagnostics, err := settings.parse(`profile.pwsh.name = PowerShell
profile.cmd.name = Command Prompt
`)
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&diagnostics)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(diagnostics), 0)
	testing.expect(t, settings.profile_value_facts("powerShell", &s.profiles, "cmd").name_taken)
	testing.expect(t, settings.profile_value_facts("  PowerShell  ", &s.profiles, "cmd").name_taken)
	testing.expect(t, !settings.profile_value_facts("POWERSHELL", &s.profiles, "pwsh").name_taken)
	testing.expect(t, !settings.profile_value_facts("pwsh", &s.profiles, "cmd").name_taken)
	testing.expect(t, !settings.profile_value_facts("", &s.profiles, "cmd").name_taken)
}

@(test)
profile_text_facts_match_load_and_edit_validation :: proc(t: ^testing.T) {
	for value in ([?]string{"", " \t ", "\xe2\x80\x83"}) {
		facts := settings.profile_value_facts(value)
		testing.expect(t, facts.valid && facts.empty)
		for key in ([?]string{"profile.alpha.name", "profile.alpha.command"}) {
			_, issue := settings.profile_edit_text(key, value)
			testing.expect(t, issue != "")
		}
	}
	for value in ([?]string{"bad\x00text", "\xff"}) {
		testing.expect(t, !settings.profile_value_facts(value).valid)
		_, issue := settings.profile_edit_text("profile.alpha.directory", value)
		testing.expect_value(t, issue, "Expected UTF-8 text without NUL bytes.")
	}
	s, diagnostics, error := settings.parse("profile.alpha.name = \" \t \"\n" +
		"profile.alpha.command = \"\xe2\x80\x83\"\nprofile.beta.command = cmd.exe\n")
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&diagnostics)
	testing.expect_value(t, error, nil)
	testing.expect_value(t, len(diagnostics), 2)
	alpha := settings.profile_find(&s.profiles, "alpha")
	if !testing.expect(t, alpha != nil) {return}
	testing.expect_value(t, alpha.name, "alpha")
	testing.expect_value(t, alpha.command, "")
	testing.expect(t, settings.profile_find(&s.profiles, "beta") != nil)
	serialized, issue := settings.profile_edit_text("profile.alpha.name", "  café  ")
	testing.expect_value(t, issue, "")
	testing.expect_value(t, serialized, "\"  café  \"")
}

@(test)
profile_order_moves_do_not_duplicate_ids :: proc(t: ^testing.T) {
	ids := [?]string{"default", "pwsh", "cmd"}
	out: [3]string
	moved := settings.profile_move(ids[:], 0, 2, out[:])
	testing.expect_value(t, len(moved), 3)
	testing.expect_value(t, moved[0], "pwsh")
	testing.expect_value(t, moved[1], "default")
	testing.expect_value(t, moved[2], "cmd")

	moved = settings.profile_move(ids[:], 2, 0, out[:])
	testing.expect_value(t, moved[0], "cmd")
	testing.expect_value(t, moved[1], "default")
	testing.expect_value(t, moved[2], "pwsh")

	moved = settings.profile_move(ids[:], 1, 1, out[:])
	testing.expect_value(t, moved[0], "default")
	testing.expect_value(t, moved[1], "pwsh")
	testing.expect_value(t, moved[2], "cmd")
}

@(test)
profile_order_text_lists_the_table_then_the_rest :: proc(t: ^testing.T) {
	others := [?]string{"cmd", "wsl-ubuntu"}
	text, text_error := settings.profile_order_text(
		[]string{"pwsh", "default"},
		others[:],
		context.allocator,
	)
	defer delete(text)
	testing.expect_value(t, text_error, nil)
	testing.expect_value(t, text, "pwsh, default, cmd, wsl-ubuntu")
}

@(test)
default_and_hidden_writes_use_the_existing_keys :: proc(t: ^testing.T) {
	first, first_message, first_error := settings.edit_text("", "shell.default_profile", "pwsh")
	defer delete(first)
	defer delete(first_message)
	testing.expect_value(t, first_error, nil)
	testing.expect_value(t, first_message, "")
	second, second_message, second_error := settings.edit_text(first, "profile.pwsh.hidden", "true")
	defer delete(second)
	defer delete(second_message)
	testing.expect_value(t, second_error, nil)
	testing.expect_value(t, second_message, "")
	parsed, diagnostics, parse_error := settings.parse(second)
	defer settings.destroy(&parsed)
	defer settings.diagnostics_destroy(&diagnostics)
	testing.expect_value(t, parse_error, nil)
	testing.expect_value(t, len(diagnostics), 0)
	testing.expect_value(t, parsed.shell.default_profile, "pwsh")
	pwsh := settings.profile_find(&parsed.profiles, "pwsh")
	if testing.expect(t, pwsh != nil) {
		testing.expect_value(t, pwsh.hidden, true)
		testing.expect_value(t, pwsh.hidden_set, true)
	}
	testing.expect(t, !strings.has_prefix(second, "profile.pwsh.hidden"))
}
