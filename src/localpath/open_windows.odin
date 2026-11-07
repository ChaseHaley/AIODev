package localpath

import "base:runtime"
import "core:log"
import "core:os"
import "core:strings"
import w "core:sys/windows"

foreign import open_kernel32 "system:kernel32.lib"

@(default_calling_convention = "system")
foreign open_kernel32 {
	GetDriveTypeW :: proc(root: w.LPCWSTR) -> u32 ---
}

// Click-time file admission. It differs from pty's working-directory check on purpose: a clicked path
// starts absolute, may be a file of any kind, and refuses every non-placeholder reparse component
// before following it, while a working directory may be relative and may cross a local junction as
// long as its final target is a local directory. Keep both policies; share only the path grammar.

// RPC_E_CHANGED_MODE: COM is already initialized on this thread in another apartment, which serves.
@(private)
COM_CHANGED_MODE :: 0x80010106

// Enters a single-threaded COM apartment on the calling thread. `entered` means the caller owes one
// CoUninitialize, including for S_FALSE. COM already initialized in another apartment kind serves, so it
// is `usable` with nothing owed; any other failure is logged.
@(require_results)
com_apartment :: proc() -> (entered, usable: bool) {
	result := w.CoInitializeEx(nil, .APARTMENTTHREADED)
	if result >= 0 {return true, true}
	if u32(result) == COM_CHANGED_MODE {return false, true}
	log.errorf("CoInitializeEx failed: HRESULT 0x%x", u32(result))
	return false, false
}

// The cycle and complexity bound for shortcut chains. A target still naming a shortcut is refused.
@(private)
SHORTCUT_HOPS :: 4

// Sync providers such as OneDrive mark local placeholders with the cloud reparse tag family.
// Those redirect nowhere, unlike junctions, symlinks and mount points, which stay refused.
@(private, require_results)
cloud_placeholder :: proc(path: cstring16) -> bool {
	data: w.WIN32_FIND_DATAW
	find := w.FindFirstFileW(path, &data)
	if find == w.INVALID_HANDLE_VALUE {return false}
	if !bool(w.FindClose(find)) {log.errorf("FindClose failed: %d", w.GetLastError())}
	return data.dwFileAttributes & w.FILE_ATTRIBUTE_REPARSE_POINT != 0 &&
		data.dwReserved0 & 0xffff0fff == 0x9000001a
}

