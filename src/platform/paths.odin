package platform

import "aio:localpath"
import "core:strings"
import w "core:sys/windows"

// Which paths may be opened or read; both backends refuse the same ones.

// True for a local filesystem path: a drive-absolute path or a colon-free relative path. URL
// schemes, drive-relative names and UNC/device paths are refused, so this generic helper cannot
// become a launch path for untrusted URLs or network shares.
@(require_results)
open_path_allowed :: proc(path: string) -> bool {
	if path == "" {return false}
	for c in path {
		if c == 0 {return false}
	}
	if localpath.is_drive_absolute(path) {return true}
	if strings.has_prefix(path, `\\`) || strings.has_prefix(path, "//") {return false}
	for c in path {
		if c == ':' {return false}
		if c == '/' || c == '\\' {break}
	}
	return true
}

// True when `path` is a local regular file no larger than `limit` bytes. The check reads file
// attributes only: neither the contents nor a reparse target is opened, so a settings value
// cannot stall on a device or a remote share, or allocate unbounded memory, before the caller
// decides to read the file. Directory, device, reparse-point, and non-local names are refused.
@(require_results)
local_file_within_limit :: proc(path: string, limit: i64) -> bool {
	if !open_path_allowed(path) {return false}
	text := w.utf8_to_wstring(path, context.allocator)
	if text == nil {return false}
	defer delete(text)
	attributes: w.WIN32_FILE_ATTRIBUTE_DATA
	if !bool(w.GetFileAttributesExW(text, w.GetFileExInfoStandard, &attributes)) {return false}
	refused :=
		w.FILE_ATTRIBUTE_DIRECTORY | w.FILE_ATTRIBUTE_DEVICE | w.FILE_ATTRIBUTE_REPARSE_POINT
	if attributes.dwFileAttributes & refused != 0 {return false}
	size := (i64(attributes.nFileSizeHigh) << 32) | i64(attributes.nFileSizeLow)
	return size > 0 && size <= limit
}
