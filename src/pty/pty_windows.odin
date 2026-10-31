package pty

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:slice"
import "core:strings"
import "core:sync"
import w "core:sys/windows"
import "core:unicode/utf8"

Pty :: struct {
	output, input, process, job: w.HANDLE,
	id:                          u32,
	console:                     HPCON,
	console_mutex:               sync.Mutex, // Guards console ownership and active resize calls.
	console_changed:             sync.Cond,
	resizing:                    int,
	closing:                     bool,
	// Output bytes delivered to readers. The reader thread adds; diagnostics read atomically.
	bytes_read:                  u64,
}

process_id :: proc(p: ^Pty) -> u32 {
	return p.id
}

@(private, require_results)
spawn_failure :: proc(call: string, kind: Spawn_Error_Kind, code: u32) -> Spawn_Error {
	log.errorf("pty: %s failed (OS code %v)", call, code)
	return {kind, code}
}

@(private, require_results)
io_failure :: proc(call: string, kind: Error, code: u32) -> Error {
	log.errorf("pty: %s failed (OS code %v)", call, code)
	return kind
}

@(private)
close_handle :: proc(handle: ^w.HANDLE) {
	if handle^ == nil {return}
	if !bool(w.CloseHandle(handle^)) {
		log.errorf("CloseHandle failed: %v", w.GetLastError())
	}
	handle^ = nil
}

@(private)
Environment_Entry :: struct {
	text:  []u16,
	owned: cstring16,
}

@(private, require_results)
parse_environment :: proc(
	parent: w.LPWCH,
	extra: int,
	allocator: runtime.Allocator,
) -> (
	[dynamic]Environment_Entry,
	Spawn_Error,
) {
	block := cast([^]u16)parent
	length, count := 0, 0
	for block[length] != 0 {
		for block[length] != 0 {length += 1}
		length += 1
		count += 1
	}
	entries, err := make([dynamic]Environment_Entry, count, count + extra, allocator)
	if err != nil {return nil, {.Out_Of_Memory, 0}}
	start, index := 0, 0
	for i in 0 ..< length {
		if block[i] == 0 {
			entries[index].text = block[start:i]
			index += 1
			start = i + 1
		}
	}
	return entries, {}
}

@(private)
environment_name :: proc(text: []u16) -> []u16 {
	separator := 1
	for separator < len(text) && text[separator] != '=' {separator += 1}
	return text[:separator]
}

@(private)
compare_environment :: proc(a, b: []u16) -> i32 {
	result := CompareStringOrdinal(raw_data(a), i32(len(a)), raw_data(b), i32(len(b)), true)
	assert(result != 0)
	return result
}

@(private, require_results)
apply_environment_override :: proc(
	entries: ^[dynamic]Environment_Entry,
	item: Env_Var,
	allocator: runtime.Allocator,
) -> Spawn_Error {
	if len(item.name) == 0 ||
	   strings.contains_any(item.name, "=\x00") ||
	   strings.contains(item.value, "\x00") ||
	   !utf8.valid_string(item.name) ||
	   !utf8.valid_string(item.value) {
		return {.Invalid_Environment, 0}
	}
	pieces := [?]string{item.name, "=", item.value}
	text, text_err := strings.concatenate(pieces[:], allocator)
	if text_err != nil {return {.Out_Of_Memory, 0}}
	defer delete(text, allocator)
	wide := w.utf8_to_wstring(text, allocator)
	if wide == nil {return {.Out_Of_Memory, 0}}
	entry := Environment_Entry {
		text  = slice.from_ptr(cast(^u16)wide, len(wide)),
		owned = wide,
	}
	name := environment_name(entry.text)
	for &existing in entries^ {
		if compare_environment(environment_name(existing.text), name) == CSTR_EQUAL {
			delete(existing.owned, allocator)
			existing = entry
			return {}
		}
	}
	_, append_err := append(entries, entry)
	if append_err != nil {
		delete(wide, allocator)
		return {.Out_Of_Memory, 0}
	}
	return {}
}

