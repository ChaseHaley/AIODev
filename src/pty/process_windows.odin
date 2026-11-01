package pty

import "core:log"
import w "core:sys/windows"

@(require_results)
process_snapshot :: proc(allocator := context.allocator) -> ([]Process_Info, Error) {
	handle := w.CreateToolhelp32Snapshot(w.TH32CS_SNAPPROCESS, 0)
	if handle == w.INVALID_HANDLE_VALUE {
		log.errorf("CreateToolhelp32Snapshot failed: %v", w.GetLastError())
		return nil, .Read
	}
	defer if !bool(w.CloseHandle(handle)) {log.errorf("CloseHandle failed: %v", w.GetLastError())}
	list := make([dynamic]Process_Info, allocator)
	success := false
	defer if !success {
		for p in list {delete(p.executable, allocator)}
		delete(list)
	}
	entry := w.PROCESSENTRY32W {
		dwSize = size_of(w.PROCESSENTRY32W),
	}
	if !bool(w.Process32FirstW(handle, &entry)) {
		log.errorf("Process32FirstW failed: %v", w.GetLastError())
		return nil, .Read
	}
	for {
		length := 0
		for length < len(entry.szExeFile) && entry.szExeFile[length] != 0 {length += 1}
		name, conversion_error := w.utf16_to_utf8(entry.szExeFile[:length], allocator)
		if conversion_error != nil {return nil, .Out_Of_Memory}
		_, err := append(&list, Process_Info{entry.th32ProcessID, entry.th32ParentProcessID, name})
		if err != nil {delete(name, allocator); return nil, .Out_Of_Memory}
		if !bool(w.Process32NextW(handle, &entry)) {
			if w.GetLastError() != w.ERROR_NO_MORE_FILES {
				log.errorf("Process32NextW failed: %v", w.GetLastError())
				return nil, .Read
			}
			break
		}
	}
	snapshot, err := make([]Process_Info, len(list), allocator)
	if err != nil {return nil, .Out_Of_Memory}
	copy(snapshot, list[:])
	delete(list)
	success = true
	return snapshot, .None
}

process_snapshot_destroy :: proc(snapshot: []Process_Info, allocator := context.allocator) {
	for p in snapshot {delete(p.executable, allocator)}
	delete(snapshot, allocator)
}

// The full image path of a process the snapshot named as root's child or descendant. Snapshot
// parent IDs are never cleared, so a process created before root may name root's reused ID
// without being its descendant; those, exited processes and denied access return no path.
@(require_results)
process_image :: proc(id, root: u32, allocator := context.allocator) -> (string, bool) {
	process := w.OpenProcess(w.PROCESS_QUERY_LIMITED_INFORMATION, false, id)
	if process == nil {return "", false}
	defer close_process(process)
	shell := w.OpenProcess(w.PROCESS_QUERY_LIMITED_INFORMATION, false, root)
	if shell == nil {return "", false}
	defer close_process(shell)
	created, shell_created, unused: w.FILETIME
	if !bool(w.GetProcessTimes(process, &created, &unused, &unused, &unused)) ||
	   !bool(w.GetProcessTimes(shell, &shell_created, &unused, &unused, &unused)) {
		log.errorf("GetProcessTimes failed: %v", w.GetLastError())
		return "", false
	}
	if filetime(created) < filetime(shell_created) {return "", false}
	buffer: [4096]u16
	length := w.DWORD(len(buffer))
	if !bool(QueryFullProcessImageNameW(process, 0, raw_data(buffer[:]), &length)) {return "", false}
	path, err := w.utf16_to_utf8(buffer[:length], allocator)
	return path, err == nil
}

@(private)
filetime :: proc(time: w.FILETIME) -> u64 {
	return u64(time.dwHighDateTime) << 32 | u64(time.dwLowDateTime)
}

@(private)
close_process :: proc(process: w.HANDLE) {
	if !bool(w.CloseHandle(process)) {log.errorf("CloseHandle failed: %v", w.GetLastError())}
}
