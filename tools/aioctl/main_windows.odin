package aioctl

import "core:fmt"
import "core:io"
import "core:log"
import "core:os"
import "core:strings"
import "core:time"
import w "core:sys/windows"
import "aio:control"
import "aio:instance"
import "aio:platform"

@(private)
Paths :: struct { repo, data, executable, pipe, app_id, record: string }

main :: proc() {
	context.logger = log.Logger{procedure = diagnostic, lowest_level = .Warning}
	code := start()
	free_all(context.temp_allocator)
	os.exit(code)
}

@(private)
diagnostic :: proc(_: rawptr, level: log.Level, text: string, _: log.Options, _ := #caller_location) {
	fmt.eprintfln("%s: %s", level >= .Error ? "error" : "warn", text)
}

@(private, require_results)
fail :: proc(message: string) -> int {
	fmt.eprintfln("error: %s", response_body(message))
	return 1
}

@(private, require_results)
os_failure :: proc(call: string) -> bool {
	log.errorf("%s failed (OS code %v)", call, w.GetLastError())
	return false
}

@(private)
close_handle :: proc(h: ^w.HANDLE) {
	if h^ == nil || h^ == w.INVALID_HANDLE_VALUE { return }
	if !bool(w.CloseHandle(h^)) { log.errorf("CloseHandle failed (OS code %v)", w.GetLastError()) }
	h^ = nil
}

@(private, require_results)
wide :: proc(text: string) -> cstring16 {
	return w.utf8_to_wstring(text, context.temp_allocator)
}

@(private, require_results)
make_paths :: proc(name: string) -> (Paths, bool) {
	exe, err := os.get_executable_path(context.temp_allocator)
	if err != nil { return {}, false }
	repo := os.dir(os.dir(exe))
	if !os.exists(fmt.tprintf("%s\\build.ps1", repo)) { return {}, false }
	p := Paths{repo = repo}
	p.data = fmt.tprintf("%s\\build\\verify\\%s", repo, name)
	p.executable = fmt.tprintf("%s\\build\\aiodev-verify.exe", repo)
	app_id, id_error := instance.app_id({name = name}, context.temp_allocator)
	if id_error != nil { return {}, false }
	p.app_id = app_id
	p.record = fmt.tprintf("%s\\instance.ini", p.data)
	pipe, pipe_error := control.pipe_name(p.app_id, context.temp_allocator)
	if pipe_error != .None || !safe_data_path(repo, p.data, name) { return {}, false }
	p.pipe = pipe
	return p, true
}

@(private, require_results)
start :: proc() -> int {
	args, argument_error := instance.command_line(context.allocator)
	if argument_error != .None {
		return fail(fmt.tprintf("cannot read Unicode arguments (%v); check the command line and retry",
			argument_error))
	}
	defer instance.command_line_destroy(args, context.allocator)
	o, error := parse_options(args)
	if error != "" {
		fmt.eprintfln("error: %s\n%s", error, response_body(USAGE))
		return 2
	}
	if o.args[0] == "help" { return show_help(o.args) }
	p, ok := make_paths(o.name)
	if !ok { return fail("cannot locate build.ps1; run this repository's build\\aioctl.exe") }
	if o.args[0] == "launch" { return launch(o, p) }
	r, record_ok := read_record(p)
	if !record_ok {
		if o.args[0] == "doctor" { fmt.println("fail recorded instance: missing or invalid instance.ini") }
		return fail(fmt.tprintf("no recorded instance %s; run aioctl --name %s launch", o.name, o.name))
	}
	h, verified := open_recorded(r, p)
	defer close_handle(&h)
	if o.args[0] == "doctor" { return doctor(o, p, r, verified) }
	if !verified {
		return fail(fmt.tprintf("instance %s has no live recorded identity; run aioctl --name %s launch",
			o.name, o.name))
	}
	if o.args[0] == "stop" { return stop(o, p, r, h) }
	c, err := verified_connect(p, r.pid, 500)
	if err != .None {
		return fail("control pipe unavailable or PID mismatch; run aioctl doctor, then stop and launch")
	}
	defer control.close(&c)
	timeout := 15000
	request, parse_error := control.parse(o.args)
	defer control.request_destroy(&request)
	if parse_error.advice == "" {
		#partial switch q in request {
		case control.Wait: timeout = min(q.timeout_ms, int(max(i32))-1000)+1000
		case control.Run: timeout = min(q.timeout_ms, int(max(i32))-1000)+1000
		}
	}
	response, call_error := control.call(&c, o.args, timeout)
	defer control.response_destroy(&response)
	if call_error != .None {
		return fail(fmt.tprintf("control request failed (%v); run aioctl doctor", call_error))
	}
	if !response.ok && !strings.has_prefix(response.text, "error:") &&
	   !strings.has_prefix(response.text, "FAIL") {
		return fail(response.text)
	}
	fmt.println(response_body(response.text))
	return response.ok ? 0 : 1
}

