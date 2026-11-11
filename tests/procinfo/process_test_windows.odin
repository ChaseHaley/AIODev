package procinfo_test

import "core:strings"
import "core:testing"
import "core:time"
import w "core:sys/windows"
import "aio:procinfo"

// The tree of a running shell lists what a full snapshot lists below it, in the same order.
@(test)
process_tree_matches_the_snapshot_below_its_roots :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	command := w.utf8_to_wstring(`C:\Windows\System32\cmd.exe /d /c "ping -n 6 127.0.0.1 >nul"`)
	startup := w.STARTUPINFOW{cb = size_of(w.STARTUPINFOW)}
	info: w.PROCESS_INFORMATION
	flags := u32(w.CREATE_NO_WINDOW)
	created := w.CreateProcessW(nil, command, nil, nil, false, flags, nil, nil, &startup, &info)
	if !testing.expect(t, bool(created)) {return}
	defer {
		w.TerminateProcess(info.hProcess, 1)
		w.CloseHandle(info.hProcess)
		w.CloseHandle(info.hThread)
	}
	shell := info.dwProcessId
	// Once ping runs, the processes below the shell stay put until it ends five seconds later.
	pinging := false
	for started := time.tick_now(); !pinging && time.tick_since(started) < 10 * time.Second; {
		listed, err := procinfo.process_tree({shell}, context.temp_allocator)
		if !testing.expect_value(t, err, procinfo.Error.None) {return}
		for p in listed {pinging ||= strings.equal_fold(p.executable, "PING.EXE")}
		if !pinging {time.sleep(10 * time.Millisecond)}
	}
	if !testing.expect(t, pinging, "the shell started ping") {return}
	snapshot, err := procinfo.process_snapshot(context.temp_allocator)
	if !testing.expect_value(t, err, procinfo.Error.None) {return}
	tree, tree_err := procinfo.process_tree({shell}, context.temp_allocator)
	if !testing.expect_value(t, tree_err, procinfo.Error.None) {return}
	below := make([dynamic]procinfo.Process_Info, context.temp_allocator)
	for p in snapshot {
		current := p.id
		for _ in 0 ..< 16 {
			if current == shell {append(&below, p); break}
			parent := current
			for q in snapshot {if q.id == current {parent = q.parent; break}}
			if parent == current || parent == 0 {break}
			current = parent
		}
	}
	if !testing.expect_value(t, len(tree), len(below)) {return}
	for p, i in tree {
		testing.expect_value(t, p.id, below[i].id)
		testing.expect_value(t, p.parent, below[i].parent)
		testing.expect(t, strings.equal_fold(p.executable, below[i].executable), p.executable)
	}
}

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
