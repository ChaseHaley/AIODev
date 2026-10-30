package aioctl_test

import "base:runtime"
import "core:testing"
import "aio:settings"
import ctl "../../tools/aioctl"

@(test)
defaults_and_options :: proc(t: ^testing.T) {
	o, err := ctl.parse_options({"launch"})
	testing.expect_value(t, err, "")
	testing.expect_value(t, o.name, "verify")
	testing.expect_value(t, o.shell, "")
	testing.expect_value(t, o.columns, 120)
	testing.expect_value(t, o.rows, 32)
	o, err = ctl.parse_options({"--name", "test_1-X", "launch", "--fresh", "--shell", "cmd.exe",
		"--size", "80x24", "--keep-env", "--keep-layout"})
	testing.expect_value(t, err, "")
	testing.expect_value(t, o.name, "test_1-X")
	testing.expect_value(t, o.shell, "cmd.exe")
	testing.expect_value(t, o.columns, 80)
	testing.expect_value(t, o.rows, 24)
	testing.expect(t, o.fresh && o.keep_env && o.keep_layout)
	for args in ([][]string{{"help"}, {"help", "launch"}, {"doctor"}, {"stop"},
		{"launch", "--settings", "x.ini", "--fresh"}, {"key", "Ctrl+Shift+P"},
		{"wait", "text", "PS ", "--timeout", "100"}, {"type", ""}, {"type", "é漢😀"},
		{"launch", "--size", "1x1000"}, {"unknown"}, {"key", "badkey"}, {"wait", "text"}}) {
		_, parse_error := ctl.parse_options(args)
		testing.expect_value(t, parse_error, "")
	}
}

@(test)
signed_screen_positions_remain_one_shell_argument :: proc(t: ^testing.T) {
	for args in ([][]string{{"window", "move", "-100,200"},
		{"mouse", "move", "-100,200", "--screen"},
		{"mouse", "drag", "-100,200", "300,-400", "--screen"}}) {
		_, err := ctl.parse_options(args)
		testing.expect_value(t, err, "")
	}
	for args in ([][]string{{"window", "move", "-100", "200"},
		{"mouse", "move", "-100", "200", "--screen"},
		{"mouse", "drag", "-100,200", "300", "-400", "--screen"}}) {
		_, err := ctl.parse_options(args)
		testing.expect(t, err != "")
	}
}

@(test)
usage_errors :: proc(t: ^testing.T) {
	for args in ([][]string{nil, {"--name"}, {"--name", ""}, {"--name", "../owner", "stop"},
		{"--name", "default/", "launch"}, {"launch", "--unknown"}, {"launch", "--size"},
		{"launch", "--size", "0x32"}, {"launch", "--size", "1001x32"},
		{"launch", "--size", "1x-1"}, {"launch", "--size", "1x2x3"},
		{"launch", "--size", "99999999999999999999999x2"},
		{"launch", "--fresh", "--fresh"}, {"launch", "--keep-env", "--keep-env"},
		{"launch", "--keep-layout", "--keep-layout"},
		{"launch", "--shell", "x", "--shell", "y"}, {"launch", "--shell", ""},
		{"launch", "--shell", "bad\nvalue"}, {"launch", "--shell", "\xff"},
		{"launch", "--settings", "x", "--size", "1x2"},
		{"launch", "--settings", "x", "--shell", "x"},
		{"launch", "--settings", "--fresh"}, {"launch", "--name", "x"},
		{"doctor", "extra"}, {"stop", "extra"}, {"help", "x", "y"}}) {
		_, err := ctl.parse_options(args)
		testing.expect(t, err != "")
	}
}

