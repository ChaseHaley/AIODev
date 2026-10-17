package aioctl_test

import "core:fmt"
import "core:os"
import "core:testing"
import w "core:sys/windows"
import ctl "../../tools/aioctl"

@(private)
close_test_handle :: proc(t: ^testing.T, handle: ^w.HANDLE) {
	if handle^ == nil || handle^ == w.INVALID_HANDLE_VALUE { return }
	testing.expect(t, bool(w.CloseHandle(handle^)))
	handle^ = nil
}

@(test)
redirected_child_excludes_caller_pipe :: proc(t: ^testing.T) {
	sa := w.SECURITY_ATTRIBUTES{nLength = size_of(w.SECURITY_ATTRIBUTES), bInheritHandle = true}
	caller_read, caller_write, output_read, output_write: w.HANDLE
	defer close_test_handle(t, &caller_read)
	defer close_test_handle(t, &caller_write)
	defer close_test_handle(t, &output_read)
	defer close_test_handle(t, &output_write)
	if !testing.expect(t, bool(w.CreatePipe(&caller_read, &caller_write, &sa, 0))) { return }
	if !testing.expect(t, bool(w.CreatePipe(&output_read, &output_write, &sa, 0))) { return }
	input := w.CreateFileW(w.L("NUL"), w.GENERIC_READ, w.FILE_SHARE_READ | w.FILE_SHARE_WRITE,
		&sa, w.OPEN_EXISTING, w.FILE_ATTRIBUTE_NORMAL, nil)
	if !testing.expect(t, input != w.INVALID_HANDLE_VALUE) { return }
	defer close_test_handle(t, &input)
	executable, found := os.lookup_env("COMSPEC", context.allocator)
	if !testing.expect(t, found) { return }
	defer delete(executable)
	directory, directory_error := os.get_working_directory(context.allocator)
	if !testing.expect(t, directory_error == nil) { return }
	defer delete(directory)
	buffer: [32768]u8
	command := fmt.bprintf(buffer[:], "\"%s\" /d /c exit 0", executable)
	child, ok := ctl.spawn_redirected(executable, command, directory, nil, input, output_write)
	if !testing.expect(t, ok) { return }
	defer close_test_handle(t, &child.hProcess)
	defer close_test_handle(t, &child.hThread)
	defer {
		testing.expect(t, bool(w.TerminateProcess(child.hProcess, 0)))
		testing.expect_value(t, w.WaitForSingleObject(child.hProcess, 5000), w.WAIT_OBJECT_0)
	}
	close_test_handle(t, &caller_write)
	close_test_handle(t, &output_write)
	testing.expect_value(t, w.WaitForSingleObject(child.hProcess, 0), w.WAIT_TIMEOUT)
	peek := w.PeekNamedPipe(caller_read, nil, 0, nil, nil, nil)
	code := w.GetLastError()
	testing.expect(t, !bool(peek))
	testing.expect_value(t, code, w.ERROR_BROKEN_PIPE)
	testing.expect(t, bool(w.PeekNamedPipe(output_read, nil, 0, nil, nil, nil)))
}
