package pty_test

import "aio:pty"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import w "core:sys/windows"

expected_failure :: proc(options: pty.Spawn_Options) -> (pty.Pty, pty.Spawn_Error) {
	context.logger = {}
	return pty.spawn(options)
}

Run :: struct {
	p: pty.Pty,
	reader, waiter: ^thread.Thread,
	mutex: sync.Mutex,
	output: [32768]u8,
	length: int,
	read_error, wait_error: pty.Error,
	code: u32,
}

read_output :: proc(t: ^thread.Thread) {
	r := cast(^Run)t.data
	buffer: [4096]u8
	for {
		n, err := pty.read(&r.p, buffer[:])
		if err != .None {
			r.read_error = err
			return
		}
		sync.mutex_lock(&r.mutex)
		r.length += copy(r.output[r.length:], buffer[:n])
		sync.mutex_unlock(&r.mutex)
	}
}

wait_process :: proc(t: ^thread.Thread) {
	r := cast(^Run)t.data
	r.code, r.wait_error = pty.wait_exit(&r.p)
	pty.close_console(&r.p)
}

start :: proc(t: ^testing.T, r: ^Run, command: string, environment: []pty.Env_Var = nil, path_append := "") -> bool {
	testing.set_fail_timeout(t, 40 * time.Second)
	p, err := pty.spawn({
		command_line = command,
		working_directory = "C:\\Windows\\System32",
		environment = environment,
		path_append = path_append,
		cols = 80,
		rows = 25,
	})
	if !testing.expect_value(t, err.kind, pty.Spawn_Error_Kind.None) {
		return false
	}
	r.p = p
	r.reader = thread.create(read_output)
	if r.reader == nil {
		testing.expect(t, false, "thread creation failed")
		pty.destroy(&r.p)
		return false
	}
	r.reader.data = r
	thread.start(r.reader)
	r.waiter = thread.create(wait_process)
	if r.waiter == nil {
		testing.expect(t, false, "thread creation failed")
		testing.expect_value(t, pty.terminate(&r.p), pty.Error.None)
		pty.close_console(&r.p)
		finish(t, r)
		return false
	}
	r.waiter.data = r
	thread.start(r.waiter)
	return true
}

finish :: proc(t: ^testing.T, r: ^Run) {
	if r.waiter != nil {
		status := w.WaitForSingleObject(r.waiter.win32_thread, 15000)
		if status != w.WAIT_OBJECT_0 {
			testing.expect(t, false, "process timed out")
			testing.expect_value(t, pty.terminate(&r.p), pty.Error.None)
			status = w.WaitForSingleObject(r.waiter.win32_thread, 5000)
		}
		if testing.expect_value(t, status, w.WAIT_OBJECT_0) {
			thread.join(r.waiter)
			thread.destroy(r.waiter)
			r.waiter = nil
		}
	}
	if r.reader != nil {
		if testing.expect_value(t, w.WaitForSingleObject(r.reader.win32_thread, 5000), w.WAIT_OBJECT_0) {
			thread.join(r.reader)
			thread.destroy(r.reader)
			r.reader = nil
		}
	}
	testing.expect_value(t, r.wait_error, pty.Error.None)
	testing.expect_value(t, r.read_error, pty.Error.Closed)
	pty.destroy(&r.p)
	pty.destroy(&r.p)
}

contains :: proc(r: ^Run, text: string) -> bool {
	sync.mutex_lock(&r.mutex)
	defer sync.mutex_unlock(&r.mutex)
	return strings.contains(string(r.output[:r.length]), text)
}

await_output :: proc(t: ^testing.T, r: ^Run, text: string) -> bool {
	deadline := time.tick_now()
	for time.tick_since(deadline) < 10 * time.Second {
		if contains(r, text) {
			return true
		}
		time.sleep(time.Millisecond * 5)
	}
	testing.expect(t, false, "output timed out")
	return false
}

@(test)
output_and_exit :: proc(t: ^testing.T) {
	r: Run
	if !start(t, &r, "C:\\Windows\\System32\\cmd.exe /d /c \"echo AIO_OUTPUT&exit /b 37\"") {
		return
	}
	finish(t, &r)
	testing.expect_value(t, r.code, 37)
	testing.expect(t, contains(&r, "AIO_OUTPUT"))
	testing.expect(t, contains(&r, "\x1b[?9001h"))
}