@(private, require_results)
show_help :: proc(args: []string) -> int {
	command := len(args) == 2 ? args[1] : ""
	switch command {
	case "": fmt.print(USAGE)
	case "launch":
		fmt.print(
			`launch [--fresh] [--settings <file>] [--shell <command>] [--size <cols>x<rows>] [--keep-env]
Starts build\aiodev-verify.exe without activation; refuses an existing named instance.
Data and evidence: <repo>\build\verify\<name>\; --fresh deletes only that directory.
Defaults: pwsh -NoLogo -NoProfile -NoExit with isolated PSReadLine history and predictions off;
repository directory, Cascadia Mono, blink off, 120x32.
History is saved to <data dir>\history.txt; apostrophes in the path are escaped for PowerShell.
--shell is written unchanged; doctor warns: shell history not isolated (custom --shell).
--settings is copied unchanged; doctor warns that its shell history is not isolated.
Size dimensions are 1..1000.
--settings copies a settings file instead; omit --shell and --size when using it.
NO_COLOR is removed unless --keep-env. Tries job breakaway, then retries without it.
Readiness: matching pipe PID, ping, wait text "PS ", wait idle; overall deadline 20 seconds.
Failure stops the launched process and prints log tails. Success:
launched <name> pid=<pid> ready=<ms>ms build=<id> data=<dir>
`,
		)
		return 0
	case "doctor":
		fmt.print(`doctor
Read-only checks: recorded PID, creation time and image; pipe PID and reply; isolated app ID;
source freshness; launch NO_COLOR decision; isolated shell history; running session and visible window.
One ok, warn, or fail line per check. Any fail exits 1; warnings alone exit 0.
`)
		return 0
	case "stop":
		fmt.print(`stop
Requests tray quit, waits 5 seconds, then terminates only the verified recorded process if needed.
Checks surviving child processes; keeps the data directory and logs. Any survivors fail.
Output: stopped <name> pid=<pid> forced=<true|false> children=<n> data=<dir>
`)
		return 0
	}
	b, allocation_error := strings.builder_make()
	if allocation_error != nil { return fail("not enough memory for help; retry") }
	defer strings.builder_destroy(&b)
	err := control.help(&b, command)
	if err != .None {
		fmt.eprintln("error: unknown help command; use help")
		return 2
	}
	fmt.print(strings.to_string(b))
	return 0
}

@(private, require_results)
read_record :: proc(p: Paths) -> (Record, bool) {
	data, err := os.read_entire_file(p.record, context.temp_allocator)
	if err != nil { return {}, false }
	r, ok := parse_record(string(data))
	return r, ok && strings.equal_fold(r.executable, p.executable)
}

@(private, require_results)
creation_time :: proc(h: w.HANDLE) -> (u64, bool) {
	created, exited, kernel, user: w.FILETIME
	if !bool(w.GetProcessTimes(h, &created, &exited, &kernel, &user)) {
		return 0, os_failure("GetProcessTimes")
	}
	return u64(created.dwHighDateTime)<<32 | u64(created.dwLowDateTime), true
}

@(private, require_results)
matches_record :: proc(h: w.HANDLE, r: Record, p: Paths) -> bool {
	buffer: [32768]u16
	size := u32(len(buffer))
	if !bool(QueryFullProcessImageNameW(h, 0, raw_data(buffer[:]), &size)) {
		return os_failure("QueryFullProcessImageNameW")
	}
	text: [131072]u8
	image := w.utf16_to_utf8(text[:], buffer[:size])
	if image == "" { return os_failure("WideCharToMultiByte") }
	created, ok := creation_time(h)
	return ok && created == r.created && strings.equal_fold(image, p.executable) &&
	       strings.equal_fold(r.executable, p.executable)
}

