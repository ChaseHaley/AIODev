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
	process, opened := open_descendant(id, root)
	if !opened {return "", false}
	defer close_process(process)
	buffer: [4096]u16
	length := w.DWORD(len(buffer))
	if !bool(QueryFullProcessImageNameW(process, 0, raw_data(buffer[:]), &length)) {return "", false}
	path, err := w.utf16_to_utf8(buffer[:length], allocator)
	return path, err == nil
}

// The command line arguments of root's child or descendant, under the same guard as process_image.
// The caller deletes each argument and the slice.
@(require_results)
process_arguments :: proc(id, root: u32, allocator := context.allocator) -> ([]string, bool) {
	process, opened := open_descendant(id, root)
	if !opened {return nil, false}
	defer close_process(process)
	// ProcessCommandLineInformation: a UNICODE_STRING followed by its characters. Needs Windows 8.1.
	COMMAND_LINE_CLASS :: w.PROCESS_INFO_CLASS(60)
	STATUS_INFO_LENGTH_MISMATCH :: 0xC0000004
	size: u32
	status := w.NtQueryInformationProcess(process, COMMAND_LINE_CLASS, nil, 0, &size)
	if status != STATUS_INFO_LENGTH_MISMATCH || size < size_of(w.UNICODE_STRING) || size > 1 << 17 {
		return nil, false
	}
	buffer := make([]u8, size, context.temp_allocator)
	if w.NtQueryInformationProcess(process, COMMAND_LINE_CLASS, raw_data(buffer), size, &size) != 0 {
		return nil, false
	}
	line := (^w.UNICODE_STRING)(raw_data(buffer))
	wide := make([]u16, int(line.Length / 2) + 1, context.temp_allocator)
	copy(wide, line.Buffer[:line.Length / 2])
	count: i32
	argv := w.CommandLineToArgvW(w.wstring(raw_data(wide)), &count)
	if argv == nil {return nil, false}
	defer w.LocalFree(argv)
	arguments := make([]string, int(count), allocator)
	for i in 0 ..< int(count) {
		value, err := w.wstring_to_utf8(argv[i], -1, allocator)
		if err != nil {
			for a in arguments[:i] {delete(a, allocator)}
			delete(arguments, allocator)
			return nil, false
		}
		arguments[i] = value
	}
	return arguments, true
}

// The current directory of root or its descendant, under the same guard as process_image, read
// from the process's parameters the way WezTerm does. PowerShell's Set-Location does not change
// it; a shell reports that directory through OSC 7 instead. WoW64 processes return no directory.
@(require_results)
process_directory :: proc(id, root: u32, allocator := context.allocator) -> (string, bool) {
	process, opened := open_descendant(id, root, w.PROCESS_QUERY_INFORMATION | w.PROCESS_VM_READ)
	if !opened {return "", false}
	defer close_process(process)
	machine, native: w.USHORT
	if !bool(w.IsWow64Process2(process, &machine, &native)) || machine != 0 {return "", false}
	basic: w.PROCESS_BASIC_INFORMATION
	size: u32
	status := w.NtQueryInformationProcess(process, .ProcessBasicInformation, &basic, size_of(basic), &size)
	if status != 0 || basic.PebBaseAddress == nil {return "", false}
	// PEB.ProcessParameters and RTL_USER_PROCESS_PARAMETERS.CurrentDirectory.DosPath on 64-bit Windows.
	when size_of(uintptr) != 8 {return "", false}
	PARAMETERS_OFFSET :: 0x20
	DIRECTORY_OFFSET :: 0x38
	parameters: uintptr
	peb := uintptr(basic.PebBaseAddress)
	if !read_memory(process, peb + PARAMETERS_OFFSET, &parameters, size_of(parameters)) || parameters == 0 {
		return "", false
	}
	path: w.UNICODE_STRING
	if !read_memory(process, parameters + DIRECTORY_OFFSET, &path, size_of(path)) ||
	   path.Length == 0 || path.Length % 2 != 0 || path.Buffer == nil {
		return "", false
	}
	wide := make([]u16, int(path.Length / 2), context.temp_allocator)
	if !read_memory(process, uintptr(path.Buffer), raw_data(wide), int(path.Length)) {return "", false}
	// DosPath keeps a trailing separator; a drive root keeps its own.
	length := len(wide)
	if length > 3 && wide[length - 1] == '\\' {length -= 1}
	directory, err := w.utf16_to_utf8(wide[:length], allocator)
	return directory, err == nil
}

@(private, require_results)
read_memory :: proc(process: w.HANDLE, address: uintptr, buffer: rawptr, size: int) -> bool {
	read: w.SIZE_T
	ok := w.ReadProcessMemory(process, rawptr(address), buffer, w.SIZE_T(size), &read)
	return bool(ok) && int(read) == size
}

@(private, require_results)
open_descendant :: proc(
	id, root: u32,
	access: u32 = w.PROCESS_QUERY_LIMITED_INFORMATION,
) -> (w.HANDLE, bool) {
	process := w.OpenProcess(access, false, id)
	if process == nil {return nil, false}
	shell := w.OpenProcess(w.PROCESS_QUERY_LIMITED_INFORMATION, false, root)
	if shell == nil {close_process(process); return nil, false}
	defer close_process(shell)
	created, shell_created, unused: w.FILETIME
	if !bool(w.GetProcessTimes(process, &created, &unused, &unused, &unused)) ||
	   !bool(w.GetProcessTimes(shell, &shell_created, &unused, &unused, &unused)) {
		log.errorf("GetProcessTimes failed: %v", w.GetLastError())
		close_process(process)
		return nil, false
	}
	if filetime(created) < filetime(shell_created) {close_process(process); return nil, false}
	return process, true
}

@(private)
filetime :: proc(time: w.FILETIME) -> u64 {
	return u64(time.dwHighDateTime) << 32 | u64(time.dwLowDateTime)
}

@(private)
close_process :: proc(process: w.HANDLE) {
	if !bool(w.CloseHandle(process)) {log.errorf("CloseHandle failed: %v", w.GetLastError())}
}