@(test)
spawn_errors :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	options := pty.Spawn_Options{
		command_line = "aio_missing_executable_93820.exe",
		working_directory = "C:\\Windows", cols = 80, rows = 25,
	}
	p, err := expected_failure(options)
	defer pty.destroy(&p)
	testing.expect_value(t, err.kind, pty.Spawn_Error_Kind.Start_Process)
	testing.expect_value(t, err.os_code, 2)
	message, message_err := pty.error_message(err, options)
	testing.expect_value(t, message_err, pty.Error.None)
	defer delete(message)
	testing.expect(t, strings.has_prefix(message, "Could not start \"aio_missing_executable_93820.exe\":" ))
	directories := [2]string{"C:\\aio_missing_directory_93820", "C:\\Windows\\System32\\cmd.exe"}
	for directory in directories {
		bad, dir_err := expected_failure({
			command_line = "cmd.exe", working_directory = directory, cols = 80, rows = 25,
		})
		testing.expect_value(t, dir_err.kind, pty.Spawn_Error_Kind.Invalid_Working_Directory)
		pty.destroy(&bad)
	}
	bad, arg_err := pty.spawn({command_line = "cmd.exe", working_directory = "C:\\Windows", cols = 0, rows = 25})
	testing.expect_value(t, arg_err.kind, pty.Spawn_Error_Kind.Invalid_Argument)
	pty.destroy(&bad)
}

@(test)
invalid_arguments_and_allocation :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	options := pty.Spawn_Options{
		command_line = "cmd.exe", working_directory = "C:\\Windows", cols = 80, rows = 25,
	}
	dimensions_to_test := [?]u16{0, 32768, 65535}
	for dimensions in dimensions_to_test {
		bad := options
		bad.cols = dimensions
		p, err := expected_failure(bad)
		testing.expect_value(t, err.kind, pty.Spawn_Error_Kind.Invalid_Argument)
		pty.destroy(&p)
	}
	commands := [?]string{"", "cmd.exe\x00 /c echo bad", "\xff"}
	for command in commands {
		bad := options
		bad.command_line = command
		p, err := expected_failure(bad)
		testing.expect_value(t, err.kind, pty.Spawn_Error_Kind.Invalid_Argument)
		pty.destroy(&p)
	}
	p, alloc_err := pty.spawn(options, mem.nil_allocator())
	testing.expect_value(t, alloc_err.kind, pty.Spawn_Error_Kind.Out_Of_Memory)
	pty.destroy(&p)
	message, message_err := pty.error_message({kind = .Out_Of_Memory}, options, mem.nil_allocator())
	testing.expect_value(t, message_err, pty.Error.Out_Of_Memory)
	testing.expect_value(t, message, "")
}

@(test)
drain_before_eof :: proc(t: ^testing.T) {
	r: Run
	if !start(t, &r, "cmd.exe /d /c \"(for /l %i in (1,1,700) do @echo DRAIN_%i)&echo DRAIN_COMPLETE\"") {
		return
	}
	finish(t, &r)
	testing.expect(t, contains(&r, "DRAIN_1"))
	testing.expect(t, contains(&r, "DRAIN_700"))
	testing.expect(t, contains(&r, "DRAIN_COMPLETE"))
}

@(test)
terminate_tree :: proc(t: ^testing.T) {
	r: Run
	command :: "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe -NoProfile -Command \"" +
		"$p = Start-Process -NoNewWindow -PassThru " +
		"C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe " +
		"-ArgumentList '-NoProfile -Command Start-Sleep -Seconds 120'; " +
		"[Console]::WriteLine('CHILD_READY'); Start-Sleep -Seconds 120\""
	if !start(t, &r, command) { return }
	if await_output(t, &r, "CHILD_READY") {
		snapshot := w.CreateToolhelp32Snapshot(w.TH32CS_SNAPPROCESS, 0)
		if testing.expect(t, snapshot != w.INVALID_HANDLE_VALUE) {
			defer testing.expect(t, bool(w.CloseHandle(snapshot)))
			entry := w.PROCESSENTRY32W{dwSize = size_of(w.PROCESSENTRY32W)}
			children: [16]w.HANDLE
			count := 0
			defer {
				for handle in children[:count] { testing.expect(t, bool(w.CloseHandle(handle))) }
			}
			found := bool(w.Process32FirstW(snapshot, &entry))
			for found {
				if entry.th32ParentProcessID == pty.process_id(&r.p) {
					if !testing.expect(t, count < len(children)) { break }
					handle := w.OpenProcess(w.SYNCHRONIZE, false, entry.th32ProcessID)
					if testing.expect(t, handle != nil) {
						children[count] = handle
						count += 1
					}
				}
				found = bool(w.Process32NextW(snapshot, &entry))
			}
			testing.expect_value(t, w.GetLastError(), w.ERROR_NO_MORE_FILES)
			testing.expect(t, count > 0)
			testing.expect_value(t, pty.terminate(&r.p), pty.Error.None)
			for handle in children[:count] {
				testing.expect_value(t, w.WaitForSingleObject(handle, 5000), w.WAIT_OBJECT_0)
			}
		}
	}
	finish(t, &r)
}

