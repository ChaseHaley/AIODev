package pty

import "aio:localpath"
import "base:runtime"
import "core:os"
import "core:strings"
import w "core:sys/windows"

// The first token of a Windows command line names the module when `lpApplicationName` is nil.
// A quoted token ends at its closing quote; paths cannot contain quotes, so no escape handling is
// needed here. Callers still hand the untouched command line to CreateProcessW.
@(require_results)
executable_token :: proc(command_line: string) -> string {
	start := 0
	for start < len(command_line) &&
	    (command_line[start] == ' ' || command_line[start] == '\t') {start += 1}
	if start == len(command_line) {return ""}
	if command_line[start] == '"' {
		end := start + 1
		for end < len(command_line) && command_line[end] != '"' {end += 1}
		return command_line[start + 1:end]
	}
	end := start
	for end < len(command_line) && command_line[end] != ' ' && command_line[end] != '\t' {end += 1}
	return command_line[start:end]
}

// True when the token names a path (absolute, drive-relative, UNC or relative) instead of a bare
// module name. Explicit paths stay explicit; only bare names are resolved by the terminal.
@(require_results)
is_explicit_path :: proc(token: string) -> bool {
	return localpath.has_drive_prefix(token) || strings.contains_any(token, `/\`)
}

@(private, require_results)
same_directory :: proc(a, b: string) -> bool {
	if b == "" {return false}
	left := strings.trim_right(a, `\/`)
	right := strings.trim_right(b, `\/`)
	return left != "" && strings.equal_fold(left, right)
}

// A PATH entry's directory: surrounding space and one pair of quotes removed.
@(private, require_results)
path_entry_text :: proc(entry: string) -> string {
	text := strings.trim_space(entry)
	if len(text) >= 2 && text[0] == '"' && text[len(text) - 1] == '"' {text = text[1:len(text) - 1]}
	return text
}

// A PATH entry may name an absolute directory other than the process's current directory. Relative
// entries and the current directory itself are not authorization to choose a different executable.
@(require_results)
path_entry_trusted :: proc(entry, current_directory: string) -> bool {
	text := path_entry_text(entry)
	if text == "" || text == "." || text == ".." {return false}
	if !localpath.is_drive_absolute(text) && !strings.has_prefix(text, `\\`) {return false}
	return !same_directory(text, current_directory)
}

@(private, require_results)
current_directory :: proc(allocator: runtime.Allocator) -> string {
	buffer: [w.MAX_PATH_WIDE]u16
	n := w.GetCurrentDirectoryW(u32(len(buffer)), raw_data(buffer[:]))
	if n == 0 || n >= u32(len(buffer)) {return ""}
	text, err := w.utf16_to_utf8(buffer[:n], allocator)
	if err != nil {return ""}
	return text
}

@(private, require_results)
add_directory :: proc(
	list: ^[dynamic]string,
	directory: string,
	allocator: runtime.Allocator,
) -> runtime.Allocator_Error {
	if directory == "" {return nil}
	copy, err := strings.clone(directory, allocator)
	if err != nil {return err}
	if _, append_err := append(list, copy); append_err != nil {
		delete(copy, allocator)
		return append_err
	}
	return nil
}

// The directories a bare shell name may come from: the application directory, the Windows system
// directories, and absolute PATH entries other than the current directory. The current directory
// and relative PATH entries are deliberately absent, so a project directory cannot choose the
// executable the terminal launches.
@(require_results)
search_directories :: proc(
	allocator := context.allocator,
) -> (
	[]string,
	runtime.Allocator_Error,
) {
	directories := make([dynamic]string, 0, 8, allocator)
	success := false
	defer if !success {
		for directory in directories {delete(directory, allocator)}
		delete(directories)
	}
	buffer: [w.MAX_PATH_WIDE]u16
	n := w.GetModuleFileNameW(nil, raw_data(buffer[:]), u32(len(buffer)))
	if n > 0 && n < u32(len(buffer)) {
		last := int(n)
		for last > 0 && buffer[last - 1] != '\\' && buffer[last - 1] != '/' {last -= 1}
		if last >= 2 {
			directory, err := w.utf16_to_utf8(buffer[:last], allocator)
			if err != nil {return nil, err}
			defer delete(directory, allocator)
			if err = add_directory(&directories, directory, allocator); err != nil {return nil, err}
		}
	}
	n = GetSystemDirectoryW(raw_data(buffer[:]), u32(len(buffer)))
	if n > 0 && n < u32(len(buffer)) {
		directory, err := w.utf16_to_utf8(buffer[:n], allocator)
		if err != nil {return nil, err}
		defer delete(directory, allocator)
		if err = add_directory(&directories, directory, allocator); err != nil {return nil, err}
	}
	n = GetWindowsDirectoryW(raw_data(buffer[:]), u32(len(buffer)))
	if n > 0 && n < u32(len(buffer)) {
		directory, err := w.utf16_to_utf8(buffer[:n], allocator)
		if err != nil {return nil, err}
		defer delete(directory, allocator)
		if err = add_directory(&directories, directory, allocator); err != nil {return nil, err}
	}
	if path, found := os.lookup_env("PATH", allocator); found {
		defer delete(path, allocator)
		cwd := current_directory(allocator)
		defer delete(cwd, allocator)
		rest := path
		for entry in strings.split_by_byte_iterator(&rest, ';') {
			if !path_entry_trusted(entry, cwd) {continue}
			if err := add_directory(&directories, path_entry_text(entry), allocator); err != nil {
				return nil, err
			}
		}
	}
	success = true
	return directories[:], nil
}

// Resolves the command line's executable token once. Explicit paths are returned unchanged. A bare
// name is searched only in `directories`, mirroring CreateProcess's trusted directories without
// its current-directory step.
@(require_results)
resolve_executable :: proc(
	command_line: string,
	directories: []string,
	allocator := context.allocator,
) -> (
	string,
	Spawn_Error,
) {
	token := executable_token(command_line)
	if token == "" {return "", {.Invalid_Argument, 0}}
	if is_explicit_path(token) {
		copy, err := strings.clone(token, allocator)
		if err != nil {return "", {.Out_Of_Memory, 0}}
		return copy, {}
	}
	if len(directories) == 0 {return "", {.Start_Process, w.ERROR_FILE_NOT_FOUND}}
	return search_path(token, directories, ".exe", allocator)
}

// Finds `name` in `directories`, adding `extension` when the name has none.
@(private, require_results)
search_path :: proc(name: string, directories: []string, extension: string, allocator: runtime.Allocator) -> (
	string,
	Spawn_Error,
) {
	path, join_error := strings.join(directories, ";", allocator)
	if join_error != nil {return "", {.Out_Of_Memory, 0}}
	defer delete(path, allocator)
	wide_path := w.utf8_to_wstring(path, allocator)
	if wide_path == nil {return "", {.Out_Of_Memory, 0}}
	defer delete(wide_path, allocator)
	wide_name := w.utf8_to_wstring(name, allocator)
	if wide_name == nil {return "", {.Out_Of_Memory, 0}}
	defer delete(wide_name, allocator)
	wide_extension := w.utf8_to_wstring(extension, allocator)
	if wide_extension == nil {return "", {.Out_Of_Memory, 0}}
	defer delete(wide_extension, allocator)
	buffer: [w.MAX_PATH_WIDE]u16
	n := SearchPathW(wide_path, wide_name, wide_extension, u32(len(buffer)), raw_data(buffer[:]), nil)
	if n == 0 || n >= u32(len(buffer)) {return "", {.Start_Process, w.ERROR_FILE_NOT_FOUND}}
	result, conversion_error := w.utf16_to_utf8(buffer[:n], allocator)
	if conversion_error != nil {return "", {.Out_Of_Memory, 0}}
	return result, {}
}

// What a command line launches. nil: the line names no executable at all.
Executable :: union {
	Explicit_Executable,
	Searched_Executable,
}

// A path spelled by the command line, left for CreateProcess to find; borrows the command line.
Explicit_Executable :: struct {
	token: string,
}

// A bare name found in the trusted search directories; owns its path.
Searched_Executable :: struct {
	path: string,
}

// The one resolution order every caller uses: executable token, then explicit-path spelling, then
// the trusted directories for a bare name. A failed bare-name search reports Start_Process with the
// OS code; Out_Of_Memory means the lookup itself could not run.
@(require_results)
resolve_command :: proc(command_line: string, allocator := context.allocator) -> (Executable, Spawn_Error) {
	token := executable_token(command_line)
	if token == "" {return nil, {}}
	if is_explicit_path(token) {return Explicit_Executable{token}, {}}
	directories, directories_error := search_directories(allocator)
	if directories_error != nil {return nil, {.Out_Of_Memory, 0}}
	defer {
		for directory in directories {delete(directory, allocator)}
		delete(directories, allocator)
	}
	path, err := resolve_executable(command_line, directories, allocator)
	if err.kind != .None {return nil, err}
	return Searched_Executable{path}, {}
}

executable_destroy :: proc(executable: ^Executable, allocator := context.allocator) {
	if searched, ok := executable.(Searched_Executable); ok {delete(searched.path, allocator)}
	executable^ = nil
}

// What a link program's command line runs: an executable, or a batch script, which only cmd.exe runs.
Program :: struct {
	// Owned.
	path:  string,
	batch: bool,
}

// Resolves a link program as resolve_command resolves a shell, except that a bare name may also be a
// .com, .bat or .cmd file: each directory in turn is tried in Windows' default PATHEXT order, as a
// shell searches, so VS Code's `code` is the first directory's code.cmd. An explicit path is kept as
// written.
@(require_results)
resolve_program :: proc(command_line: string, allocator := context.allocator) -> (Program, Spawn_Error) {
	directories, directories_error := search_directories(allocator)
	if directories_error != nil {return {}, {.Out_Of_Memory, 0}}
	defer {
		for directory in directories {delete(directory, allocator)}
		delete(directories, allocator)
	}
	return resolve_program_in(command_line, directories, allocator)
}

// resolve_program over `directories` from search_directories, so a caller resolving several programs
// reads the search directories once.
@(require_results)
resolve_program_in :: proc(
	command_line: string,
	directories: []string,
	allocator := context.allocator,
) -> (
	Program,
	Spawn_Error,
) {
	token := executable_token(command_line)
	if token == "" {return {}, {.Invalid_Argument, 0}}
	if is_explicit_path(token) {
		path, err := strings.clone(token, allocator)
		if err != nil {return {}, {.Out_Of_Memory, 0}}
		return {path, is_batch(path)}, {}
	}
	for directory in directories {
		for extension in ([?]string{".com", ".exe", ".bat", ".cmd"}) {
			path, err := search_path(token, {directory}, extension, allocator)
			if err.kind == .Start_Process {continue}
			if err.kind != .None {return {}, err}
			return {path, is_batch(path)}, {}
		}
	}
	return {}, {.Start_Process, w.ERROR_FILE_NOT_FOUND}
}

program_destroy :: proc(program: ^Program, allocator := context.allocator) {
	delete(program.path, allocator)
	program^ = {}
}

@(private, require_results)
is_batch :: proc(path: string) -> bool {
	lower := strings.to_lower(path, context.temp_allocator)
	return strings.has_suffix(lower, ".bat") || strings.has_suffix(lower, ".cmd")
}

// The text after the command line's executable token, which borrows it.
@(require_results)
command_arguments :: proc(command_line: string) -> string {
	token := executable_token(command_line)
	if token == "" {return ""}
	start := strings.index(command_line, token) + len(token)
	if start < len(command_line) && command_line[start] == '"' {start += 1}
	return strings.trim_left(command_line[start:], " \t")
}

// The command line that runs batch script `script` with `arguments` through the system's cmd.exe. /d
// skips the user's AutoRun commands, and /s with the outer quotes hands cmd the rest as written.
@(require_results)
batch_command_line :: proc(
	script, arguments: string,
	allocator := context.allocator,
) -> (
	string,
	Spawn_Error,
) {
	buffer: [w.MAX_PATH_WIDE]u16
	n := GetSystemDirectoryW(raw_data(buffer[:]), u32(len(buffer)))
	if n == 0 || n >= u32(len(buffer)) {return "", {.Start_Process, u32(w.GetLastError())}}
	system, err := w.utf16_to_utf8(buffer[:n], context.temp_allocator)
	if err != nil {return "", {.Out_Of_Memory, 0}}
	line, line_error := strings.concatenate(
		{`"`, system, `\cmd.exe" /d /s /c ""`, script, `" `, arguments, `"`},
		allocator,
	)
	if line_error != nil {return "", {.Out_Of_Memory, 0}}
	return line, {}
}
