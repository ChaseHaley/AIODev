package pty_test

import "aio:pty"
import "core:strings"
import "core:testing"

@(test)
executable_token_parsing :: proc(t: ^testing.T) {
	cases := [?]struct {
		line, token: string,
	} {
		{"pwsh.exe -NoLogo", "pwsh.exe"},
		{"  cmd.exe /d /c echo", "cmd.exe"},
		{`"C:\Program Files\PowerShell\7\pwsh.exe" -NoLogo`, `C:\Program Files\PowerShell\7\pwsh.exe`},
		{"\"C:\\Windows\\System32\\cmd.exe\"", "C:\\Windows\\System32\\cmd.exe"},
		{`"unterminated -NoLogo`, "unterminated -NoLogo"},
		{"", ""},
		{"   ", ""},
		{`"" -NoLogo`, ""},
	}
	for c in cases {
		testing.expect_value(t, pty.executable_token(c.line), c.token)
	}
}

@(test)
command_arguments_follow_the_executable :: proc(t: ^testing.T) {
	cases := [?]struct {
		line, arguments: string,
	} {
		{"nvim C:\\notes.md", "C:\\notes.md"},
		{`"C:\Program Files\Neovim\bin\nvim.exe"  "C:\a b\x.md"`, `"C:\a b\x.md"`},
		{"code", ""},
		{"", ""},
	}
	for c in cases {
		testing.expect_value(t, pty.command_arguments(c.line), c.arguments)
	}
}

// A link program may be a batch script, as VS Code's `code` is; an executable found by name is not one.
@(test)
resolve_program_tells_batch_scripts_from_executables :: proc(t: ^testing.T) {
	script, script_err := pty.resolve_program(`C:\Tools\code.CMD "C:\a b\x.md"`)
	testing.expect_value(t, script_err.kind, pty.Spawn_Error_Kind.None)
	defer pty.program_destroy(&script)
	testing.expect_value(t, script.path, `C:\Tools\code.CMD`)
	testing.expect(t, script.batch)

	found, found_err := pty.resolve_program("cmd /d /c rem")
	testing.expect_value(t, found_err.kind, pty.Spawn_Error_Kind.None)
	defer pty.program_destroy(&found)
	testing.expect(t, strings.has_suffix(strings.to_lower(found.path, context.temp_allocator), `\system32\cmd.exe`), found.path)
	testing.expect(t, !found.batch)

	_, missing := pty.resolve_program("aio_missing_program_51207")
	testing.expect_value(t, missing.kind, pty.Spawn_Error_Kind.Start_Process)
}

// cmd.exe /s strips the outer quotes and runs the rest as written, so the script keeps its own quotes.
@(test)
batch_command_line_runs_the_script_through_cmd :: proc(t: ^testing.T) {
	line, err := pty.batch_command_line(`C:\Tools\code.cmd`, `"C:\a b\x.md"`)
	testing.expect_value(t, err.kind, pty.Spawn_Error_Kind.None)
	defer delete(line)
	testing.expect(t, strings.has_suffix(line, `\cmd.exe" /d /s /c ""C:\Tools\code.cmd" "C:\a b\x.md""`), line)
}

@(test)
explicit_path_detection :: proc(t: ^testing.T) {
	cases := [?]struct {
		token:    string,
		explicit: bool,
	} {
		{"pwsh.exe", false},
		{"pwsh", false},
		{`C:\Windows\System32\cmd.exe`, true},
		{`C:/Windows/System32/cmd.exe`, true},
		{`C:relative`, true},
		{`.\shell.exe`, true},
		{`..\shell.exe`, true},
		{`\\server\share\shell.exe`, true},
		{"cmd.exe", false},
	}
	for c in cases {
		testing.expect_value(t, pty.is_explicit_path(c.token), c.explicit)
	}
}

@(test)
path_entries_must_be_absolute_and_outside_the_current_directory :: proc(t: ^testing.T) {
	cwd := `C:\Users\example\project`
	cases := [?]struct {
		entry, cwd: string,
		trusted:    bool,
	} {
		{`C:\Windows`, cwd, true},
		{`C:\Windows\`, cwd, true},
		{`c:\windows`, cwd, true},
		{`\\server\share\bin`, cwd, true},
		{`"C:\Program Files\PowerShell\7"`, cwd, true},
		{"", cwd, false},
		{".", cwd, false},
		{"..", cwd, false},
		{`bin`, cwd, false},
		{`..\bin`, cwd, false},
		{`C:relative`, cwd, false},
		{`C:\Users\example\project`, cwd, false},
		{`c:\users\example\project\`, cwd, false},
		{`C:\Users\example\project2`, cwd, true},
	}
	for c in cases {
		testing.expectf(
			t,
			pty.path_entry_trusted(c.entry, c.cwd) == c.trusted,
			"entry %q with cwd %q: expected trusted=%t",
			c.entry,
			c.cwd,
			c.trusted,
		)
	}
}

@(test)
resolve_executable_uses_given_directories :: proc(t: ^testing.T) {
	directories := [?]string{`C:\Windows`, `C:\Windows\System32`}
	path, err := pty.resolve_executable("cmd.exe /d /c echo", directories[:])
	testing.expect_value(t, err.kind, pty.Spawn_Error_Kind.None)
	defer delete(path)
	testing.expect(t, strings.has_suffix(path, `\System32\cmd.exe`), path)

	with_extension, extension_err := pty.resolve_executable("cmd", directories[:])
	testing.expect_value(t, extension_err.kind, pty.Spawn_Error_Kind.None)
	defer delete(with_extension)
	testing.expect(t, strings.has_suffix(with_extension, `\System32\cmd.exe`), with_extension)

	explicit := `C:\Windows\System32\cmd.exe /d`
	unchanged, explicit_err := pty.resolve_executable(explicit, nil)
	testing.expect_value(t, explicit_err.kind, pty.Spawn_Error_Kind.None)
	defer delete(unchanged)
	testing.expect_value(t, unchanged, `C:\Windows\System32\cmd.exe`)

	_, missing := pty.resolve_executable("aio_missing_executable_93820.exe", directories[:])
	testing.expect_value(t, missing.kind, pty.Spawn_Error_Kind.Start_Process)
	testing.expect_value(t, missing.os_code, 2)
}

@(test)
working_directories_stay_local :: proc(t: ^testing.T) {
	cases := [?]struct {
		path:  string,
		local: bool,
	} {
		{`C:\Windows`, true},
		{`C:/Windows`, true},
		{`C:\`, true},
		{`.`, true},
		{`..`, true},
		{`C:\aio_missing_directory_93820`, false},
		{`C:\Windows\System32\cmd.exe`, false},
		{`\\server\share`, false},
		{`//server/share`, false},
		{`\\?\C:\Windows`, false},
		{`\\.\C:\Windows`, false},
		{`\??\C:\Windows`, false},
		{`\\?\UNC\server\share`, false},
		{`C:relative`, false},
		{`C:`, false},
	}
	for c in cases {
		testing.expectf(
			t,
			pty.working_directory_is_local(c.path) == c.local,
			"%q: expected local=%t",
			c.path,
			c.local,
		)
	}
}

@(test)
search_directories_are_absolute :: proc(t: ^testing.T) {
	directories, err := pty.search_directories(context.allocator)
	testing.expect_value(t, err, nil)
	defer {
		for directory in directories {delete(directory, context.allocator)}
		delete(directories, context.allocator)
	}
	testing.expect(t, len(directories) > 0)
	for directory in directories {
		testing.expectf(
			t,
			pty.path_entry_trusted(directory, ""),
			"search directory %q is not absolute",
			directory,
		)
	}
}
