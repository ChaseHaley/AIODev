package spawn_test

import "aio:instance"
import "aio:spawn"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import w "core:sys/windows"
import "core:testing"
import "core:time"

// The test executable is also a deterministic native child, avoiding PowerShell and shell parsing
// in the quoting, chunk-boundary, full-duplex and process-tree tests.
@(init)
child_entry :: proc "contextless" () {
	context = runtime.default_context()
	args, error := instance.command_line(context.allocator)
	if error != .None {return}
	// A child process always ends in os.exit, so only the test runner's own path frees the arguments.
	if len(args) < 2 || args[0] != "--spawn-test-child" {
		instance.command_line_destroy(args, context.allocator)
		return
	}
	switch args[1] {
	case "arguments":
		expected := [?]string{"", "a b", "a\tb", `C:\a b\`, `quote"end`, `\\"`, "é漢😀"}
		if len(args) != len(expected) + 2 {os.exit(11)}
		for arg, index in expected {if args[index + 2] != arg {os.exit(12)}}
		child_write("quoted\r\n")
	case "environment":
		value, found := os.lookup_env("ONLY_CHILD", context.temp_allocator)
		if !found || value != "é漢" {os.exit(20)}
		_, removed := os.lookup_env("DELETE_CHILD", context.temp_allocator)
		if removed {os.exit(21)}
		_, inherited := os.lookup_env("PATH", context.temp_allocator)
		if inherited {os.exit(22)}
		unicode, unicode_found := os.lookup_env("名", context.temp_allocator)
		if !unicode_found || unicode != "値" {os.exit(23)}
		child_write("environment\r\n")
	case "handle":
		if len(args) != 3 {os.exit(24)}
		number, parsed := strconv.parse_uint(args[2], 10)
		if !parsed {os.exit(25)}
		// Handle values may be reused in the child. Signal it and inspect the original event
		// in the parent instead of assuming that the numeric value must be invalid.
		_ = w.SetEvent(cast(w.HANDLE)uintptr(number))
	case "crlf":
		child_write("a\r")
		input: u8
		count: w.DWORD
		if !bool(w.ReadFile(w.GetStdHandle(w.STD_INPUT_HANDLE), &input, 1, &count, nil)) || count != 1 {
			os.exit(13)
		}
		child_write("\nb\rc\r")
	case "duplex":
		buffer: [4096]u8
		for &value in buffer {value = 'o'}
		for _ in 0 ..< 32 {child_write(string(buffer[:]))}
		total := 0
		for {
			count: w.DWORD
			if !bool(w.ReadFile(w.GetStdHandle(w.STD_INPUT_HANDLE), &buffer[0], u32(len(buffer)), &count, nil)) || count == 0 {break}
			total += int(count)
		}
		if total != 128 * 1024 {os.exit(14)}
	case "tree":
		executable, path_error := os.get_executable_path(context.temp_allocator)
		if path_error != nil {os.exit(15)}
		line := fmt.tprintf(`"%s" --spawn-test-child sleep`, executable)
		wide := w.utf8_to_wstring(line, context.temp_allocator)
		if wide == nil {os.exit(16)}
		startup := w.STARTUPINFOW{
			cb = size_of(w.STARTUPINFOW), dwFlags = w.STARTF_USESTDHANDLES,
			hStdInput = w.GetStdHandle(w.STD_INPUT_HANDLE),
			hStdOutput = w.GetStdHandle(w.STD_OUTPUT_HANDLE),
			hStdError = w.GetStdHandle(w.STD_ERROR_HANDLE),
		}
		info: w.PROCESS_INFORMATION
		if !bool(w.CreateProcessW(nil, wide, nil, nil, true, w.CREATE_NO_WINDOW, nil, nil, &startup, &info)) {os.exit(17)}
		_ = w.CloseHandle(info.hThread)
		_ = w.CloseHandle(info.hProcess)
		child_write(fmt.tprintf("%d\n", info.dwProcessId))
		time.sleep(30 * time.Second)
	case "sleep":
		time.sleep(30 * time.Second)
	case:
		os.exit(18)
	}
	os.exit(0)
}

child_write :: proc(text: string) {
	offset := 0
	for offset < len(text) {
		count: w.DWORD
		if !bool(w.WriteFile(w.GetStdHandle(w.STD_OUTPUT_HANDLE), raw_data(text[offset:]), u32(len(text) - offset), &count, nil)) || count == 0 {os.exit(19)}
		offset += int(count)
	}
}

Collected :: struct {
	stdout, stderr: [dynamic]u8,
	code: int,
	exited: bool,
}

collect :: proc(t: ^testing.T, p: ^spawn.Process) -> Collected {
	result: Collected
	began := time.tick_now()
	for time.tick_since(began) < 8 * time.Second {
		output := spawn.poll(p)
		_, stdout_error := append(&result.stdout, ..output.stdout)
		_, stderr_error := append(&result.stderr, ..output.stderr)
		testing.expect(t, stdout_error == nil && stderr_error == nil)
		if output.exited {
			result.code, result.exited = output.code, true
			return result
		}
		time.sleep(time.Millisecond)
	}
	testing.expect(t, false, "child output or exit timed out")
	spawn.kill(p)
	return result
}

collected_destroy :: proc(result: ^Collected) {
	delete(result.stdout)
	delete(result.stderr)
}

run :: proc(t: ^testing.T, argv: []string, options: spawn.Options = {}) -> Collected {
	p, error := spawn.start(argv, options, {})
	if !testing.expect_value(t, error, spawn.Error.None) {return {}}
	defer spawn.destroy(p)
	testing.expect(t, spawn.pid(p) > 0)
	return collect(t, p)
}

@(test)
stdout_stderr_and_exit :: proc(t: ^testing.T) {
	cases := [?]struct {argv: []string, stdout, stderr: string, code: int}{
		{{"cmd.exe", "/d", "/c", "echo hi"}, "hi\n", "", 0},
		{{"cmd.exe", "/d", "/c", "exit 3"}, "", "", 3},
		{{"cmd.exe", "/d", "/c", "echo out&echo err>&2"}, "out\n", "err\n", 0},
	}
	for item in cases {
		result := run(t, item.argv)
		testing.expect(t, result.exited)
		testing.expect_value(t, string(result.stdout[:]), item.stdout)
		testing.expect_value(t, string(result.stderr[:]), item.stderr)
		testing.expect_value(t, result.code, item.code)
		collected_destroy(&result)
	}
}

@(test)
initial_and_kept_stdin :: proc(t: ^testing.T) {
	initial := run(t, {"findstr.exe", "x"}, {stdin = "x\r\nother\r\n"})
	defer collected_destroy(&initial)
	testing.expect_value(t, string(initial.stdout[:]), "x\n")
	testing.expect_value(t, initial.code, 0)
	p, error := spawn.start({"findstr.exe", "x"}, {stdin = "x first\r\n", keep_stdin = true}, {})
	if !testing.expect_value(t, error, spawn.Error.None) {return}
	defer spawn.destroy(p)
	testing.expect_value(t, spawn.write(p, transmute([]u8)string("x second\r\n")), spawn.Error.None)
	spawn.close_stdin(p)
	spawn.close_stdin(p)
	testing.expect_value(t, spawn.write(p, transmute([]u8)string("x closed\r\n")), spawn.Error.Closed)
	kept := collect(t, p)
	defer collected_destroy(&kept)
	testing.expect_value(t, string(kept.stdout[:]), "x first\nx second\n")
	testing.expect_value(t, kept.code, 0)
}

@(test)
environment_and_cwd :: proc(t: ^testing.T) {
	directory, directory_error := os.make_directory_temp("", "aio-spawn-*", context.allocator)
	if !testing.expect_value(t, directory_error, nil) {return}
	defer delete(directory)
	defer os.remove_all(directory)
	result := run(t, {"cmd.exe", "/d", "/c", "echo %AIO_SPAWN_TEST%"}, {
		env = {"AIO_SPAWN_TEST=old", "aio_spawn_test=changed"},
	})
	defer collected_destroy(&result)
	testing.expect_value(t, string(result.stdout[:]), "changed\n")
	cwd := run(t, {"cmd.exe", "/d", "/c", "cd"}, {cwd = directory})
	defer collected_destroy(&cwd)
	testing.expect(t, strings.equal_fold(strings.trim(string(cwd.stdout[:]), "\r\n"), directory))
	testing.expect_value(t, cwd.code, 0)
	executable, path_error := os.get_executable_path(context.allocator)
	if !testing.expect_value(t, path_error, nil) {return}
	defer delete(executable)
	cleared := run(t, {executable, "--spawn-test-child", "environment"}, {
		clear_env = true,
		env = {"ONLY_CHILD=é漢", "DELETE_CHILD=old", "delete_child=", "名=値"},
	})
	defer collected_destroy(&cleared)
	testing.expect_value(t, string(cleared.stdout[:]), "environment\n")
	testing.expect_value(t, cleared.code, 0)
}

@(test)
lookup_uses_child_path_and_pathext :: proc(t: ^testing.T) {
	missing, missing_error := spawn.start({"aio-spawn-no-such-program-96f27.exe"}, {}, {})
	testing.expect_value(t, missing_error, spawn.Error.Not_Found)
	testing.expect(t, missing == nil)
	spawn.destroy(missing)
	directory, directory_error := os.make_directory_temp("", "aio-spawn-path-*", context.allocator)
	if !testing.expect_value(t, directory_error, nil) {return}
	defer delete(directory)
	defer os.remove_all(directory)
	batch := fmt.tprintf("%s\\probe.cmd", directory)
	if !testing.expect_value(t, os.write_entire_file(batch, "@echo unsafe\r\n"), nil) {return}
	options := spawn.Options{clear_env = true, env = {fmt.tprintf("PATH=%s", directory), "PATHEXT=.CMD;.EXE"}}
	names := [?]string{"probe", "probe.cmd", batch}
	for name in names {
		p, error := spawn.start({name}, options, {})
		testing.expect(t, p == nil)
		testing.expect_value(t, error, spawn.Error.Not_Executable)
		spawn.destroy(p)
	}
	executable, path_error := os.get_executable_path(context.allocator)
	if !testing.expect_value(t, path_error, nil) {return}
	defer delete(executable)
	copy_path := fmt.tprintf("%s\\probe.exe", directory)
	if !testing.expect_value(t, os.copy_file(copy_path, executable), nil) {return}
	options.env = {fmt.tprintf("PATH=%s", directory), "PATHEXT=.EXE;.CMD"}
	result := run(t, {"probe", "--spawn-test-child", "arguments", "", "a b", "a\tb", `C:\a b\`, `quote"end`, `\\"`, "é漢😀"}, options)
	defer collected_destroy(&result)
	testing.expect_value(t, result.code, 0)
	testing.expect_value(t, string(result.stdout[:]), "quoted\n")
	// A path containing a separator is used directly, even with an empty child PATH.
	relative := run(t, {`.\probe.exe`, "--spawn-test-child", "arguments", "", "a b", "a\tb", `C:\a b\`, `quote"end`, `\\"`, "é漢😀"}, {
		cwd = directory, clear_env = true,
	})
	defer collected_destroy(&relative)
	testing.expect_value(t, relative.code, 0)
}

Wake_Count :: struct {count: i32}

on_wake :: proc "contextless" (data: rawptr) {
	counter := (^Wake_Count)(data)
	sync.atomic_add(&counter.count, 1)
}

@(test)
crlf_across_reads_and_wake :: proc(t: ^testing.T) {
	executable, path_error := os.get_executable_path(context.allocator)
	if !testing.expect_value(t, path_error, nil) {return}
	defer delete(executable)
	counter: Wake_Count
	p, error := spawn.start({executable, "--spawn-test-child", "crlf"}, {keep_stdin = true}, {
		procedure = on_wake, data = &counter,
	})
	if !testing.expect_value(t, error, spawn.Error.None) {return}
	defer spawn.destroy(p)
	began := time.tick_now()
	for sync.atomic_load(&counter.count) == 0 && time.tick_since(began) < 5 * time.Second {time.sleep(time.Millisecond)}
	first := spawn.poll(p)
	testing.expect_value(t, string(first.stdout), "a")
	testing.expect(t, !first.exited)
	testing.expect_value(t, spawn.write(p, transmute([]u8)string("x")), spawn.Error.None)
	spawn.close_stdin(p)
	result := collect(t, p)
	defer collected_destroy(&result)
	testing.expect_value(t, string(result.stdout[:]), "\nb\rc\r")
	testing.expect_value(t, result.code, 0)
	// Initial output, later output and exit each wake the host, even if EOF adds more wakes.
	began = time.tick_now()
	for sync.atomic_load(&counter.count) < 3 && time.tick_since(began) < time.Second {time.sleep(time.Millisecond)}
	testing.expect(t, sync.atomic_load(&counter.count) >= 3)
	preserved := run(t, {"cmd.exe", "/d", "/c", "echo hi"}, {keep_crlf = true})
	defer collected_destroy(&preserved)
	testing.expect_value(t, string(preserved.stdout[:]), "hi\r\n")
}

@(test)
large_initial_input_does_not_block_start :: proc(t: ^testing.T) {
	executable, path_error := os.get_executable_path(context.allocator)
	if !testing.expect_value(t, path_error, nil) {return}
	defer delete(executable)
	input := make([]u8, 128 * 1024)
	defer delete(input)
	for &value in input {value = 'i'}
	result := run(t, {executable, "--spawn-test-child", "duplex"}, {stdin = string(input)})
	defer collected_destroy(&result)
	testing.expect_value(t, result.code, 0)
	testing.expect_value(t, len(result.stdout), 128 * 1024)
	for value in result.stdout {if !testing.expect_value(t, value, u8('o')) {break}}
	discards := [?]spawn.Options{{discard_stdout = true}, {discard_stdout = true, discard_stderr = true}}
	for options in discards {
		discarded := run(t, {"cmd.exe", "/d", "/c", "echo hi"}, options)
		testing.expect_value(t, len(discarded.stdout), 0)
		testing.expect_value(t, discarded.code, 0)
		collected_destroy(&discarded)
	}
}

@(test)
kill_stops_running_process :: proc(t: ^testing.T) {
	p, error := spawn.start({"ping.exe", "-n", "30", "127.0.0.1"}, {}, {})
	if !testing.expect_value(t, error, spawn.Error.None) {return}
	defer spawn.destroy(p)
	testing.expect(t, spawn.running(p))
	began := time.tick_now()
	spawn.kill(p)
	testing.expect(t, time.tick_since(began) < 3 * time.Second)
	testing.expect(t, !spawn.running(p))
	result := collect(t, p)
	defer collected_destroy(&result)
	testing.expect(t, result.exited)
	spawn.kill(p)
}

@(test)
destroy_stops_descendants_and_joins_readers :: proc(t: ^testing.T) {
	executable, path_error := os.get_executable_path(context.allocator)
	if !testing.expect_value(t, path_error, nil) {return}
	defer delete(executable)
	p, error := spawn.start({executable, "--spawn-test-child", "tree"}, {}, {})
	if !testing.expect_value(t, error, spawn.Error.None) {return}
	defer if p != nil {spawn.destroy(p)}
	output: [dynamic]u8
	defer delete(output)
	began := time.tick_now()
	for time.tick_since(began) < 5 * time.Second {
		chunk := spawn.poll(p)
		_, append_error := append(&output, ..chunk.stdout)
		if !testing.expect_value(t, append_error, nil) {return}
		if strings.contains(string(output[:]), "\n") {break}
		time.sleep(time.Millisecond)
	}
	child_pid, parsed := strconv.parse_uint(strings.trim(string(output[:]), "\r\n"), 10)
	if !testing.expect(t, parsed && child_pid > 0) {return}
	child := w.OpenProcess(w.SYNCHRONIZE, false, u32(child_pid))
	if !testing.expect(t, child != nil) {return}
	defer w.CloseHandle(child)
	began = time.tick_now()
	spawn.destroy(p)
	p = nil
	testing.expect(t, time.tick_since(began) < 3 * time.Second)
	testing.expect_value(t, w.WaitForSingleObject(child, 1000), u32(w.WAIT_OBJECT_0))
	spawn.destroy(nil)
}

@(test)
unrelated_handles_are_not_inherited :: proc(t: ^testing.T) {
	attributes := w.SECURITY_ATTRIBUTES{nLength = size_of(w.SECURITY_ATTRIBUTES), bInheritHandle = true}
	event := w.CreateEventW(&attributes, true, false, nil)
	if !testing.expect(t, event != nil) {return}
	defer w.CloseHandle(event)
	executable, path_error := os.get_executable_path(context.allocator)
	if !testing.expect_value(t, path_error, nil) {return}
	defer delete(executable)
	result := run(t, {executable, "--spawn-test-child", "handle", fmt.tprintf("%d", uintptr(event))})
	defer collected_destroy(&result)
	testing.expect_value(t, result.code, 0)
	testing.expect_value(t, w.WaitForSingleObject(event, 0), u32(w.WAIT_TIMEOUT))
}
