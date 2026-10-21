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
