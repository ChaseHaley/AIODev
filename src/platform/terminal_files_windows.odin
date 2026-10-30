package platform

import "aio:links"
import "core:log"
import "core:os"
import "core:strings"
import w "core:sys/windows"

foreign import terminal_kernel32 "system:kernel32.lib"

@(default_calling_convention = "system")
foreign terminal_kernel32 {
	GetDriveTypeW :: proc(root: w.LPCWSTR) -> u32 ---
}

// Refuse mapped drives and every reparse component before following a path. This also keeps
// local junctions and symlinks from smuggling a remote share into a click-time existence check.
@(private, require_results)
canonical_terminal_path :: proc(path: string) -> (string, bool) {
	if !links.local_absolute(path) {return "", false}
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
		full[i] = saved
		if attributes == w.INVALID_FILE_ATTRIBUTES ||
		   attributes & (w.FILE_ATTRIBUTE_DEVICE | w.FILE_ATTRIBUTE_REPARSE_POINT) != 0 {
			return "", false
		}
	}
	handle := w.CreateFileW(cstring16(&full[0]), 0, w.FILE_SHARE_READ | w.FILE_SHARE_WRITE | w.FILE_SHARE_DELETE,
		nil, w.OPEN_EXISTING, w.FILE_FLAG_BACKUP_SEMANTICS, nil)
	if handle == w.INVALID_HANDLE_VALUE {
		log.errorf("CreateFileW(terminal path) failed: %d", w.GetLastError())
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
	if !links.local_absolute(converted) {return "", false}
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
// An unresolved, non-filesystem or remote target is refused. Every .lnk still requires confirmation.
@(private, require_results)
shortcut_target :: proc(path: string) -> (string, bool) {
	result := w.CoInitializeEx(nil, .APARTMENTTHREADED)
	initialized := result >= 0
	defer if initialized {w.CoUninitialize()}
	if result < 0 && u32(result) != 0x80010106 {
		log.errorf("CoInitializeEx failed: %x", u32(result))
		return "", false
	}
	class_id := w.GUID{0x00021401, 0, 0, {0xc0, 0, 0, 0, 0, 0, 0, 0x46}}
	link_id := w.GUID{0x000214f9, 0, 0, {0xc0, 0, 0, 0, 0, 0, 0, 0x46}}
	persist_id := w.GUID{0x0000010b, 0, 0, {0xc0, 0, 0, 0, 0, 0, 0, 0x46}}
	object: rawptr
	result = w.CoCreateInstance(&class_id, nil, w.CLSCTX_INPROC_SERVER, &link_id, &object)
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
	n := 0
	for n < len(target) && target[n] != 0 {n += 1}
	if n == 0 || n == len(target) {return "", false}
	converted, err := w.utf16_to_utf8(target[:n], context.temp_allocator)
	return converted, err == nil
}

@(require_results)
prepare_terminal_file :: proc(path: string) -> (file: Terminal_File, ok: bool) {
	canonical, exists := canonical_terminal_path(path)
	if !exists {return {}, false}
	target := canonical
	shortcut := false
	for _ in 0 ..< 4 {
		if !strings.has_suffix(strings.to_lower(target, context.temp_allocator), ".lnk") {break}
		shortcut = true
		raw, resolved := shortcut_target(target)
		if !resolved {return {}, false}
		target, resolved = canonical_terminal_path(raw)
		if !resolved {return {}, false}
	}
	if strings.has_suffix(strings.to_lower(target, context.temp_allocator), ".lnk") {return {}, false}
	file.path, _ = strings.clone(canonical)
	file.target, _ = strings.clone(target)
	if file.path == "" || file.target == "" {terminal_file_destroy(&file); return {}, false}
	pathext := os.get_env("PATHEXT", context.temp_allocator)
	file.confirm = shortcut || links.file_needs_confirmation(target, pathext)
	return file, true
}

// Recheck after confirmation; never promote a replaced document into an unconfirmed active type.
@(require_results)
open_terminal_file :: proc(path: string, confirmed := false) -> bool {
	file, ok := prepare_terminal_file(path)
	if !ok {return false}
	defer terminal_file_destroy(&file)
	if file.confirm && !confirmed {return false}
	text := w.utf8_to_wstring(file.path, context.temp_allocator)
	if text == nil {return false}
	verb := [5]u16{'o', 'p', 'e', 'n', 0}
	info := w.SHELLEXECUTEINFOW{cbSize = size_of(w.SHELLEXECUTEINFOW),
		fMask = w.SEE_MASK_FLAG_NO_UI, lpVerb = cstring16(&verb[0]), lpFile = text, nShow = w.SW_SHOWNORMAL}
	if !bool(w.ShellExecuteExW(&info)) {
		log.errorf("ShellExecuteExW(terminal file) failed: %d", w.GetLastError())
		return false
	}
	return true
}