@(private, require_results)
open_recorded :: proc(r: Record, p: Paths) -> (w.HANDLE, bool) {
	access := u32(w.PROCESS_QUERY_LIMITED_INFORMATION | w.SYNCHRONIZE | w.PROCESS_TERMINATE)
	h := w.OpenProcess(access, false, r.pid)
	if h == nil {
		if w.GetLastError() != w.ERROR_INVALID_PARAMETER {
			log.errorf("OpenProcess failed: %v", w.GetLastError())
		}
		return nil, false
	}
	status := w.WaitForSingleObject(h, 0)
	if status == w.WAIT_FAILED { log.errorf("WaitForSingleObject failed: %v", w.GetLastError()) }
	return h, status == w.WAIT_TIMEOUT && matches_record(h, r, p)
}

@(private, require_results)
verified_connect :: proc(p: Paths, pid: u32, timeout: int) -> (control.Client, control.Error) {
	c, err := control.connect(p.pipe, timeout)
	if err != .None { return {}, err }
	if c.process_id != pid {
		control.close(&c)
		return {}, .Invalid_Argument
	}
	return c, .None
}

@(private, require_results)
no_reparse :: proc(path: string, missing_ok: bool) -> bool {
	name := wide(path)
	if name == nil { return false }
	attributes := w.GetFileAttributesW(name)
	if attributes == w.INVALID_FILE_ATTRIBUTES {
		code := w.GetLastError()
		if missing_ok && (code == w.ERROR_FILE_NOT_FOUND || code == w.ERROR_PATH_NOT_FOUND) { return true }
		return os_failure("GetFileAttributesW")
	}
	return attributes & w.FILE_ATTRIBUTE_REPARSE_POINT == 0
}

@(private, require_results)
safe_tree :: proc(path: string) -> bool {
	if !no_reparse(path, true) { return false }
	if !os.exists(path) { return true }
	entries, err := os.read_directory_by_path(path, 0, context.temp_allocator)
	if err != nil { log.errorf("reading %s failed: %v", path, err); return false }
	for e in entries {
		if !no_reparse(e.fullpath, false) { return false }
		if e.type == .Directory && !safe_tree(e.fullpath) { return false }
	}
	return true
}

@(private, require_results)
remove_tree :: proc(path: string) -> bool {
	if !no_reparse(path, true) { return false }
	if !os.exists(path) { return true }
	entries, err := os.read_directory_by_path(path, 0, context.temp_allocator)
	if err != nil { log.errorf("reading %s failed: %v", path, err); return false }
	for e in entries {
		if !no_reparse(e.fullpath, false) { return false }
		if e.type == .Directory {
			if !remove_tree(e.fullpath) { return false }
		} else if error := os.remove(e.fullpath); error != nil {
			log.errorf("removing %s failed: %v", e.fullpath, error)
			return false
		}
	}
	if error := os.remove(path); error != nil {
		log.errorf("removing %s failed: %v", path, error)
		return false
	}
	return true
}

@(private, require_results)
launch_environment :: proc(keep: bool) -> ([]u16, bool) {
	parent := w.GetEnvironmentStringsW()
	if parent == nil { return nil, os_failure("GetEnvironmentStringsW") }
	defer {
		if !bool(w.FreeEnvironmentStringsW(parent)) {
			log.errorf("FreeEnvironmentStringsW failed: %v", w.GetLastError())
		}
	}
	block := cast([^]u16)parent
	length := 0
	for block[length] != 0 {
		for block[length] != 0 { length += 1 }
		length += 1
	}
	return environment_block(block[:max(2, length+1)], keep)
}

@(private, require_results)
spawn :: proc(o: Options, p: Paths) -> (w.PROCESS_INFORMATION, bool) {
	log_path := wide(fmt.tprintf("%s\\stdout.log", p.data))
	null_path := wide("NUL")
	command_text := fmt.tprintf("\"%s\" --instance %s --data-dir \"%s\" --no-activate",
		p.executable, o.name, p.data)
	if log_path == nil || null_path == nil { return {}, false }
	sa := w.SECURITY_ATTRIBUTES{nLength = size_of(w.SECURITY_ATTRIBUTES), bInheritHandle = true}
	output := w.CreateFileW(log_path, w.GENERIC_WRITE, w.FILE_SHARE_READ | w.FILE_SHARE_WRITE,
		&sa, w.CREATE_ALWAYS, w.FILE_ATTRIBUTE_NORMAL, nil)
	if output == w.INVALID_HANDLE_VALUE { return {}, os_failure("CreateFileW(stdout.log)") }
	defer close_handle(&output)
	input := w.CreateFileW(null_path, w.GENERIC_READ, w.FILE_SHARE_READ | w.FILE_SHARE_WRITE,
		&sa, w.OPEN_EXISTING, w.FILE_ATTRIBUTE_NORMAL, nil)
	if input == w.INVALID_HANDLE_VALUE { return {}, os_failure("CreateFileW(NUL)") }
	defer close_handle(&input)
	environment, env_ok := launch_environment(o.keep_env)
	if !env_ok { return {}, false }
	defer delete(environment)
	return spawn_redirected(p.executable, command_text, p.repo, environment, input, output)
}

