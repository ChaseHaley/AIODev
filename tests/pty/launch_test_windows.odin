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
