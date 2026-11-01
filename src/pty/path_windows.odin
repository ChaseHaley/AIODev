package pty

import "aio:links"
import "core:log"
import "core:strings"
import "core:unicode/utf8"
import w "core:sys/windows"

// A working directory must stay on this machine. UNC, device, and drive-relative forms are refused
// before any filesystem access. An accepted path is resolved and its final target checked, so a
// junction or mapped drive cannot smuggle in a remote share. Relative paths stay allowed and are
// resolved against this process's current directory.
@(require_results)
working_directory_is_local :: proc(path: string) -> bool {
	if path == "" || strings.contains(path, "\x00") || !utf8.valid_string(path) {
		return false
	}
	if !local_path_shape(path) {return false}
	wide := w.utf8_to_wstring(path, context.temp_allocator)
	if wide == nil {
		log.error("pty: converting the working directory failed")
		return false
	}
	full: [32768]u16
	n := w.GetFullPathNameW(wide, u32(len(full)), cstring16(&full[0]), nil)
	if n == 0 || n >= u32(len(full)) {
		log.warnf("pty: GetFullPathNameW failed (OS code %v)", w.GetLastError())
		return false
	}
	if !local_absolute_wide(full[:n]) {return false}
	handle := w.CreateFileW(
		cstring16(&full[0]),
		0,
		w.FILE_SHARE_READ | w.FILE_SHARE_WRITE | w.FILE_SHARE_DELETE,
		nil,
		w.OPEN_EXISTING,
		w.FILE_FLAG_BACKUP_SEMANTICS,
		nil,
	)
	if handle == w.INVALID_HANDLE_VALUE {return open_failure()}
	defer if !bool(w.CloseHandle(handle)) {
		log.errorf("pty: CloseHandle failed: %v", w.GetLastError())
	}
	info: w.BY_HANDLE_FILE_INFORMATION
	if !bool(w.GetFileInformationByHandle(handle, &info)) {
		log.warnf("pty: GetFileInformationByHandle failed (OS code %v)", w.GetLastError())
		return false
	}
	if info.dwFileAttributes & w.FILE_ATTRIBUTE_DIRECTORY == 0 {return false}
	final: [32768]u16
	count := w.GetFinalPathNameByHandleW(
		handle,
		cstring16(&final[0]),
		u32(len(final)),
		w.VOLUME_NAME_DOS,
	)
	if count == 0 || count >= u32(len(final)) {
		log.warnf("pty: GetFinalPathNameByHandleW failed (OS code %v)", w.GetLastError())
		return false
	}
	return local_final_path(final[:count])
}

// A missing or invalid directory is an ordinary rejection; anything else is worth a diagnostic.
@(private, require_results)
open_failure :: proc() -> bool {
	code := w.GetLastError()
	if code != w.ERROR_FILE_NOT_FOUND &&
	   code != w.ERROR_PATH_NOT_FOUND &&
	   code != w.ERROR_INVALID_NAME &&
	   code != ERROR_DIRECTORY {
		log.warnf("pty: CreateFileW failed (OS code %v)", code)
	}
	return false
}

// Rejects the shapes that name a remote or device namespace before any API can touch the network:
// two leading separators cover UNC and \\?\, \??\ names the NT object namespace directly, and a
// drive letter not followed by a separator is a drive-relative path whose target is not obvious.
@(private, require_results)
local_path_shape :: proc(path: string) -> bool {
	if len(path) >= 2 && path_separator(path[0]) && path_separator(path[1]) {return false}
	if len(path) >= 4 && path_separator(path[0]) && path[1] == '?' && path[2] == '?' &&
	   path_separator(path[3]) {
		return false
	}
	if len(path) >= 2 && path[1] == ':' && ascii_letter(path[0]) {
		if len(path) == 2 || !path_separator(path[2]) {return false}
	}
	return true
}

@(private, require_results)
path_separator :: proc(c: u8) -> bool {
	return c == '\\' || c == '/'
}

@(private, require_results)
ascii_letter :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

// A resolved absolute path must have a drive root that is not a network drive, and its characters
// must satisfy the same local-path rules used by the link opener.
@(private, require_results)
local_absolute_wide :: proc(path: []u16) -> bool {
	if len(path) < 3 || path[1] != ':' || (path[2] != '\\' && path[2] != '/') {
		return false
	}
	if !((path[0] >= 'A' && path[0] <= 'Z') || (path[0] >= 'a' && path[0] <= 'z')) {
		return false
	}
	text, err := w.utf16_to_utf8(path, context.temp_allocator)
	if err != nil {
		log.warnf("pty: converting the working directory failed: %v", err)
		return false
	}
	return local_drive_path(text)
}

// GetFinalPathNameByHandleW returns a \\?\ path. UNC and volume-GUID results are refused; a drive
// result is checked again so a local junction to a mapped network drive cannot pass.
@(private, require_results)
local_final_path :: proc(path: []u16) -> bool {
	text, err := w.utf16_to_utf8(path, context.temp_allocator)
	if err != nil {
		log.warnf("pty: converting the working directory failed: %v", err)
		return false
	}
	if strings.has_prefix(text, `\\?\UNC\`) {return false}
	if strings.has_prefix(text, `\\?\`) {text = text[4:]}
	return local_drive_path(text)
}

@(private, require_results)
local_drive_path :: proc(path: string) -> bool {
	if !links.local_absolute(path) {return false}
	root := [4]u16{u16(path[0]), ':', '\\', 0}
	drive := GetDriveTypeW(cstring16(&root[0]))
	return drive != DRIVE_REMOTE && drive != DRIVE_NO_ROOT_DIR
}