@(test)
data_directory_boundaries :: proc(t: ^testing.T) {
	repo :: `C:\repo`
	testing.expect(t, ctl.safe_data_path(repo, `C:\repo\build\verify\verify`, "verify"))
	testing.expect(t, ctl.safe_data_path(repo, `c:\REPO\BUILD\verify\TEST`, "test"))
	for path in ([]string{`C:\repo`, `C:\repo\build\verify`, `C:\repo\build\verify\`,
		`C:\repo\build\verify\verify\..`, `C:\repo\build\verify\verify\child`,
		`C:\repo\build\verify\verify2`, `C:\repo\build\verify2\verify`,
		`C:\repo2\build\verify\verify`, `D:\repo\build\verify\verify`,
		`C:\repo\build\verify\..\verify`, `C:/repo/build/verify/verify`}) {
		testing.expect(t, !ctl.safe_data_path(repo, path, "verify"))
	}
	for name in ([]string{"", ".", "..", "a/b", `a\b`, "a:", "a ", "a.", "\x00"}) {
		testing.expect(t, !ctl.safe_data_path(repo, `C:\repo\build\verify\verify`, name))
	}
	testing.expect(t, !ctl.safe_data_path("relative", `relative\build\verify\verify`, "verify"))
}

@(test)
generated_settings :: proc(t: ^testing.T) {
	o, err := ctl.parse_options({"launch", "--shell", `pwsh -Command "Write-Host 'x'"`, "--size", "90x20"})
	testing.expect_value(t, err, "")
	text, ok := ctl.settings_text(o, `C:\repo with spaces\data`, `C:\verify`)
	defer delete(text)
	testing.expect(t, ok)
	s, diagnostics, parse_error := settings.parse(text)
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&diagnostics)
	testing.expect_value(t, parse_error, runtime.Allocator_Error.None)
	testing.expect_value(t, len(diagnostics), 0)
	testing.expect_value(t, s.shell.command, o.shell)
	testing.expect_value(t, s.shell.directory, `C:\repo with spaces\data`)
	testing.expect_value(t, s.font.family, "Cascadia Mono")
	testing.expect_value(t, s.cursor.blink, false)
	testing.expect_value(t, s.window.columns, 90)
	testing.expect_value(t, s.window.rows, 20)
	for shell in ([]string{`"C:\Program Files\pwsh.exe"`, `"C:\Program Files\pwsh.exe" -NoProfile`,
		" cmd.exe ", "pwsh -Command \"a=b\""}) {
		custom := o
		custom.shell = shell
		generated, valid := ctl.settings_text(custom, `C:\repo`, `C:\verify`)
		defer delete(generated)
		testing.expect(t, valid)
		parsed, issues, error := settings.parse(generated)
		defer settings.destroy(&parsed)
		defer settings.diagnostics_destroy(&issues)
		testing.expect_value(t, error, runtime.Allocator_Error.None)
		testing.expect_value(t, len(issues), 0)
		testing.expect_value(t, parsed.shell.command, shell)
	}
	for bad in ([]ctl.Options{{}, {shell = "x", columns = 0, rows = 1},
		{shell = "x", columns = 1, rows = 1001}, {shell = "x\nkey=true", columns = 1, rows = 1}}) {
		result, valid := ctl.settings_text(bad, `C:\repo`, `C:\verify`)
		defer delete(result)
		testing.expect(t, !valid)
	}
}

@(private)
fail_allocation :: proc(_: rawptr, _: runtime.Allocator_Mode, _, _: int,
	_: rawptr, _: int, _ := #caller_location) -> ([]u8, runtime.Allocator_Error) {
	return nil, .Out_Of_Memory
}

@(test)
default_history_settings :: proc(t: ^testing.T) {
	for item in ([]struct { directory, command: string }{
		{`C:\verify`, `pwsh -NoLogo -NoProfile -NoExit -Command `+
			`"Set-PSReadLineOption -HistorySavePath 'C:\verify\history.txt' -PredictionSource None"`},
		{`C:\owner's repo\é漢`, `pwsh -NoLogo -NoProfile -NoExit -Command `+
			`"Set-PSReadLineOption -HistorySavePath 'C:\owner''s repo\é漢\history.txt' `+
			`-PredictionSource None"`},
		{`C:\a''b`, `pwsh -NoLogo -NoProfile -NoExit -Command `+
			`"Set-PSReadLineOption -HistorySavePath 'C:\a''''b\history.txt' -PredictionSource None"`},
	}) {
		for args in ([][]string{{"launch"}, {"launch", "--keep-env"}}) {
			o, error := ctl.parse_options(args)
			testing.expect_value(t, error, "")
			text, ok := ctl.settings_text(o, `C:\repo`, item.directory)
			defer delete(text)
			if !testing.expect(t, ok) { continue }
			s, diagnostics, parse_error := settings.parse(text)
			defer settings.destroy(&s)
			defer settings.diagnostics_destroy(&diagnostics)
			testing.expect_value(t, parse_error, runtime.Allocator_Error.None)
			testing.expect_value(t, len(diagnostics), 0)
			testing.expect_value(t, s.shell.command, item.command)
		}
	}
	o, error := ctl.parse_options({"launch"})
	testing.expect_value(t, error, "")
	for directory in ([]string{"", "bad\rpath", "bad\npath", "bad\x00path", "bad\"path", "\xff"}) {
		text, ok := ctl.settings_text(o, `C:\repo`, directory)
		defer delete(text)
		testing.expect(t, !ok)
	}
}

@(test)
settings_allocation_failure :: proc(t: ^testing.T) {
	o, err := ctl.parse_options({"launch"})
	testing.expect_value(t, err, "")
	text, ok := ctl.settings_text(o, `C:\repo`, `C:\verify`,
		runtime.Allocator{procedure = fail_allocation})
	testing.expect(t, !ok)
	testing.expect_value(t, text, "")
}

