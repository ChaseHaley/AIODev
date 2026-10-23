package pty

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
	return(
		(len(token) >= 2 &&
				token[1] == ':' &&
				((token[0] >= 'a' && token[0] <= 'z') ||
						(token[0] >= 'A' && token[0] <= 'Z'))) ||
		strings.contains_any(token, `/\`)
	)
}

@(private, require_results)
same_directory :: proc(a, b: string) -> bool {
	if b == "" {return false}
	left := strings.trim_right(a, `\/`)
	right := strings.trim_right(b, `\/`)
	return left != "" && strings.equal_fold(left, right)
}

// A PATH entry may name an absolute directory other than the process's current directory. Relative
// entries and the current directory itself are not authorization to choose a different executable.
@(require_results)
path_entry_trusted :: proc(entry, current_directory: string) -> bool {
	text := strings.trim_space(entry)
	if len(text) >= 2 && text[0] == '"' && text[len(text) - 1] == '"' {text = text[1:len(text) - 1]}
	if text == "" || text == "." || text == ".." {return false}
	absolute :=
		len(text) >= 3 &&
		text[1] == ':' &&
		((text[0] >= 'a' && text[0] <= 'z') || (text[0] >= 'A' && text[0] <= 'Z')) &&
		(text[2] == '\\' || text[2] == '/')
	if !absolute && !strings.has_prefix(text, `\\`) {return false}
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
			text := strings.trim_space(entry)
			if len(text) >= 2 && text[0] == '"' && text[len(text) - 1] == '"' {
				text = text[1:len(text) - 1]
			}
			if err := add_directory(&directories, text, allocator); err != nil {return nil, err}
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
	path, join_error := strings.join(directories, ";", allocator)
	if join_error != nil {return "", {.Out_Of_Memory, 0}}
	defer delete(path, allocator)
	wide_path := w.utf8_to_wstring(path, allocator)
	if wide_path == nil {return "", {.Out_Of_Memory, 0}}
	defer delete(wide_path, allocator)
	wide_token := w.utf8_to_wstring(token, allocator)
	if wide_token == nil {return "", {.Out_Of_Memory, 0}}
	defer delete(wide_token, allocator)
	extension := [5]u16{'.', 'e', 'x', 'e', 0}
	buffer: [w.MAX_PATH_WIDE]u16
	n := SearchPathW(
		wide_path,
		wide_token,
		cstring16(&extension[0]),
		u32(len(buffer)),
		raw_data(buffer[:]),
		nil,
	)
	if n == 0 || n >= u32(len(buffer)) {return "", {.Start_Process, w.ERROR_FILE_NOT_FOUND}}
	result, conversion_error := w.utf16_to_utf8(buffer[:n], allocator)
	if conversion_error != nil {return "", {.Out_Of_Memory, 0}}
	return result, {}
}