// Adds `directory` as the last PATH entry, or sets PATH to it when the block has none.
@(private, require_results)
append_path :: proc(
	entries: ^[dynamic]Environment_Entry,
	directory: string,
	allocator: runtime.Allocator,
) -> Spawn_Error {
	path_name := [4]u16{'P', 'A', 'T', 'H'}
	for &existing in entries^ {
		if compare_environment(environment_name(existing.text), path_name[:]) != CSTR_EQUAL {continue}
		addition := w.utf8_to_wstring(directory, allocator)
		if addition == nil {return {.Out_Of_Memory, 0}}
		defer delete(addition, allocator)
		added := slice.from_ptr(cast(^u16)addition, len(addition))
		combined, err := make([]u16, len(existing.text) + 1 + len(added) + 1, allocator)
		if err != nil {return {.Out_Of_Memory, 0}}
		copy(combined, existing.text)
		combined[len(existing.text)] = ';'
		copy(combined[len(existing.text) + 1:], added)
		delete(existing.owned, allocator)
		existing = {text = combined[:len(combined) - 1], owned = cstring16(raw_data(combined))}
		return {}
	}
	return apply_environment_override(entries, {"PATH", directory}, allocator)
}

@(private)
sort_environment :: proc(entries: []Environment_Entry) {
	slice.sort_by(entries, proc(a, b: Environment_Entry) -> bool {
		return compare_environment(a.text, b.text) == CSTR_LESS_THAN
	})
}

@(private, require_results)
serialize_environment :: proc(
	entries: []Environment_Entry,
	allocator: runtime.Allocator,
) -> (
	[]u16,
	Spawn_Error,
) {
	length := 1
	for entry in entries {length += len(entry.text) + 1}
	block, err := make([]u16, max(length, 2), allocator)
	if err != nil || block == nil {return nil, {.Out_Of_Memory, 0}}
	offset := 0
	for entry in entries {
		copy(block[offset:], entry.text)
		offset += len(entry.text) + 1
	}
	return block, {}
}

@(private, require_results)
environment_block :: proc(
	overrides: []Env_Var,
	allocator: runtime.Allocator,
	refresh: bool,
	path_append: string = "",
) -> (
	[]u16,
	Spawn_Error,
) {
	parent := w.GetEnvironmentStringsW()
	if parent == nil {
		return nil, spawn_failure("GetEnvironmentStringsW", .Environment, u32(w.GetLastError()))
	}
	defer {
		if !bool(w.FreeEnvironmentStringsW(parent)) {
			log.errorf("FreeEnvironmentStringsW failed: %v", w.GetLastError())
		}
	}
	fresh: rawptr
	if refresh {
		token: w.HANDLE
		if !bool(
			w.OpenProcessToken(w.GetCurrentProcess(), w.TOKEN_QUERY | w.TOKEN_DUPLICATE, &token),
		) {
			return nil, spawn_failure("OpenProcessToken", .Environment, u32(w.GetLastError()))
		}
		defer close_handle(&token)
		if !bool(CreateEnvironmentBlock(&fresh, token, true)) {
			return nil, spawn_failure(
				"CreateEnvironmentBlock",
				.Environment,
				u32(w.GetLastError()),
			)
		}
	}
	defer if fresh != nil && !bool(DestroyEnvironmentBlock(fresh)) {
		log.errorf("DestroyEnvironmentBlock failed: %v", w.GetLastError())
	}
	source := fresh != nil ? cast(w.LPWCH)fresh : parent
	entries, parse_err := parse_environment(source, len(overrides), allocator)
	if parse_err.kind != .None {return nil, parse_err}
	defer {
		for entry in entries {delete(entry.owned, allocator)}
		delete(entries)
	}
	for item in overrides {
		if err := apply_environment_override(&entries, item, allocator); err.kind != .None {
			return nil, err
		}
	}
	if path_append != "" {
		if err := append_path(&entries, path_append, allocator); err.kind != .None {return nil, err}
	}
	sort_environment(entries[:])
	return serialize_environment(entries[:], allocator)
}