@(require_results)
spawn_redirected :: proc(
	executable, command_line, directory: string, environment: []u16, input, output: w.HANDLE,
) -> (w.PROCESS_INFORMATION, bool) {
	exe := w.utf8_to_wstring(executable, context.allocator)
	defer delete(exe)
	repo := w.utf8_to_wstring(directory, context.allocator)
	defer delete(repo)
	command := w.utf8_to_wstring(command_line, context.allocator)
	defer delete(command)
	if exe == nil || repo == nil || command == nil { return {}, false }
	size: w.SIZE_T
	if bool(InitializeProcThreadAttributeList(nil, 1, 0, &size)) ||
	   w.GetLastError() != w.ERROR_INSUFFICIENT_BUFFER {
		return {}, os_failure("InitializeProcThreadAttributeList(size)")
	}
	storage, allocation_error := make([]u8, int(size))
	if allocation_error != nil { return {}, false }
	defer delete(storage)
	attributes := raw_data(storage)
	if !bool(InitializeProcThreadAttributeList(attributes, 1, 0, &size)) {
		return {}, os_failure("InitializeProcThreadAttributeList")
	}
	defer DeleteProcThreadAttributeList(attributes)
	handles := [?]w.HANDLE{input, output}
	if !bool(UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
		&handles[0], size_of(handles), nil, nil)) {
		return {}, os_failure("UpdateProcThreadAttribute(handle list)")
	}
	startup := STARTUPINFOEXW{
		StartupInfo = {cb = size_of(STARTUPINFOEXW), dwFlags = w.STARTF_USESTDHANDLES,
			hStdInput = input, hStdOutput = output, hStdError = output},
		lpAttributeList = attributes,
	}
	flags := u32(w.CREATE_NO_WINDOW | w.CREATE_UNICODE_ENVIRONMENT |
		w.CREATE_SUSPENDED | w.EXTENDED_STARTUPINFO_PRESENT)
	info: w.PROCESS_INFORMATION
	if !bool(w.CreateProcessW(exe, command, nil, nil, true, flags | w.CREATE_BREAKAWAY_FROM_JOB,
		raw_data(environment), repo, &startup.StartupInfo, &info)) {
		code := w.GetLastError()
		log.warnf("CreateProcessW with job breakaway failed: %v; retrying without breakaway", code)
		delete(command)
		command = w.utf8_to_wstring(command_line, context.allocator)
		if command == nil { return {}, false }
		if !bool(w.CreateProcessW(exe, command, nil, nil, true, flags,
			raw_data(environment), repo, &startup.StartupInfo, &info)) {
			return {}, os_failure("CreateProcessW")
		}
	}
	return info, true
}

@(private, require_results)
terminate_and_wait :: proc(h: w.HANDLE) -> bool {
	status := w.WaitForSingleObject(h, 0)
	if status == w.WAIT_OBJECT_0 { return true }
	if status == w.WAIT_FAILED { return os_failure("WaitForSingleObject") }
	if !bool(w.TerminateProcess(h, 1)) { return os_failure("TerminateProcess") }
	result := w.WaitForSingleObject(h, 5000)
	if result == w.WAIT_FAILED { return os_failure("WaitForSingleObject") }
	return result == w.WAIT_OBJECT_0
}

