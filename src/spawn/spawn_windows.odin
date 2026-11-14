package spawn

import "aio:commands"
import "base:runtime"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import w "core:sys/windows"
import "core:thread"
import "core:unicode/utf8"

// Process is opaque to callers. kill stops its whole job, including descendants that outlive
// the immediate child. destroy accepts nil and also cleans up a partially started process.
Process :: struct {
	allocator: runtime.Allocator,
	wake: Wake,
	process, job, input: w.HANDLE,
	id: u32,
	mutex, input_mutex: sync.Mutex,
	streams: [2]Stream,
	waiter, writer: ^thread.Thread,
	initial: string,
	keep_stdin, keep_crlf, exited, capture_failed: bool,
	code: int,
}

@(private)
Stream :: struct {
	owner: ^Process,
	handle: w.HANDLE,
	worker: ^thread.Thread,
	incoming, delivered: [dynamic]u8,
	done: bool,
}

@(private)
STARTUPINFOEXW :: struct {
	StartupInfo: w.STARTUPINFOW,
	lpAttributeList: rawptr,
}

@(private)
IO_COUNTERS :: struct {
	ReadOperationCount, WriteOperationCount, OtherOperationCount: u64,
	ReadTransferCount, WriteTransferCount, OtherTransferCount: u64,
}

@(private)
JOBOBJECT_BASIC_LIMIT_INFORMATION :: struct {
	PerProcessUserTimeLimit, PerJobUserTimeLimit: w.LARGE_INTEGER,
	LimitFlags: w.DWORD,
	MinimumWorkingSetSize, MaximumWorkingSetSize: w.SIZE_T,
	ActiveProcessLimit: w.DWORD,
	Affinity: w.ULONG_PTR,
	PriorityClass, SchedulingClass: w.DWORD,
}

@(private)
JOBOBJECT_EXTENDED_LIMIT_INFORMATION :: struct {
	BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION,
	IoInfo: IO_COUNTERS,
	ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed: w.SIZE_T,
}

foreign import kernel32 "system:kernel32.lib"

@(private, default_calling_convention = "system")
foreign kernel32 {
	InitializeProcThreadAttributeList :: proc(list: rawptr, count, flags: w.DWORD, size: ^w.SIZE_T) -> w.BOOL ---
	UpdateProcThreadAttribute :: proc(
		list: rawptr,
		flags: w.DWORD,
		attribute: w.DWORD_PTR,
		value: rawptr,
		size: w.SIZE_T,
		previous: rawptr,
		returned: ^w.SIZE_T,
	) -> w.BOOL ---
	DeleteProcThreadAttributeList :: proc(list: rawptr) ---
	CreateJobObjectW :: proc(attributes: w.LPSECURITY_ATTRIBUTES, name: w.LPCWSTR) -> w.HANDLE ---
	SetInformationJobObject :: proc(job: w.HANDLE, kind: i32, info: rawptr, size: w.DWORD) -> w.BOOL ---
	AssignProcessToJobObject :: proc(job, process: w.HANDLE) -> w.BOOL ---
	TerminateJobObject :: proc(job: w.HANDLE, code: w.UINT) -> w.BOOL ---
	CompareStringOrdinal :: proc(a: ^u16, a_length: i32, b: ^u16, b_length: i32, ignore_case: w.BOOL) -> i32 ---
}

@(private)
close_handle :: proc(handle: ^w.HANDLE) {
	if handle^ == nil {return}
	_ = w.CloseHandle(handle^)
	handle^ = nil
}

@(private)
notify :: proc(p: ^Process) {
	if p.wake.wake != nil {p.wake.wake(p.wake.data)}
}

@(private)
environment_name :: proc(entry: []u16) -> []u16 {
	// Windows also supplies hidden drive-current-directory entries such as =C:=C:\work.
	separator := 1
	for separator < len(entry) && entry[separator] != '=' {separator += 1}
	return entry[:separator]
}

// CompareStringOrdinal results.
@(private)
CSTR_LESS_THAN :: 1
@(private)
CSTR_EQUAL :: 2

@(private)
compare_environment :: proc(a, b: []u16) -> i32 {
	return CompareStringOrdinal(raw_data(a), i32(len(a)), raw_data(b), i32(len(b)), true)
}