// Refuse mapped drives and every non-placeholder reparse component before following a path.
// This keeps local junctions and symlinks from smuggling a remote share into a click-time check.
// Only fixed, removable and RAM-disk drives are allowed.
@(private, require_results)
canonical_path :: proc(path: string) -> (string, bool) {
	if !local_absolute(path) {return "", false}
	text := w.utf8_to_wstring(path, context.temp_allocator)
	if text == nil {return "", false}
	full: [4096]u16
	n := w.GetFullPathNameW(text, u32(len(full)), cstring16(&full[0]), nil)
	if n == 0 || n >= u32(len(full)) {
		log.errorf("GetFullPathNameW failed: %d", w.GetLastError())
		return "", false
	}
	root := [4]u16{full[0], ':', '\\', 0}
	drive := GetDriveTypeW(cstring16(&root[0]))
	if drive != 2 && drive != 3 && drive != 6 {return "", false}
	for i := 3; i <= int(n); i += 1 {
		if i < int(n) && full[i] != '\\' && full[i] != '/' {continue}
		saved := full[i]
		full[i] = 0
		attributes := w.GetFileAttributesW(cstring16(&full[0]))
		refused := attributes == w.INVALID_FILE_ATTRIBUTES ||
			attributes & w.FILE_ATTRIBUTE_DEVICE != 0 ||
			attributes & w.FILE_ATTRIBUTE_REPARSE_POINT != 0 && !cloud_placeholder(cstring16(&full[0]))
		full[i] = saved
		if refused {return "", false}
	}
	handle := w.CreateFileW(cstring16(&full[0]), 0, w.FILE_SHARE_READ | w.FILE_SHARE_WRITE | w.FILE_SHARE_DELETE,
		nil, w.OPEN_EXISTING, w.FILE_FLAG_BACKUP_SEMANTICS, nil)
	if handle == w.INVALID_HANDLE_VALUE {
		log.errorf("CreateFileW(local file) failed: %d", w.GetLastError())
		return "", false
	}
	defer if !bool(w.CloseHandle(handle)) {log.errorf("CloseHandle failed: %d", w.GetLastError())}
	final: [4096]u16
	count := w.GetFinalPathNameByHandleW(handle, cstring16(&final[0]), u32(len(final)), w.VOLUME_NAME_DOS)
	if count == 0 || count >= u32(len(final)) {
		log.errorf("GetFinalPathNameByHandleW failed: %d", w.GetLastError())
		return "", false
	}
	converted, err := w.utf16_to_utf8(final[:count], context.temp_allocator)
	if err != nil {return "", false}
	if strings.has_prefix(converted, `\\?\`) {converted = converted[4:]}
	if !local_absolute(converted) {return "", false}
	return converted, true
}

@(private)
Shell_Link :: struct #raw_union {
	#subtype unknown: w.IUnknown,
	using vtable: ^Shell_Link_Vtable,
}
@(private)
Shell_Link_Vtable :: struct {
	using unknown_vtable: w.IUnknown_VTable,
	GetPath: proc "system" (this: ^Shell_Link, path: ^u16, count: i32, data: rawptr, flags: u32) -> w.HRESULT,
	GetIDList, SetIDList, GetDescription, SetDescription, GetWorkingDirectory, SetWorkingDirectory: rawptr,
	GetArguments: proc "system" (this: ^Shell_Link, arguments: ^u16, count: i32) -> w.HRESULT,
}
@(private)
Persist_File :: struct #raw_union {
	#subtype unknown: w.IUnknown,
	using vtable: ^Persist_File_Vtable,
}
@(private)
Persist_File_Vtable :: struct {
	using unknown_vtable: w.IUnknown_VTable,
	GetClassID, IsDirty: rawptr,
	Load: proc "system" (this: ^Persist_File, path: w.LPCWSTR, mode: u32) -> w.HRESULT,
}

// Read the stored target without Resolve: no tracking search, network lookup, UI or link mutation.
// An unresolved, non-filesystem or remote target is refused, and so is a shortcut with arguments,
// because a plain open of its target cannot carry them.
@(private, require_results)
shortcut_target :: proc(path: string) -> (string, bool) {
	initialized, usable := com_apartment()
	defer if initialized {w.CoUninitialize()}
	if !usable {return "", false}
	class_id := w.GUID{0x00021401, 0, 0, {0xc0, 0, 0, 0, 0, 0, 0, 0x46}}
	link_id := w.GUID{0x000214f9, 0, 0, {0xc0, 0, 0, 0, 0, 0, 0, 0x46}}
	persist_id := w.GUID{0x0000010b, 0, 0, {0xc0, 0, 0, 0, 0, 0, 0, 0x46}}
	object: rawptr
	result := w.CoCreateInstance(&class_id, nil, w.CLSCTX_INPROC_SERVER, &link_id, &object)
	if result < 0 || object == nil {
		log.errorf("CoCreateInstance(ShellLink) failed: %x", u32(result))
		return "", false
	}
	link := (^Shell_Link)(object)
	defer link->Release()
	persist: rawptr
	result = link->QueryInterface(&persist_id, &persist)
	if result < 0 || persist == nil {
		log.errorf("QueryInterface(IPersistFile) failed: %x", u32(result))
		return "", false
	}
	file := (^Persist_File)(persist)
	defer file->Release()
	text := w.utf8_to_wstring(path, context.temp_allocator)
	if text == nil {return "", false}
	if result = file->Load(text, 0); result < 0 {
		log.errorf("IPersistFile.Load failed: %x", u32(result)); return "", false
	}
	target: [4096]u16
	if result = link->GetPath(&target[0], i32(len(target)), nil, 4); result != 0 {
		log.errorf("IShellLink.GetPath failed: %x", u32(result)); return "", false
	}
	arguments: [4096]u16
	if result = link->GetArguments(&arguments[0], i32(len(arguments))); result < 0 {
		log.errorf("IShellLink.GetArguments failed: %x", u32(result)); return "", false
	}
	if arguments[0] != 0 {return "", false}
	n := 0
	for n < len(target) && target[n] != 0 {n += 1}
	if n == 0 || n == len(target) {return "", false}
	converted, err := w.utf16_to_utf8(target[:n], context.temp_allocator)
	return converted, err == nil
}

@(private, require_results)
shortcut_name :: proc(path: string) -> bool {
	return strings.has_suffix(strings.to_lower(path, context.temp_allocator), ".lnk")
}

// Follows shortcuts from an admitted canonical path. The target borrows the temporary allocator.
// Only a shortcut starts COM; any other file is its own target.
@(private, require_results)
shortcut_chain :: proc(canonical: string) -> (target: string, shortcut, ok: bool) {
	target = canonical
	for _ in 0 ..< SHORTCUT_HOPS {
		if !shortcut_name(target) {break}
		shortcut = true
		raw, resolved := shortcut_target(target)
		if !resolved {return "", false, false}
		target, resolved = canonical_path(raw)
		if !resolved {return "", false, false}
	}
	if shortcut_name(target) {return "", false, false}
	return target, shortcut, true
}

// Whether prepare_open would accept the path, without its owned copies or confirmation policy.
// Link candidates are tried with it: a candidate must be openable, not merely present, so an
// unusable longer spelling never beats a usable shorter one, and a shortcut's chain is checked too.
@(require_results)
file_available :: proc(path: string) -> bool {
	canonical, admitted := canonical_path(path)
	if !admitted {return false}
	_, _, ok := shortcut_chain(canonical)
	return ok
}

@(require_results)
prepare_open :: proc(path: string) -> (file: Open_File, ok: bool) {
	canonical, admitted := canonical_path(path)
	if !admitted {return {}, false}
	target, shortcut, resolved := shortcut_chain(canonical)
	if !resolved {return {}, false}
	path_error, target_error: runtime.Allocator_Error
	file.path, path_error = strings.clone(canonical)
	file.target, target_error = strings.clone(target)
	if path_error != nil || target_error != nil {open_file_destroy(&file); return {}, false}
	pathext := os.get_env("PATHEXT", context.temp_allocator)
	file.confirm = shortcut || file_needs_confirmation(target, pathext)
	return file, true
}

// approved is the target the user confirmed, or empty when no confirmation was shown; a prepared
// target is never empty. The dispatch rechecks the path and opens only the validated target, never
// the .lnk, so the shell does not resolve a shortcut again at launch and a retargeted shortcut is
// refused rather than opened.
@(require_results)
open_file :: proc(path, approved: string) -> bool {
	file, ok := prepare_open(path)
	if !ok {return false}
	defer open_file_destroy(&file)
	if file.confirm && approved == "" {return false}
	if approved != "" && file.target != approved {return false}
	text := w.utf8_to_wstring(file.target, context.temp_allocator)
	if text == nil {return false}
	verb := [5]u16{'o', 'p', 'e', 'n', 0}
	info := w.SHELLEXECUTEINFOW{cbSize = size_of(w.SHELLEXECUTEINFOW),
		fMask = w.SEE_MASK_FLAG_NO_UI, lpVerb = cstring16(&verb[0]), lpFile = text, nShow = w.SW_SHOWNORMAL}
	if !bool(w.ShellExecuteExW(&info)) {
		log.errorf("ShellExecuteExW(local file) failed: %d", w.GetLastError())
		return false
	}
	return true
}