@(private)
log_tail :: proc(path: string) {
	file, err := os.open(path)
	if err != nil { fmt.eprintfln("log %s: unavailable (%v)", path, err); return }
	defer {
		if error := os.close(file); error != nil { log.errorf("closing log tail failed: %v", error) }
	}
	size, size_error := os.file_size(file)
	if size_error != nil { fmt.eprintfln("log %s: cannot read size (%v)", path, size_error); return }
	buffer: [4096]u8
	n, read_error := os.read_at(file, buffer[:min(size, i64(len(buffer)))], max(0, size-i64(len(buffer))))
	if read_error != nil && read_error != os.Error(io.Error.EOF) {
		fmt.eprintfln("log %s: cannot read tail (%v)", path, read_error)
		return
	}
	text := strings.trim_space(string(buffer[:n]))
	start, lines := len(text), 0
	for start > 0 && lines < 12 {
		start -= 1
		if text[start] == '\n' { lines += 1 }
	}
	fmt.eprintfln("log %s:\n%s", path, text[start:])
}

@(private, require_results)
launch :: proc(o: Options, p: Paths) -> int {
	if !no_reparse(fmt.tprintf("%s\\build", p.repo), false) ||
	   !no_reparse(fmt.tprintf("%s\\build\\verify", p.repo), true) || !safe_tree(p.data) {
		return fail("data path has a reparse point or cannot be read; inspect build\\verify before retrying")
	}
	if err := os.mkdir_all(fmt.tprintf("%s\\build\\verify", p.repo)); err != nil {
		return fail(fmt.tprintf("cannot create build\\verify (%v); check directory permissions", err))
	}
	lock_path := wide(fmt.tprintf("%s\\build\\verify\\%s.lock", p.repo, o.name))
	if lock_path == nil { return fail("not enough memory; retry launch") }
	lock := w.CreateFileW(lock_path, w.GENERIC_WRITE, 0, nil, w.OPEN_ALWAYS, w.FILE_ATTRIBUTE_NORMAL, nil)
	if lock == w.INVALID_HANDLE_VALUE {
		log.errorf("CreateFileW(launch lock) failed: %v", w.GetLastError())
		return fail("another launch is active or the lock is inaccessible; wait and retry")
	}
	defer close_handle(&lock)
	exists, instance_error := platform.instance_running(p.app_id)
	if instance_error != .None {
		return fail("cannot check the instance mutex; inspect OS errors before retrying")
	}
	if exists {
		return fail(fmt.tprintf("instance %s is already running; run aioctl --name %s stop", o.name, o.name))
	}
	if r, ok := read_record(p); ok {
		h, alive := open_recorded(r, p)
		defer close_handle(&h)
		if alive {
			return fail(fmt.tprintf("recorded process is still running; run aioctl --name %s stop", o.name))
		}
	}
	text: string
	if o.settings != "" {
		data, err := os.read_entire_file(o.settings, context.temp_allocator)
		if err != nil { return fail(fmt.tprintf("cannot read --settings file (%v); check the path", err)) }
		text = string(data)
	} else {
		generated, ok := settings_text(o, p.repo, p.data, context.temp_allocator)
		if !ok { return fail("cannot generate settings; check --shell and --size") }
		text = generated
	}
	if o.fresh && !remove_tree(p.data) {
		return fail("cannot clear the data directory; inspect permissions and retry")
	}
	if err := os.mkdir_all(p.data); err != nil {
		return fail(fmt.tprintf("cannot create data directory: %v; check permissions", err))
	}
	if err := os.write_entire_file(fmt.tprintf("%s\\settings.ini", p.data), text); err != nil {
		return fail(fmt.tprintf("cannot write settings (%v); check data-directory permissions", err))
	}
	success := false
	defer if !success {
		log_tail(fmt.tprintf("%s\\stdout.log", p.data))
		log_tail(fmt.tprintf("%s\\logs\\aiodev.%s.log", p.data, o.name))
	}
	start_time := time.tick_now()
	info, spawned := spawn(o, p)
	if !spawned { return fail("could not start the verify executable; rebuild with build.ps1 verify") }
	defer close_handle(&info.hProcess)
	defer close_handle(&info.hThread)
	defer if !success {
		if !terminate_and_wait(info.hProcess) {
			fmt.eprintln("error: cleanup failed; inspect the recorded PID before retrying")
		}
	}
	created, created_ok := creation_time(info.hProcess)
	if !created_ok { return fail("cannot record launch identity; inspect OS errors and retry") }
	// Record ownership before the child can create a session.
	history := o.shell != "" ? "custom-shell" : (o.settings != "" ? "settings-file" : "isolated")
	record := fmt.tprintf("pid=%d\ncreated=%d\nexecutable=%s\nno_color=%s\nhistory=%s\n",
		info.dwProcessId, created, p.executable, o.keep_env ? "kept" : "removed", history)
	if err := os.write_entire_file(p.record, record); err != nil {
		return fail(fmt.tprintf("cannot record launch (%v); check directory permissions", err))
	}
	if w.ResumeThread(info.hThread) == max(w.DWORD) {
		log.errorf("ResumeThread failed: %v", w.GetLastError())
		return fail("cannot resume the launched process; inspect OS errors and retry")
	}
	deadline :: 20000
	connect_timeout := deadline-int(time.tick_since(start_time)/time.Millisecond)
	if connect_timeout <= 0 { return fail("launch deadline expired; inspect the log tails") }
	c, connection_error := verified_connect(p, info.dwProcessId, connect_timeout)
	if connection_error != .None {
		return fail(fmt.tprintf("readiness pipe failed (%v); inspect the log tails", connection_error))
	}
	defer control.close(&c)
	build := "unknown"
	steps := [?][]string{{"ping"}, {"wait", "text", "PS ", "--timeout", "15000"},
		{"wait", "idle", "300", "--timeout", "15000"}}
	for step in steps {
		remaining := deadline-int(time.tick_since(start_time)/time.Millisecond)
		if remaining <= 0 { return fail("launch deadline expired; inspect the log tails") }
		response, err := control.call(&c, step, remaining)
		defer control.response_destroy(&response)
		if err != .None || !response.ok {
			return fail(fmt.tprintf("readiness %s failed (%v): %s; inspect logs",
				step[0], err, response.text))
		}
		if step[0] == "ping" {
			app_id, id_ok := response_field(response.text, "app", context.temp_allocator)
			if !id_ok || app_id != p.app_id { return fail("unexpected app identity; inspect the log tails") }
			data, data_ok := response_field(response.text, "data", context.temp_allocator)
			if !data_ok || !strings.equal_fold(data, p.data) {
				return fail("unexpected data directory; inspect the log tails")
			}
			build_id, build_ok := response_field(response.text, "build", context.temp_allocator)
			if !build_ok { return fail("missing build identity; rebuild with build.ps1 verify") }
			build = build_id
		}
	}
	success = true
	fmt.printfln("launched %s pid=%d ready=%dms build=%s data=%s", o.name, info.dwProcessId,
		int(time.tick_since(start_time)/time.Millisecond), build, p.data)
	return 0
}