@(require_results)
spawn :: proc(options: Spawn_Options, allocator := context.allocator) -> (Pty, Spawn_Error) {
	p: Pty
	if options.cols == 0 ||
	   options.rows == 0 ||
	   options.cols > u16(max(i16)) ||
	   options.rows > u16(max(i16)) ||
	   len(options.command_line) == 0 ||
	   strings.contains(options.command_line, "\x00") ||
	   !utf8.valid_string(options.command_line) {
		return {}, {.Invalid_Argument, 0}
	}
	if len(options.working_directory) == 0 ||
	   strings.contains(options.working_directory, "\x00") ||
	   !utf8.valid_string(options.working_directory) {
		return {}, {.Invalid_Working_Directory, ERROR_DIRECTORY}
	}
	command := w.utf8_to_wstring(options.command_line, allocator)
	if command == nil {return {}, {.Out_Of_Memory, 0}}
	defer delete(command, allocator)
	// Resolve a bare shell name once, before starting anything. Passing the result as
	// lpApplicationName keeps CreateProcess from searching the current directory and relative
	// PATH entries, which belong to the project being opened rather than to the terminal.
	application: w.LPCWSTR
	defer if application != nil {delete(application, allocator)}
	token := executable_token(options.command_line)
	if token != "" && !is_explicit_path(token) {
		directories, directories_error := search_directories(allocator)
		if directories_error != nil {return {}, {.Out_Of_Memory, 0}}
		defer {
			for directory in directories {delete(directory, allocator)}
			delete(directories, allocator)
		}
		resolved, resolve_error := resolve_executable(
			options.command_line,
			directories,
			allocator,
		)
		if resolve_error.kind != .None {return {}, resolve_error}
		defer delete(resolved, allocator)
		application = w.utf8_to_wstring(resolved, allocator)
		if application == nil {return {}, {.Out_Of_Memory, 0}}
	}
	directory := w.utf8_to_wstring(options.working_directory, allocator)
	if directory == nil {return {}, {.Out_Of_Memory, 0}}
	defer delete(directory, allocator)
	attributes := w.GetFileAttributesW(directory)
	if attributes == w.INVALID_FILE_ATTRIBUTES {
		return {}, spawn_failure("GetFileAttributesW", .Invalid_Working_Directory, u32(w.GetLastError()))
	}
	if attributes & w.FILE_ATTRIBUTE_DIRECTORY == 0 {
		return {}, {.Invalid_Working_Directory, ERROR_DIRECTORY}
	}
	environment, env_err := environment_block(
		options.environment,
		allocator,
		options.refresh_environment,
		options.path_append,
	)
	if env_err.kind != .None {
		return {}, env_err
	}
	defer delete(environment, allocator)
	success := false
	defer {
		if !success {
			destroy(&p)
		}
	}
	console_input, console_output: w.HANDLE
	defer close_handle(&console_input)
	defer close_handle(&console_output)
	if !bool(w.CreatePipe(&console_input, &p.input, nil, 0)) {
		return {}, spawn_failure("CreatePipe", .Pipe, u32(w.GetLastError()))
	}
	if !bool(w.CreatePipe(&p.output, &console_output, nil, 0)) {
		return {}, spawn_failure("CreatePipe", .Pipe, u32(w.GetLastError()))
	}
	size_cells := w.COORD{i16(options.cols), i16(options.rows)}
	api := conpty()
	flags := u32(PSEUDOCONSOLE_RESIZE_QUIRK | PSEUDOCONSOLE_WIN32_INPUT_MODE)
	if api.bundled {flags |= PSEUDOCONSOLE_GLYPH_WIDTH_GRAPHEMES}
	result := api.create(size_cells, console_input, console_output, flags, &p.console)
	if u32(result) == w.E_INVALIDARG {
		result = api.create(size_cells, console_input, console_output, 0, &p.console)
	}
	if result < 0 {
		return {}, spawn_failure("CreatePseudoConsole", .Console, u32(result))
	}
	close_handle(&console_input)
	close_handle(&console_output)
	size: w.SIZE_T
	if bool(InitializeProcThreadAttributeList(nil, 1, 0, &size)) ||
	   w.GetLastError() != w.ERROR_INSUFFICIENT_BUFFER {
		return {}, spawn_failure("InitializeProcThreadAttributeList", .Attributes, u32(w.GetLastError()))
	}
	storage, storage_err := make([]u8, int(size), allocator)
	if storage_err != nil {
		return {}, {.Out_Of_Memory, 0}
	}
	defer delete(storage, allocator)
	if !bool(InitializeProcThreadAttributeList(raw_data(storage), 1, 0, &size)) {
		return {}, spawn_failure("InitializeProcThreadAttributeList", .Attributes, u32(w.GetLastError()))
	}
	defer DeleteProcThreadAttributeList(raw_data(storage))
	if !bool(
		UpdateProcThreadAttribute(
			raw_data(storage),
			0,
			PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
			rawptr(p.console),
			size_of(HPCON),
			nil,
			nil,
		),
	) {
		return {}, spawn_failure("UpdateProcThreadAttribute", .Attributes, u32(w.GetLastError()))
	}
	p.job = CreateJobObjectW(nil, nil)
	if p.job == nil {
		return {}, spawn_failure("CreateJobObjectW", .Job, u32(w.GetLastError()))
	}
	limits := JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
		BasicLimitInformation = {LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE},
	}
	if !bool(
		SetInformationJobObject(
			p.job,
			JobObjectExtendedLimitInformation,
			&limits,
			size_of(limits),
		),
	) {
		return {}, spawn_failure("SetInformationJobObject", .Job, u32(w.GetLastError()))
	}
	startup := STARTUPINFOEXW {
		StartupInfo = {cb = size_of(STARTUPINFOEXW), dwFlags = w.STARTF_USESTDHANDLES},
		lpAttributeList = raw_data(storage),
	}
	info: w.PROCESS_INFORMATION
	// Children inherit the ignore-Ctrl+C flag; a launcher that set it on us would make Ctrl+C dead in the shell.
	if !bool(w.SetConsoleCtrlHandler(nil, false)) {
		log.errorf("SetConsoleCtrlHandler failed: %v", w.GetLastError())
	}
	process_flags := u32(
		w.CREATE_UNICODE_ENVIRONMENT | w.EXTENDED_STARTUPINFO_PRESENT | w.CREATE_SUSPENDED,
	)
	if !bool(
		w.CreateProcessW(
			application,
			command,
			nil,
			nil,
			false,
			process_flags,
			raw_data(environment),
			directory,
			&startup.StartupInfo,
			&info,
		),
	) {
		return {}, spawn_failure("CreateProcessW", .Start_Process, u32(w.GetLastError()))
	}
	p.process = info.hProcess
	p.id = info.dwProcessId
	defer close_handle(&info.hThread)
	if !bool(AssignProcessToJobObject(p.job, p.process)) {
		err := spawn_failure("AssignProcessToJobObject", .Job, u32(w.GetLastError()))
		if !bool(w.TerminateProcess(p.process, 1)) {
			log.errorf("TerminateProcess failed: %v", w.GetLastError())
		}
		return {}, err
	}
	if w.ResumeThread(info.hThread) == max(w.DWORD) {
		return {}, spawn_failure("ResumeThread", .Resume_Process, u32(w.GetLastError()))
	}
	success = true
	return p, {}
}

