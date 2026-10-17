package instance_test

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:testing"
import w "core:sys/windows"
import "aio:instance"

// Probe Unicode arguments before the test runner parses the CRT's ANSI argv.
@(init)
command_line_child :: proc "contextless" () {
	context = runtime.default_context()
	args, err := instance.command_line(context.allocator)
	if err != .None { return }
	if len(args) == 0 || args[0] != "--instance-command-line-test" {
		instance.command_line_destroy(args, context.allocator)
		return
	}
	expected := [?]string{"--instance-command-line-test", "é漢", "a b", "", `C:\é漢\`, `quote"end`, "😀"}
	code := 0
	if len(args) != len(expected) {
		code = 1
	} else {
		for arg, i in args { if arg != expected[i] { code = 1 } }
	}
	instance.command_line_destroy(args, context.allocator)
	failed, failure := instance.command_line(runtime.Allocator{procedure = fail_allocation})
	if failure != .Out_Of_Memory || len(failed) != 0 { code = 1 }
	os.exit(code)
}

@(test)
unicode_command_line :: proc(t: ^testing.T) {
	args, err := instance.command_line(context.allocator)
	if !testing.expect_value(t, err, instance.Error.None) { return }
	instance.command_line_destroy(args, context.allocator)
	executable, path_error := os.get_executable_path(context.allocator)
	if !testing.expect(t, path_error == nil) { return }
	defer delete(executable)
	line := fmt.aprintf(`"%s" --instance-command-line-test é漢 "a b" "" ` +
		`"C:\é漢\\" "quote\"end" 😀`, executable)
	defer delete(line)
	wide := w.utf8_to_wstring(line, context.allocator)
	if !testing.expect(t, wide != nil) { return }
	defer delete(wide)
	startup := w.STARTUPINFOW{cb = size_of(w.STARTUPINFOW)}
	process: w.PROCESS_INFORMATION
	if !testing.expect(t, bool(w.CreateProcessW(nil, wide, nil, nil, false,
		w.CREATE_NO_WINDOW, nil, nil, &startup, &process))) { return }
	defer testing.expect(t, bool(w.CloseHandle(process.hProcess)))
	defer testing.expect(t, bool(w.CloseHandle(process.hThread)))
	result := w.WaitForSingleObject(process.hProcess, 5000)
	if !testing.expect_value(t, result, u32(w.WAIT_OBJECT_0)) {
		testing.expect(t, bool(w.TerminateProcess(process.hProcess, 1)))
		testing.expect_value(t, w.WaitForSingleObject(process.hProcess, 5000), u32(w.WAIT_OBJECT_0))
		return
	}
	code: u32
	testing.expect(t, bool(w.GetExitCodeProcess(process.hProcess, &code)))
	testing.expect_value(t, code, u32(0))
}
