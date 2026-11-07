package procinfo_test

import "core:testing"
import w "core:sys/windows"
import "aio:procinfo"

@(test)
process_snapshot_contains_current_process :: proc(t: ^testing.T) {
	snapshot, err := procinfo.process_snapshot()
	if !testing.expect_value(t, err, procinfo.Error.None) { return }
	defer procinfo.process_snapshot_destroy(snapshot)
	index := procinfo.process_leaf(snapshot, w.GetCurrentProcessId())
	if testing.expect(t, index >= 0) { testing.expect(t, snapshot[index].executable != "") }
}

@(test)
process_image_names_live_descendants_only :: proc(t: ^testing.T) {
	current := w.GetCurrentProcessId()
	path, ok := procinfo.process_image(current, current)
	if testing.expect(t, ok) {
		defer delete(path)
		testing.expect(t, len(path) > 3 && path[1] == ':', "a full image path")
	}
	// The parent was created before this process, so it cannot be its descendant.
	snapshot, err := procinfo.process_snapshot(context.temp_allocator)
	if !testing.expect_value(t, err, procinfo.Error.None) {return}
	for p in snapshot {
		if p.id != current {continue}
		parent_path, parent_ok := procinfo.process_image(p.parent, current)
		testing.expect(t, !parent_ok)
		delete(parent_path)
	}
	_, missing := procinfo.process_image(0xFFFFFFF0, current)
	testing.expect(t, !missing)
}

@(test)
process_directory_reads_a_child_directory_and_keeps_drive_roots :: proc(t: ^testing.T) {
	current := w.GetCurrentProcessId()
	for directory in ([?]string{`C:\Windows\System32`, `C:\`}) {
		startup := w.STARTUPINFOW{cb = size_of(w.STARTUPINFOW)}
		info: w.PROCESS_INFORMATION
		command := w.utf8_to_wstring("cmd.exe /d /c ping -n 30 127.0.0.1 >nul", context.temp_allocator)
		if !testing.expect(t, bool(w.CreateProcessW(nil, command, nil, nil, false, w.CREATE_NO_WINDOW, nil,
			   w.utf8_to_wstring(directory, context.temp_allocator), &startup, &info))) {return}
		path, ok := procinfo.process_directory(info.dwProcessId, current, context.temp_allocator)
		w.TerminateProcess(info.hProcess, 0)
		w.CloseHandle(info.hThread)
		w.CloseHandle(info.hProcess)
		testing.expect(t, ok)
		testing.expect_value(t, path, directory)
	}
	// Processes that are not descendants are refused, as for process_image.
	_, missing := procinfo.process_directory(0xFFFFFFF0, current, context.temp_allocator)
	testing.expect(t, !missing)
}