@(require_results)
read :: proc(p: ^Pty, buffer: []u8) -> (n: int, err: Error) {
	if p.output == nil {
		return 0, .Closed
	}
	if len(buffer) == 0 {
		return 0, .Invalid_Argument
	}
	count: u32
	request := u32(min(len(buffer), int(max(u32))))
	if !bool(w.ReadFile(p.output, raw_data(buffer), request, &count, nil)) {
		code := u32(w.GetLastError())
		if code == w.ERROR_BROKEN_PIPE || code == w.ERROR_NO_DATA {
			return 0, .Closed
		}
		return 0, io_failure("ReadFile", .Read, code)
	}
	if count == 0 {
		return 0, .Closed
	}
	// The reader thread owns this counter; a diagnostics read may lag by the chunk in flight.
	sync.atomic_add(&p.bytes_read, u64(count))
	return int(count), .None
}

// output_bytes reports how much output this console has delivered to readers.
@(require_results)
output_bytes :: proc(p: ^Pty) -> u64 {
	return sync.atomic_load(&p.bytes_read)
}

// reset_output_bytes clears the delivered total for a diagnostics reset. A chunk read at the same
// moment may still land after the clear.
reset_output_bytes :: proc(p: ^Pty) {
	sync.atomic_store(&p.bytes_read, 0)
}

@(require_results)
write :: proc(p: ^Pty, data: []u8) -> Error {
	if p.input == nil {
		return .Closed
	}
	offset := 0
	for offset < len(data) {
		count: u32
		request := u32(min(len(data) - offset, int(max(u32))))
		if !bool(w.WriteFile(p.input, raw_data(data[offset:]), request, &count, nil)) {
			code := u32(w.GetLastError())
			if code == w.ERROR_BROKEN_PIPE || code == w.ERROR_NO_DATA {
				return .Closed
			}
			return io_failure("WriteFile", .Write, code)
		}
		if count == 0 {
			return .Closed
		}
		offset += int(count)
	}
	return .None
}

@(require_results)
resize :: proc(p: ^Pty, cols, rows: u16) -> Error {
	if cols == 0 || rows == 0 || cols > u16(max(i16)) || rows > u16(max(i16)) {
		return .Invalid_Argument
	}
	sync.mutex_lock(&p.console_mutex)
	console := p.console
	if console == nil || p.closing {
		sync.mutex_unlock(&p.console_mutex)
		return .Closed
	}
	p.resizing += 1
	sync.mutex_unlock(&p.console_mutex)
	result := conpty().resize(console, {i16(cols), i16(rows)})
	sync.mutex_lock(&p.console_mutex)
	p.resizing -= 1
	sync.cond_broadcast(&p.console_changed)
	sync.mutex_unlock(&p.console_mutex)
	if result < 0 {
		return io_failure("ResizePseudoConsole", .Resize, u32(result))
	}
	return .None
}