@(private, require_results)
environment_build :: proc(options: Options) -> (block: []u16, path, extensions: string, error: Error) {
	allocator := context.temp_allocator
	entries, allocation_error := make([dynamic][]u16, 0, len(options.env) + 64, allocator)
	if allocation_error != nil {return nil, "", "", .Out_Of_Memory}
	parent: w.LPWCH
	if !options.clear_env {
		parent = w.GetEnvironmentStringsW()
		if parent == nil {return nil, "", "", .Start_Failed}
	}
	defer if parent != nil {_ = w.FreeEnvironmentStringsW(parent)}
	if parent != nil {
		text := cast([^]u16)parent
		position := 0
		for text[position] != 0 {
			begin := position
			for text[position] != 0 {position += 1}
			_, append_error := append(&entries, text[begin:position])
			if append_error != nil {return nil, "", "", .Out_Of_Memory}
			position += 1
		}
	}
	for edit in options.env {
		separator := strings.index_byte(edit, '=')
		if separator <= 0 || strings.contains(edit, "\x00") || !utf8.valid_string(edit) {
			return nil, "", "", .Start_Failed
		}
		wide := w.utf8_to_wstring(edit, allocator)
		if wide == nil {return nil, "", "", .Out_Of_Memory}
		entry := slice.from_ptr(cast(^u16)wide, len(wide))
		// The byte index in a UTF-8 edit need not be the UTF-16 name length.
		name := environment_name(entry)
		for i := 0; i < len(entries); i += 1 {
			if compare_environment(environment_name(entries[i]), name) == CSTR_EQUAL {
				ordered_remove(&entries, i)
				break
			}
		}
		if separator + 1 == len(edit) {continue}
		_, append_error := append(&entries, entry)
		if append_error != nil {return nil, "", "", .Out_Of_Memory}
	}
	slice.sort_by(entries[:], proc(a, b: []u16) -> bool {
		return compare_environment(a, b) == CSTR_LESS_THAN
	})
	length := 1
	path = ""
	extensions = ".COM;.EXE;.BAT;.CMD"
	path_name := [?]u16{'P', 'A', 'T', 'H'}
	extensions_name := [?]u16{'P', 'A', 'T', 'H', 'E', 'X', 'T'}
	for entry in entries {
		length += len(entry) + 1
		name_wide := environment_name(entry)
		is_path := compare_environment(name_wide, path_name[:]) == CSTR_EQUAL
		is_extensions := compare_environment(name_wide, extensions_name[:]) == CSTR_EQUAL
		if is_path || is_extensions {
			value, value_error := w.utf16_to_utf8(entry[len(name_wide) + 1:], allocator)
			if value_error != nil {return nil, "", "", .Out_Of_Memory}
			if is_path {path = value} else {extensions = value}
		}
	}
	block, allocation_error = make([]u16, max(length, 2), allocator)
	if allocation_error != nil {return nil, "", "", .Out_Of_Memory}
	offset := 0
	for entry in entries {
		copy(block[offset:], entry)
		offset += len(entry) + 1
	}
	return block, path, extensions, .None
}

@(private, require_results)
executable_candidate :: proc(path: string) -> (w.wstring, Error) {
	wide := w.utf8_to_wstring(path, context.temp_allocator)
	if wide == nil {return nil, .Out_Of_Memory}
	attributes := w.GetFileAttributesW(wide)
	if attributes == w.INVALID_FILE_ATTRIBUTES || attributes & w.FILE_ATTRIBUTE_DIRECTORY != 0 {
		return nil, .Not_Found
	}
	extension := filepath.ext(path)
	if !strings.equal_fold(extension, ".exe") && !strings.equal_fold(extension, ".com") {
		return nil, .Not_Executable
	}
	return wide, .None
}

@(private, require_results)
executable_resolve :: proc(name, directory, path, extensions: string) -> (w.wstring, Error) {
	allocator := context.temp_allocator
	if strings.contains_any(name, "/\\") {
		candidate := name
		if !filepath.is_abs(candidate) {
			joined, join_error := filepath.join({directory, candidate}, allocator)
			if join_error != nil {return nil, .Out_Of_Memory}
			candidate = joined
		}
		return executable_candidate(candidate)
	}
	if path == "" {return nil, .Not_Found}
	directories, split_error := strings.split(path, ";", allocator)
	if split_error != nil {return nil, .Out_Of_Memory}
	suffixes, suffix_error := strings.split(extensions, ";", allocator)
	if suffix_error != nil {return nil, .Out_Of_Memory}
	has_extension := filepath.ext(name) != ""
	for raw_folder in directories {
		folder := strings.trim(raw_folder, "\"")
		// An empty entry such as a trailing ';' must not silently search the child's directory.
		if folder == "" {continue}
		if !filepath.is_abs(folder) {
			joined, join_error := filepath.join({directory, folder}, allocator)
			if join_error != nil {return nil, .Out_Of_Memory}
			folder = joined
		}
		// A name that already has an extension is tried as written first, as cmd.exe does; a
		// dotted name such as tool.v2 still gets the PATHEXT suffixes after that.
		if has_extension {
			candidate, join_error := filepath.join({folder, name}, allocator)
			if join_error != nil {return nil, .Out_Of_Memory}
			wide, error := executable_candidate(candidate)
			if error != .Not_Found {return wide, error}
		}
		for suffix in suffixes {
			if suffix == "" || suffix[0] != '.' || strings.contains_any(suffix, "/\\") {continue}
			filename, name_error := strings.concatenate({name, suffix}, allocator)
			if name_error != nil {return nil, .Out_Of_Memory}
			candidate, join_error := filepath.join({folder, filename}, allocator)
			if join_error != nil {return nil, .Out_Of_Memory}
			wide, error := executable_candidate(candidate)
			if error != .Not_Found {return wide, error}
		}
	}
	return nil, .Not_Found
}

