package settings_test

import "core:testing"
import "core:strings"
import "aio:settings"

@(test)
shell_badges_follow_the_launched_executable_and_explicit_override :: proc(t: ^testing.T) {
	for row in ([?][3]string{
		{"pwsh.exe -NoLogo", "pwsh", ">_"},
		{"  \"C:\\Program Files\\PowerShell\\7\\pwsh.EXE\" -NoLogo", "pwsh", ">_"},
		{"C:\\Windows\\System32\\CMD.EXE /k", "CMD", "C:"},
		{"wsl.exe --distribution Debian", "wsl", "$"},
		{"/bin/bash --login", "bash", "$"},
		{"custom-shell.exe", "custom-shell", ">_"},
		{"", "", ">_"},
	}) {
		executable := settings.shell_executable(row[0])
		testing.expect_value(t, executable, row[1])
		testing.expect_value(t, settings.shell_icon(executable, ""), row[2])
		testing.expect_value(t, settings.shell_icon(executable, "λ"), "λ")
	}
}

@(test)
header_settings_reload_and_serialize_through_the_shared_schema :: proc(t: ^testing.T) {
	s, diagnostics, err := settings.parse("pane.show_headers=false\nshell.icon=λ\n")
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&diagnostics)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(diagnostics), 0)
	testing.expect(t, !s.pane.show_headers)
	testing.expect_value(t, s.shell.icon, "λ")
	testing.expect_value(t, settings.value_text(&s, settings.schema_find("pane.show_headers")^), "false")
}

@(test)
shell_integration_wraps_only_interactive_powershell :: proc(t: ^testing.T) {
	for command in ([?]string{"pwsh.exe -NoLogo -NoProfile", "powershell.exe -NoLogo",
		"pwsh -ExecutionPolicy Bypass -NoLogo", `pwsh -wd C:\src`, `"C:\Program Files\PowerShell\7\pwsh.exe"`}) {
		testing.expect_value(t, settings.shell_command_line(command, false), command)
		wrapped := settings.shell_command_line(command, true)
		testing.expect(t, strings.has_prefix(wrapped, strings.concatenate({command, " -NoExit -EncodedCommand "}, context.temp_allocator)), wrapped)
	}
	for command in ([?]string{"pwsh -c Write-Host", "pwsh -Command Get-Date", "pwsh -File test.ps1",
		"pwsh test.ps1", "pwsh -EncodedCommand ABC", "pwsh -NonInteractive", "cmd.exe /d", "wsl.exe", ""}) {
		testing.expect_value(t, settings.shell_command_line(command, true), command)
	}
}