@(private, require_results)
child_count :: proc(pid: u32) -> (int, bool) {
	snapshot := w.CreateToolhelp32Snapshot(w.TH32CS_SNAPPROCESS, 0)
	if snapshot == w.INVALID_HANDLE_VALUE { return 0, os_failure("CreateToolhelp32Snapshot") }
	defer close_handle(&snapshot)
	entry := w.PROCESSENTRY32W{dwSize = size_of(w.PROCESSENTRY32W)}
	count := 0
	ok := bool(w.Process32FirstW(snapshot, &entry))
	for ok {
		if entry.th32ParentProcessID == pid { count += 1 }
		ok = bool(w.Process32NextW(snapshot, &entry))
	}
	if w.GetLastError() != w.ERROR_NO_MORE_FILES { return 0, os_failure("Process32 enumeration") }
	return count, true
}

@(private, require_results)
stop :: proc(o: Options, p: Paths, r: Record, h: w.HANDLE) -> int {
	c, err := verified_connect(p, r.pid, 500)
	if err == .None {
		response, call_error := control.call(&c, {"tray", "quit"}, 1000)
		if call_error != .None || !response.ok {
			log.warnf("tray quit failed (%v): %s; waiting before forced cleanup", call_error, response.text)
		}
		control.response_destroy(&response)
		control.close(&c)
	} else { log.warnf("quit pipe unavailable (%v); waiting before forced cleanup", err) }
	result := w.WaitForSingleObject(h, 5000)
	if result == w.WAIT_FAILED {
		log.errorf("WaitForSingleObject failed: %v", w.GetLastError())
		return fail("cannot wait for exit; retry stop")
	}
	forced := result == w.WAIT_TIMEOUT
	if forced && (!matches_record(h, r, p) || !terminate_and_wait(h)) {
		return fail("cannot safely terminate the recorded process; inspect its PID and image before retrying")
	}
	count, counted := child_count(r.pid)
	if !counted { return fail("cannot enumerate surviving children; inspect OS errors") }
	started := time.tick_now()
	for count > 0 && time.tick_since(started) < 2*time.Second {
		time.sleep(20*time.Millisecond)
		count, counted = child_count(r.pid)
		if !counted { return fail("cannot enumerate surviving children; inspect OS errors") }
	}
	fmt.printfln("stopped %s pid=%d forced=%t children=%d data=%s", o.name, r.pid, forced, count, p.data)
	if count > 0 { return fail("child processes remain; inspect their parent PID before cleanup") }
	return 0
}