// Starts argv directly. Only .exe and .com files are executable; batch files require an explicit
// cmd.exe /d /c invocation because CommandLineToArgvW quoting is not shell quoting.
@(require_results)
start :: proc(
	argv: []string,
	options: Options,
	wake: Wake,
	allocator := context.allocator,
) -> (
	^Process,
	Error,
) {
	if len(argv) == 0 || argv[0] == "" {return nil, .Not_Found}
	for arg in argv {
		if strings.contains(arg, "\x00") || !utf8.valid_string(arg) {return nil, .Start_Failed}
	}
	if strings.contains(options.cwd, "\x00") || !utf8.valid_string(options.cwd) {return nil, .Start_Failed}
	environment, path, extensions, environment_error := environment_build(options)
	if environment_error != .None {return nil, environment_error}
	directory, directory_error := filepath.abs(options.cwd, context.temp_allocator)
	if directory_error != nil {return nil, .Start_Failed}
	application, lookup_error := executable_resolve(argv[0], directory, path, extensions)
	if lookup_error != .None {return nil, lookup_error}
	// commands.command_line_join implements exactly the CommandLineToArgvW backslash and quote
	// rules. argv[0] is parsed without escapes, but a Windows file name holds no quote, so its
	// backslashes are never doubled and the same join is exact for it too.
	line, line_error := commands.command_line_join(argv, context.temp_allocator)
	if line_error != nil {return nil, .Out_Of_Memory}
	command := w.utf8_to_wstring(line, context.temp_allocator)
	folder := w.utf8_to_wstring(directory, context.temp_allocator)
	if command == nil || folder == nil {return nil, .Out_Of_Memory}
	p, allocation_error := new(Process, allocator)
	if allocation_error != nil {return nil, .Out_Of_Memory}
	p.allocator, p.wake = allocator, wake
	p.keep_stdin, p.keep_crlf = options.keep_stdin, options.keep_crlf
	success := false
	defer if !success {destroy(p)}
	p.initial, allocation_error = strings.clone(options.stdin, allocator)
	if allocation_error != nil {return nil, .Out_Of_Memory}
	attributes := w.SECURITY_ATTRIBUTES{nLength = size_of(w.SECURITY_ATTRIBUTES), bInheritHandle = true}
	child: [3]w.HANDLE
	defer for &handle in child {close_handle(&handle)}
	if !bool(w.CreatePipe(&child[0], &p.input, &attributes, 0)) {return nil, .Start_Failed}
	if !bool(w.SetHandleInformation(p.input, w.HANDLE_FLAG_INHERIT, 0)) {return nil, .Start_Failed}
	discard := [2]bool{options.discard_stdout, options.discard_stderr}
	for &stream, index in p.streams {
		stream.owner = p
		if discard[index] {
			nul := w.utf8_to_wstring("NUL", context.temp_allocator)
			if nul == nil {return nil, .Out_Of_Memory}
			child[index + 1] = w.CreateFileW(nul, w.GENERIC_WRITE,
				w.FILE_SHARE_READ | w.FILE_SHARE_WRITE, &attributes, w.OPEN_EXISTING,
				w.FILE_ATTRIBUTE_NORMAL, nil)
			if child[index + 1] == w.INVALID_HANDLE_VALUE {
				child[index + 1] = nil
				return nil, .Start_Failed
			}
			stream.done = true
			continue
		}
		if !bool(w.CreatePipe(&stream.handle, &child[index + 1], &attributes, 64 * 1024)) {
			return nil, .Start_Failed
		}
		if !bool(w.SetHandleInformation(stream.handle, w.HANDLE_FLAG_INHERIT, 0)) {
			return nil, .Start_Failed
		}
		stream.incoming, allocation_error = make([dynamic]u8, 0, 4096, allocator)
		if allocation_error != nil {return nil, .Out_Of_Memory}
		stream.delivered, allocation_error = make([dynamic]u8, 0, 4096, allocator)
		if allocation_error != nil {return nil, .Out_Of_Memory}
	}
	attribute_size: w.SIZE_T
	if bool(InitializeProcThreadAttributeList(nil, 1, 0, &attribute_size)) ||
	   w.GetLastError() != w.ERROR_INSUFFICIENT_BUFFER {return nil, .Start_Failed}
	storage, storage_error := make([]u8, int(attribute_size), context.temp_allocator)
	if storage_error != nil {return nil, .Out_Of_Memory}
	if !bool(InitializeProcThreadAttributeList(raw_data(storage), 1, 0, &attribute_size)) {
		return nil, .Start_Failed
	}
	defer DeleteProcThreadAttributeList(raw_data(storage))
	// PROC_THREAD_ATTRIBUTE_HANDLE_LIST excludes every unrelated inheritable app handle.
	if !bool(UpdateProcThreadAttribute(raw_data(storage), 0, 0x20002, &child[0],
		size_of(child), nil, nil)) {return nil, .Start_Failed}
	p.job = CreateJobObjectW(nil, nil)
	if p.job == nil {return nil, .Start_Failed}
	limits := JOBOBJECT_EXTENDED_LIMIT_INFORMATION{
		BasicLimitInformation = {LimitFlags = 0x2000}, // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE.
	}
	if !bool(SetInformationJobObject(p.job, 9, &limits, size_of(limits))) {return nil, .Start_Failed}
	startup := STARTUPINFOEXW{
		StartupInfo = {
			cb = size_of(STARTUPINFOEXW), dwFlags = w.STARTF_USESTDHANDLES,
			hStdInput = child[0], hStdOutput = child[1], hStdError = child[2],
		},
		lpAttributeList = raw_data(storage),
	}
	info: w.PROCESS_INFORMATION
	flags := u32(w.CREATE_NO_WINDOW | w.CREATE_UNICODE_ENVIRONMENT |
		w.EXTENDED_STARTUPINFO_PRESENT | w.CREATE_SUSPENDED)
	if !bool(w.CreateProcessW(application, command, nil, nil, true, flags,
		raw_data(environment), folder, &startup.StartupInfo, &info)) {
		if w.GetLastError() == 193 {return nil, .Not_Executable}
		return nil, .Start_Failed
	}
	p.process, p.id = info.hProcess, info.dwProcessId
	defer close_handle(&info.hThread)
	for &handle in child {close_handle(&handle)}
	// Assign while suspended: the child cannot escape the job by spawning before assignment.
	if !bool(AssignProcessToJobObject(p.job, p.process)) {return nil, .Start_Failed}
	for &stream in p.streams {
		if stream.done {continue}
		stream.worker = thread.create(reader_main)
		if stream.worker == nil {return nil, .Out_Of_Memory}
		stream.worker.data = &stream
		thread.start(stream.worker)
	}
	p.waiter = thread.create(waiter_main)
	if p.waiter == nil {return nil, .Out_Of_Memory}
	p.waiter.data = p
	thread.start(p.waiter)
	if p.initial != "" {
		p.writer = thread.create(writer_main)
		if p.writer == nil {return nil, .Out_Of_Memory}
		p.writer.data = p
		thread.start(p.writer)
	} else if !p.keep_stdin {
		close_handle(&p.input)
	}
	if w.ResumeThread(info.hThread) == max(w.DWORD) {return nil, .Start_Failed}
	success = true
	return p, .None
}