@(test)
record_validation :: proc(t: ^testing.T) {
	text :: "pid=123\ncreated=456\nexecutable=C:\\repo\\build\\aiodev-verify.exe\nno_color=removed\n"
	r, ok := ctl.parse_record(text)
	testing.expect(t, ok)
	testing.expect_value(t, r.pid, 123)
	testing.expect_value(t, r.created, 456)
	testing.expect_value(t, r.executable, `C:\repo\build\aiodev-verify.exe`)
	testing.expect(t, !r.keep_env)
	r, ok = ctl.parse_record("pid=1\r\ncreated=2\r\nexecutable=x\r\nno_color=kept\r\n")
	testing.expect(t, ok && r.keep_env)
	testing.expect_value(t, r.history, ctl.History.Unknown)
	r, ok = ctl.parse_record("pid=1\ncreated=2\nexecutable=x\nno_color=kept\nhistory=isolated\n")
	testing.expect(t, ok && r.keep_env)
	testing.expect_value(t, r.history, ctl.History.Isolated)
	r, ok = ctl.parse_record("pid=1\ncreated=2\nexecutable=x\nno_color=removed\nhistory=custom-shell\n")
	testing.expect(t, ok)
	testing.expect_value(t, r.history, ctl.History.Custom_Shell)
	r, ok = ctl.parse_record("pid=1\ncreated=2\nexecutable=x\nno_color=removed\nhistory=settings-file\n")
	testing.expect(t, ok)
	testing.expect_value(t, r.history, ctl.History.Settings_File)
	for bad in ([]string{"", "pid=1", "pid=0\ncreated=1\nexecutable=x\nno_color=removed",
		"pid=4294967296\ncreated=1\nexecutable=x\nno_color=removed",
		"pid=1\ncreated=0\nexecutable=x\nno_color=removed",
		"pid=1\ncreated=1\nexecutable=\nno_color=removed",
		"pid=1\ncreated=1\nexecutable=x\nno_color=maybe",
		"pid=1\npid=2\ncreated=1\nexecutable=x\nno_color=removed",
		"pid=1\ncreated=1\nexecutable=x\nno_color=removed\nunknown=x",
		"pid=1\ncreated=1\nexecutable=x\nno_color=removed\nhistory=",
		"pid=1\ncreated=1\nexecutable=x\nno_color=removed\nhistory=on",
		"pid=1\ncreated=1\nexecutable=x\nno_color=removed\nhistory=isolated\nhistory=custom-shell"}) {
		_, valid := ctl.parse_record(bad)
		testing.expect(t, !valid)
	}
}

@(test)
response_fields :: proc(t: ^testing.T) {
	text :: `pid="123" app="AIODev.verify" build="abc123+dirty" data="C:\\repo with spaces"`
	for field in ([]struct { key, value: string }{
		{"pid", "123"}, {"app", "AIODev.verify"}, {"build", "abc123+dirty"},
		{"data", `C:\repo with spaces`},
	}) {
		value, ok := ctl.response_field(text, field.key)
		defer delete(value)
		testing.expect(t, ok)
		testing.expect_value(t, value, field.value)
	}
	for bad in ([]string{"", "app", `app="unterminated`, `app="bad\`, `app="bad\q"`}) {
		value, ok := ctl.response_field(bad, "app")
		defer delete(value)
		testing.expect(t, !ok)
	}
	value, ok := ctl.response_field("build=abc", "build")
	defer delete(value)
	testing.expect(t, ok)
	testing.expect_value(t, value, "abc")
	missing, found := ctl.response_field(text, "missing")
	defer delete(missing)
	testing.expect(t, !found)
	failed, allocated := ctl.response_field(text, "app", runtime.Allocator{procedure = fail_allocation})
	testing.expect(t, !allocated)
	testing.expect_value(t, failed, "")
}

@(test)
powershell_split_positions :: proc(t: ^testing.T) {
	for args in ([][]string{{"expect", "cursor", "5", "4"},
		{"expect", "cell", "5", "4", "text=x"}, {"mouse", "move", "5", "4"},
		{"mouse", "down", "5", "4"}, {"mouse", "up", "5", "4"},
		{"mouse", "click", "5", "4"}, {"mouse", "wheel", "5", "4", "-1"},
		{"mouse", "drag", "5", "4", "6,7"}, {"mouse", "drag", "5,4", "6", "7"}}) {
		_, error := ctl.parse_options(args)
		testing.expect_value(t, error,
			"quote the position in PowerShell, e.g. '5,4', as one col,row argument")
	}
	for args in ([][]string{{"expect", "cursor", "5,4"},
		{"expect", "cell", "5,4", "text=x"}, {"mouse", "move", "5,4"},
		{"mouse", "drag", "5,4", "6,7"}, {"mouse", "wheel", "5,4", "2"},
		{"type", "5", "4"}, {"cells", "5", "4"}, {"mouse", "unknown", "5", "4"},
		{"expect", "state", "5", "4"}, {"mouse", "move", "5", "--px"}}) {
		_, error := ctl.parse_options(args)
		testing.expect_value(t, error, "")
	}
}

@(test)
response_newlines :: proc(t: ^testing.T) {
	for item in ([]struct { text, body: string }{
		{"", ""}, {"one", "one"}, {"one\n", "one"}, {"one\n\n", "one"},
		{"one\r\n", "one"}, {"one\ntwo\n", "one\ntwo"},
		{"one  \n", "one  "}, {"\r\n\n", ""},
	}) {
		testing.expect_value(t, ctl.response_body(item.text), item.body)
	}
}