@(private, require_results)
check_line :: proc(ok: bool, description: string) -> bool {
	fmt.printfln("%s %s", ok ? "ok" : "fail", description)
	return ok
}

@(private, require_results)
doctor :: proc(o: Options, p: Paths, r: Record, verified: bool) -> int {
	failed := !check_line(verified, "recorded PID alive, creation time and repository image match")
	c, err := verified_connect(p, r.pid, 500)
	defer control.close(&c)
	pipe_ok := err == .None && verified
	ping: control.Response
	if pipe_ok {
		ping, err = control.call(&c, {"ping"}, 1000)
		pipe_ok = err == .None && ping.ok
	}
	defer control.response_destroy(&ping)
	failed = !check_line(pipe_ok, "pipe answers and server PID matches recorded PID") || failed
	app_id, id_ok := response_field(ping.text, "app", context.temp_allocator)
	isolated := pipe_ok && id_ok && app_id == p.app_id
	failed = !check_line(isolated, "instance is isolated from the owner's default") || failed
	if !fresh_build(p) { failed = true }
	if r.keep_env {
		fmt.println("warn NO_COLOR kept at launch; relaunch without --keep-env for escape sequences")
	} else {
		fmt.println("ok NO_COLOR removed at launch")
	}
	switch r.history {
	case .Isolated: fmt.println("ok shell history isolated")
	case .Custom_Shell: fmt.println("warn shell history not isolated (custom --shell)")
	case .Settings_File: fmt.println("warn shell history not isolated (custom --settings)")
	case .Unknown: fmt.println("warn shell history isolation unknown; relaunch to record it")
	}
	state_ok := false
	if pipe_ok {
		response, state_error := control.call(&c, {"state"}, 1000)
		defer control.response_destroy(&response)
		state_ok = state_error == .None && response.ok &&
		           state_has(response.text, "session.status=running") &&
		           state_has(response.text, "window.visible=true")
	}
	failed = !check_line(state_ok, "session running and window visible") || failed
	if failed {
		return fail(fmt.tprintf("instance %s needs attention; inspect checks, "+
			"then aioctl --name %s stop or launch",
			o.name, o.name))
	}
	return 0
}

@(private)
state_has :: proc(text, line: string) -> bool {
	remaining := text
	for entry in strings.split_lines_iterator(&remaining) {
		if entry == line { return true }
	}
	return false
}

@(private, require_results)
fresh_build :: proc(p: Paths) -> bool {
	exe, err := os.stat(p.executable, context.temp_allocator)
	if err != nil { fmt.println("fail verify executable missing; run build.ps1 verify"); return false }
	newest_time := time.time_to_unix_nano(exe.modification_time)
	newest := ""
	walker := os.walker_create(fmt.tprintf("%s\\src", p.repo))
	defer os.walker_destroy(&walker)
	for info in os.walker_walk(&walker) {
		if path, error := os.walker_error(&walker); error != nil {
			fmt.printfln("fail source scan %s: %v; check permissions", path, error)
			return false
		}
		if !no_reparse(info.fullpath, false) {
			fmt.println("fail cannot check source freshness through reparse points")
			return false
		}
		stamp := time.time_to_unix_nano(info.modification_time)
		if strings.has_suffix(info.name, ".odin") && stamp > newest_time {
			newest_time = stamp
			newest = strings.clone(info.fullpath, context.temp_allocator) or_else "<allocation failed>"
		}
	}
	if path, error := os.walker_error(&walker); error != nil {
		fmt.printfln("fail source scan %s: %v; check permissions", path, error)
		return false
	}
	if newest != "" { fmt.printfln("warn stale build: %s is newer; run build.ps1 verify", newest)
	} else { fmt.println("ok verify build is newer than src/*.odin") }
	return true
}