@(private)
reader_main :: proc(t: ^thread.Thread) {
	stream := (^Stream)(t.data)
	p := stream.owner
	// The extra byte allows a pending CR followed by a full non-LF chunk without another copy.
	buffer: [4097]u8
	pending_cr := false
	for {
		count: w.DWORD
		ok := bool(w.ReadFile(stream.handle, &buffer[1], 4096, &count, nil))
		bytes := buffer[1:1 + int(count)]
		if !p.keep_crlf {
			length := 0
			for value in bytes {
				if pending_cr {
					if value != '\n' {buffer[length] = '\r'; length += 1}
					pending_cr = false
				}
				if value == '\r' {pending_cr = true; continue}
				buffer[length] = value
				length += 1
			}
			if (!ok || count == 0) && pending_cr {
				buffer[length] = '\r'
				length += 1
				pending_cr = false
			}
			bytes = buffer[:length]
		}
		sync.mutex_lock(&p.mutex)
		_, append_error := append(&stream.incoming, ..bytes)
		if append_error != nil {p.capture_failed = true}
		if !ok || count == 0 {stream.done = true}
		sync.mutex_unlock(&p.mutex)
		// Notify even for a chunk containing only a deferred CR, and once more for EOF.
		notify(p)
		if append_error != nil {
			_ = TerminateJobObject(p.job, 1)
		}
		if !ok || count == 0 {return}
	}
}