@(require_results)
wait_exit :: proc(p: ^Pty) -> (code: u32, err: Error) {
	if p.process == nil {
		return 0, .Closed
	}
	if w.WaitForSingleObject(p.process, w.INFINITE) != w.WAIT_OBJECT_0 {
		return 0, io_failure("WaitForSingleObject", .Wait, u32(w.GetLastError()))
	}
	if !bool(w.GetExitCodeProcess(p.process, &code)) {
		return 0, io_failure("GetExitCodeProcess", .Wait, u32(w.GetLastError()))
	}
	return code, .None
}

close_console :: proc(p: ^Pty) {
	sync.mutex_lock(&p.console_mutex)
	for p.closing {
		sync.cond_wait(&p.console_changed, &p.console_mutex)
	}
	if p.console == nil {
		sync.mutex_unlock(&p.console_mutex)
		return
	}
	p.closing = true
	for p.resizing != 0 {
		sync.cond_wait(&p.console_changed, &p.console_mutex)
	}
	console := p.console
	p.console = nil
	sync.mutex_unlock(&p.console_mutex)
	// After exit, closing delivers EOF and may wait for the reader to drain output.
	conpty().close(console)
	sync.mutex_lock(&p.console_mutex)
	p.closing = false
	sync.cond_broadcast(&p.console_changed)
	sync.mutex_unlock(&p.console_mutex)
}

@(require_results)
terminate :: proc(p: ^Pty) -> Error {
	if p.job == nil {
		return .None
	}
	if !bool(TerminateJobObject(p.job, 1)) {
		return io_failure("TerminateJobObject", .Terminate, u32(w.GetLastError()))
	}
	return .None
}

destroy :: proc(p: ^Pty) {
	// The reader must have reached EOF (or never started); console close can otherwise block.
	if err := terminate(p); err != .None {
		log.errorf("pty termination during destroy failed: %v", err)
	}
	close_console(p)
	close_handle(&p.input)
	close_handle(&p.output)
	close_handle(&p.process)
	close_handle(&p.job)
	p.id = 0
}

@(require_results)
error_message :: proc(
	err: Spawn_Error,
	options: Spawn_Options,
	allocator := context.allocator,
) -> (
	string,
	Error,
) {
	if err.kind == .None {return "", .None}
	prefix, subject := "", ""
	switch err.kind {
	case .None:
		return "", .None
	case .Invalid_Argument:
		prefix = "Invalid shell command line or terminal size"
	case .Invalid_Working_Directory:
		prefix, subject = "Could not use working directory", options.working_directory
	case .Invalid_Environment:
		prefix = "Invalid environment variable name or value"
	case .Out_Of_Memory:
		prefix = "Not enough memory to start the shell"
	case .Environment:
		prefix = "Could not read the parent environment"
	case .Pipe:
		prefix = "Could not create terminal pipes"
	case .Console:
		prefix = "Could not create the terminal console"
	case .Attributes:
		prefix = "Could not configure shell process attributes"
	case .Job:
		prefix = "Could not configure the shell process job"
	case .Start_Process:
		prefix, subject = "Could not start", options.command_line
	case .Resume_Process:
		prefix, subject = "Could not resume", options.command_line
	}
	wide: [2048]u16
	utf8_buffer: [8192]u8
	fallback: [64]u8
	message := ""
	if err.os_code != 0 {
		code := err.os_code
		if w.HRESULT_FACILITY(code) == .WIN32 {code = u32(w.HRESULT_CODE(code))}
		flags := u32(w.FORMAT_MESSAGE_FROM_SYSTEM | w.FORMAT_MESSAGE_IGNORE_INSERTS)
		length := w.FormatMessageW(flags, nil, code, 0, raw_data(wide[:]), len(wide), nil)
		if length == 0 {
			log.errorf("FormatMessageW failed: %v", w.GetLastError())
			message = fmt.bprintf(fallback[:], "OS code %v.", err.os_code)
		} else {
			message = w.utf16_to_utf8(utf8_buffer[:], wide[:length])
			if len(message) == 0 {
				return "", io_failure(
					"WideCharToMultiByte",
					.Invalid_Argument,
					u32(w.GetLastError()),
				)
			}
		}
	}
	quote_start, quote_end := "", ""
	if subject != "" {
		quote_start, quote_end = " \"", "\""
	}
	separator := len(message) == 0 ? "." : ": "
	parts := [?]string {
		prefix,
		quote_start,
		subject,
		quote_end,
		separator,
		strings.trim_space(message),
	}
	result, alloc_err := strings.concatenate(parts[:], allocator)
	if alloc_err != nil || len(result) == 0 {return "", .Out_Of_Memory}
	return result, .None
}
