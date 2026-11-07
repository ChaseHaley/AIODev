package instance

import "base:runtime"
import "core:log"
import "core:os"
import w "core:sys/windows"

// The instance's paths on this machine. Without --data-dir, machine-local files go under
// %LOCALAPPDATA% and settings under the roaming application-data folder; a root that cannot be found
// leaves its fields empty for the caller to report.
@(require_results)
paths :: proc(options: Options, allocator := context.allocator) -> (p: Paths, err: runtime.Allocator_Error) {
	if options.data_dir != "" {return paths_resolve(options, "", "", allocator)}
	local, _ := os.lookup_env("LOCALAPPDATA", context.temp_allocator)
	roaming: string
	wide: w.LPWSTR
	id := w.FOLDERID_RoamingAppData
	hr := w.SHGetKnownFolderPath(&id, 0, nil, &wide)
	defer if wide != nil {w.CoTaskMemFree(wide)}
	if hr < 0 {
		log.errorf("SHGetKnownFolderPath failed: HRESULT 0x%08x", u32(hr))
	} else {
		roaming = w.wstring_to_utf8(w.wstring(wide), -1, context.temp_allocator) or_return
	}
	return paths_resolve(options, local, roaming, allocator)
}

@(require_results)
command_line :: proc(allocator: runtime.Allocator) -> (args: []string, error: Error) {
	line := w.GetCommandLineW()
	if line == nil {
		log.errorf("GetCommandLineW failed: %v", w.GetLastError())
		return nil, .System
	}
	count: i32
	wide := w.CommandLineToArgvW(line, &count)
	if wide == nil {
		log.errorf("CommandLineToArgvW failed: %v", w.GetLastError())
		return nil, .System
	}
	defer {
		if w.LocalFree(rawptr(wide)) != nil {
			log.errorf("LocalFree(command line) failed: %v", w.GetLastError())
			if error == .None {
				command_line_destroy(args, allocator)
				args, error = nil, .System
			}
		}
	}
	if count < 1 {return nil, .System}
	allocation_error: runtime.Allocator_Error
	args, allocation_error = make([]string, int(count) - 1, allocator)
	if allocation_error != nil {return nil, .Out_Of_Memory}
	for &arg, i in args {
		units := cast([^]u16)wide[i + 1]
		n := 0
		for units[n] != 0 {n += 1}
		bytes, conversion_error := w.utf16_to_utf8(units[:n], allocator)
		if conversion_error != nil {
			command_line_destroy(args, allocator)
			return nil, .Out_Of_Memory
		}
		arg = string(bytes)
		if n > 0 && len(bytes) == 0 {
			log.errorf("WideCharToMultiByte(command line) failed: %v", w.GetLastError())
			command_line_destroy(args, allocator)
			return nil, .System
		}
	}
	return args, .None
}

command_line_destroy :: proc(args: []string, allocator: runtime.Allocator) {
	for arg in args {delete(arg, allocator)}
	delete(args, allocator)
}