@(private)
waiter_main :: proc(t: ^thread.Thread) {
	p := (^Process)(t.data)
	_ = w.WaitForSingleObject(p.process, w.INFINITE)
	code: w.DWORD
	ok := bool(w.GetExitCodeProcess(p.process, &code))
	sync.mutex_lock(&p.mutex)
	p.code = ok ? int(code) : -1
	p.exited = true
	sync.mutex_unlock(&p.mutex)
	notify(p)
}

@(private, require_results)
input_write :: proc(p: ^Process, data: []u8) -> Error {
	if p.input == nil {return .Closed}
	offset := 0
	for offset < len(data) {
		count: w.DWORD
		request := w.DWORD(min(len(data) - offset, int(max(w.DWORD))))
		if !bool(w.WriteFile(p.input, &data[offset], request, &count, nil)) || count == 0 {
			close_handle(&p.input)
			return .Closed
		}
		offset += int(count)
	}
	return .None
}

@(private)
writer_main :: proc(t: ^thread.Thread) {
	p := (^Process)(t.data)
	sync.mutex_lock(&p.input_mutex)
	_ = input_write(p, transmute([]u8)p.initial)
	if !p.keep_stdin {close_handle(&p.input)}
	sync.mutex_unlock(&p.input_mutex)
}

// Swaps reusable buffers rather than copying the accumulated output on every host tick.
@(require_results)
poll :: proc(p: ^Process) -> Output {
	if p == nil {return {exited = true}}
	sync.mutex_lock(&p.mutex)
	defer sync.mutex_unlock(&p.mutex)
	for &stream in p.streams {
		clear(&stream.delivered)
		stream.incoming, stream.delivered = stream.delivered, stream.incoming
	}
	return {
		stdout = p.streams[0].delivered[:], stderr = p.streams[1].delivered[:],
		exited = p.exited && p.streams[0].done && p.streams[1].done,
		code = p.capture_failed ? -1 : p.code,
	}
}

@(require_results)
pid :: proc(p: ^Process) -> int {
	return p == nil ? 0 : int(p.id)
}

// Writes synchronously after initial stdin has been sent; Closed includes a broken child pipe.
@(require_results)
write :: proc(p: ^Process, data: []u8) -> Error {
	if p == nil {return .Closed}
	if p.writer != nil {thread.join(p.writer)}
	sync.mutex_lock(&p.input_mutex)
	defer sync.mutex_unlock(&p.input_mutex)
	return input_write(p, data)
}

close_stdin :: proc(p: ^Process) {
	if p == nil {return}
	if p.writer != nil {thread.join(p.writer)}
	sync.mutex_lock(&p.input_mutex)
	close_handle(&p.input)
	sync.mutex_unlock(&p.input_mutex)
}

// Terminating the job also closes inherited pipe ends in every descendant. Wait only for the
// immediate child here; destroy subsequently joins the reader, writer and waiter threads.
kill :: proc(p: ^Process) {
	if p == nil {return}
	if p.job != nil {_ = TerminateJobObject(p.job, 1)}
	if p.process != nil {
		// This fallback also covers failure to assign a suspended process to its job during start.
		if w.WaitForSingleObject(p.process, 0) != w.WAIT_OBJECT_0 {
			_ = w.TerminateProcess(p.process, 1)
			_ = w.WaitForSingleObject(p.process, w.INFINITE)
		}
	}
}

@(require_results)
running :: proc(p: ^Process) -> bool {
	return p != nil && p.process != nil && w.WaitForSingleObject(p.process, 0) == w.WAIT_TIMEOUT
}

destroy :: proc(p: ^Process) {
	if p == nil {return}
	kill(p)
	for &stream in p.streams {
		if stream.worker != nil {
			thread.join(stream.worker)
			thread.destroy(stream.worker)
		}
		close_handle(&stream.handle)
		delete(stream.incoming)
		delete(stream.delivered)
	}
	if p.writer != nil {thread.join(p.writer); thread.destroy(p.writer)}
	if p.waiter != nil {thread.join(p.waiter); thread.destroy(p.waiter)}
	close_handle(&p.input)
	close_handle(&p.process)
	close_handle(&p.job)
	delete(p.initial, p.allocator)
	free(p, p.allocator)
}