@(test)
environment :: proc(t: ^testing.T) {
	r: Run
	variables := [?]pty.Env_Var{
		{"AIO_TEST_VALUE", "first"},
		{"aio_test_value", "h\u00e9llo \u4e16\u754c"},
		{"AIO_TEST_EMPTY", ""},
	}
	command :: "cmd.exe /d /c \"echo %AIO_TEST_VALUE%&echo %SystemRoot%&" +
		"if defined AIO_TEST_EMPTY (echo BAD_EMPTY) else (echo EMPTY_OK)\""
	if !start(t, &r, command, variables[:]) {
		return
	}
	finish(t, &r)
	testing.expect(t, contains(&r, "h\u00e9llo \u4e16\u754c"))
	testing.expect(t, contains(&r, "Windows") || contains(&r, "WINDOWS"))
	testing.expect(t, contains(&r, "EMPTY_OK"))
	bad_variables := [?]pty.Env_Var{{"BAD=NAME", "x"}}
	p, err := pty.spawn({
		command_line = "cmd.exe",
		working_directory = "C:\\Windows",
		environment = bad_variables[:],
		cols = 80,
		rows = 25,
	})
	testing.expect_value(t, err.kind, pty.Spawn_Error_Kind.Invalid_Environment)
	pty.destroy(&p)
}

@(test)
path_append_ends_path :: proc(t: ^testing.T) {
	r: Run
	// The last 17 characters of PATH: the separator and the appended directory.
	if !start(t, &r, "cmd.exe /d /c \"echo TAIL[%PATH:~-17%]\"", nil, `C:\aio-path-test`) {
		return
	}
	finish(t, &r)
	testing.expect(t, contains(&r, `TAIL[;C:\aio-path-test]`))
}

@(test)
input_and_resize :: proc(t: ^testing.T) {
	r: Run
	command :: "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe -NoProfile -Command \"" +
		"[Console]::WriteLine('READY'); $line = [Console]::ReadLine(); " +
		"[Console]::WriteLine('ROUND:' + $line); " +
		"[Console]::WriteLine('SIZE:' + [Console]::WindowWidth + ':' + [Console]::WindowHeight)\""
	if !start(t, &r, command) {
		return
	}
	if await_output(t, &r, "READY") {
		testing.expect_value(t, pty.resize(&r.p, 100, 40), pty.Error.None)
		testing.expect_value(t, pty.write(&r.p, transmute([]u8)string("hello\r")), pty.Error.None)
	}
	finish(t, &r)
	testing.expect(t, contains(&r, "ROUND:hello"))
	testing.expect(t, contains(&r, "SIZE:100:40"))
	testing.expect_value(t, pty.resize(&r.p, 80, 25), pty.Error.Closed)
}

@(test)
closed_operations :: proc(t: ^testing.T) {
	p: pty.Pty
	buffer: [8]u8
	_, read_err := pty.read(&p, buffer[:])
	_, wait_err := pty.wait_exit(&p)
	testing.expect_value(t, read_err, pty.Error.Closed)
	testing.expect_value(t, wait_err, pty.Error.Closed)
	testing.expect_value(t, pty.write(&p, buffer[:]), pty.Error.Closed)
	testing.expect_value(t, pty.resize(&p, 1, 1), pty.Error.Closed)
	testing.expect_value(t, pty.resize(&p, 0, 1), pty.Error.Invalid_Argument)
	pty.close_console(&p)
	testing.expect_value(t, pty.terminate(&p), pty.Error.None)
	pty.destroy(&p)
}

// build.ps1 places the bundled ConPTY beside every executable, so consoles get grapheme widths (D-044).
@(test)
uses_bundled_conpty :: proc(t: ^testing.T) {
	testing.expect(t, pty.bundled_conpty(), "conpty.dll and OpenConsole.exe must sit beside the test executable")
}
