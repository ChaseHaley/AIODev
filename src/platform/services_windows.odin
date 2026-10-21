package platform

import "base:runtime"
import "core:log"
import w "core:sys/windows"
import "core:unicode/utf16"

@(require_results)
window_show_inactive :: proc(p: ^Platform, id: Window_Id) -> Error {
	window := find_window(p, id)
	if window == nil {return .Invalid_Window}
	// ShowWindow returns the previous visibility, not success.
	w.ShowWindow(window.hwnd, w.SW_SHOWNOACTIVATE)
	if !bool(w.IsWindowVisible(window.hwnd)) {
		log.errorf("ShowWindow(inactive) failed: %v", w.GetLastError())
		return .Os
	}
	return .None
}

@(require_results)
@(private)
tray_add :: proc(p: ^Platform) -> Error {
	if !os_ok(w.Shell_NotifyIconW(w.NIM_ADD, &p.tray_data), "Shell_NotifyIconW(add)") {return .Os}
	p.tray_added = true
	p.tray_data.uVersion = NOTIFYICON_VERSION_4
	if !os_ok(
		w.Shell_NotifyIconW(w.NIM_SETVERSION, &p.tray_data),
		"Shell_NotifyIconW(version)",
	) {return .Os}
	return .None
}

@(require_results)
tray_create :: proc(p: ^Platform, tooltip: string) -> Error {
	if p.host.hwnd == nil {return .Not_Initialized}
	if p.tray_requested || len(tooltip) > 127 {return .Invalid_Argument}
	p.tray_data = {
		cbSize           = size_of(w.NOTIFYICONDATAW),
		hWnd             = p.host.hwnd,
		uID              = 1,
		uFlags           = w.NIF_MESSAGE | w.NIF_ICON | w.NIF_TIP | w.NIF_SHOWTIP,
		uCallbackMessage = TRAY_MESSAGE,
		hIcon            = p.icon,
	}
	utf16.encode_string(p.tray_data.szTip[:127], tooltip)
	p.tray_requested = true
	err := tray_add(p)
	if err != .None {
		cleanup_error := tray_destroy(p)
		if cleanup_error != .None {
			p.error = cleanup_error
		}
	}
	return err
}

@(require_results)
tray_destroy :: proc(p: ^Platform) -> Error {
	p.tray_requested = false
	if !p.tray_added {return .None}
	if !os_ok(
		w.Shell_NotifyIconW(w.NIM_DELETE, &p.tray_data),
		"Shell_NotifyIconW(delete)",
	) {return .Os}
	p.tray_added = false
	return .None
}

@(require_results)
tray_set_menu :: proc(p: ^Platform, items: []Tray_Menu_Item) -> Error {
	if p.host.hwnd == nil {return .Not_Initialized}
	menu := w.CreatePopupMenu()
	if menu == nil {
		log.errorf("CreatePopupMenu failed: %d", w.GetLastError())
		return .Os
	}
	ids, alloc_error := make([]u32, len(items), p.allocator)
	if alloc_error != nil {
		record_os(p, w.DestroyMenu(menu), "DestroyMenu")
		return .Out_Of_Memory
	}
	success := false
	defer {
		if !success {
			record_os(p, w.DestroyMenu(menu), "DestroyMenu")
			delete(ids, p.allocator)
		}
	}
	for item, i in items {
		if !item.separator {
			if item.id == 0 {return .Invalid_Argument}
			for previous in items[:i] {
				if !previous.separator && previous.id == item.id {return .Invalid_Argument}
			}
		}
		for c in item.title {
			if c == 0 {return .Invalid_Argument}
		}
		text := w.utf8_to_wstring(item.title, p.allocator)
		if text == nil {return .Out_Of_Memory}
		flags := u32(w.MF_STRING)
		if item.disabled {
			flags |= w.MF_GRAYED
		}
		if item.separator {
			flags = w.MF_SEPARATOR
		}
		ok := os_ok(w.AppendMenuW(menu, flags, uintptr(i + 1), text), "AppendMenuW")
		delete(text, p.allocator)
		if !ok {return .Os}
		ids[i] = item.id
	}
	if p.menu != nil && !os_ok(w.DestroyMenu(p.menu), "DestroyMenu") {return .Os}
	delete(p.menu_ids, p.allocator)
	p.menu, p.menu_ids = menu, ids
	success = true
	return .None
}

@(private)
tray_popup :: proc(p: ^Platform) {
	if p.menu == nil {return}
	point: w.POINT
	if !os_ok(w.GetCursorPos(&point), "GetCursorPos") {
		p.error = .Os
		return
	}
	if !os_ok(w.SetForegroundWindow(p.host.hwnd), "SetForegroundWindow(tray)") {
		p.error = .Os
		return
	}
	w.SetLastError(0)
	flags := u32(w.TPM_RETURNCMD | w.TPM_NONOTIFY | w.TPM_RIGHTBUTTON)
	command := w.TrackPopupMenu(p.menu, flags, point.x, point.y, 0, p.host.hwnd, nil)
	if command == 0 && w.GetLastError() != 0 {
		log.errorf("TrackPopupMenu failed: %d", w.GetLastError())
		p.error = .Os
	}
	if command > 0 && int(command) <= len(p.menu_ids) {
		enqueue(p, Tray_Menu_Event{p.menu_ids[command - 1]})
	}
	// A benign posted message lets the menu dismiss correctly on a second invocation.
	record_os(p, w.PostMessageW(p.host.hwnd, w.WM_NULL, 0, 0), "PostMessageW(tray)")
}

@(require_results)
tray_notify :: proc(p: ^Platform, title, text: string) -> Error {
	if !p.tray_added {return .Not_Initialized}
	if len(title) > 63 || len(text) > 255 {return .Invalid_Argument}
	data := p.tray_data
	data.uFlags = w.NIF_INFO
	data.dwInfoFlags = NIIF_INFO
	utf16.encode_string(data.szInfoTitle[:63], title)
	utf16.encode_string(data.szInfo[:255], text)
	if !os_ok(w.Shell_NotifyIconW(w.NIM_MODIFY, &data), "Shell_NotifyIconW(notify)") {return .Os}
	return .None
}

@(require_results)
@(private)
unlock_global :: proc(memory: w.HGLOBAL) -> bool {
	w.SetLastError(0)
	if !bool(w.GlobalUnlock(memory)) && w.GetLastError() != 0 {
		log.errorf("GlobalUnlock failed: %d", w.GetLastError())
		return false
	}
	return true
}

@(require_results)
clipboard_set_text :: proc(p: ^Platform, text: string) -> (ok: bool) {
	if p.host.hwnd == nil {return false}
	bytes, alloc_error := make([]u8, len(text) * 2, p.allocator)
	if alloc_error != nil {return false}
	defer delete(bytes, p.allocator)
	normalized, converted := clipboard_crlf(text, bytes)
	if !converted {return false}
	for c in normalized {
		if c == 0 {return false}
	}
	units := w.utf8_to_wstring(normalized, p.allocator)
	if units == nil {return false}
	defer delete(units, p.allocator)
	memory := w.GlobalAlloc(w.GMEM_MOVEABLE, uint((len(units) + 1) * 2))
	if memory == nil {
		log.errorf("GlobalAlloc failed: %d", w.GetLastError())
		return false
	}
	transferred := false
	defer {
		if !transferred && w.GlobalFree(memory) != nil {
			log.errorf("GlobalFree failed: %d", w.GetLastError())
			ok = false
		}
	}
	data := w.GlobalLock(w.HGLOBAL(memory))
	if data == nil {
		log.errorf("GlobalLock failed: %d", w.GetLastError())
		return false
	}
	copy((cast([^]u16)data)[:len(units) + 1], (cast([^]u16)units)[:len(units) + 1])
	if !unlock_global(w.HGLOBAL(memory)) {return false}
	if !os_ok(w.OpenClipboard(p.host.hwnd), "OpenClipboard") {return false}
	defer {
		if !os_ok(w.CloseClipboard(), "CloseClipboard") {
			ok = false
		}
	}
	if !os_ok(w.EmptyClipboard(), "EmptyClipboard") {return false}
	if w.SetClipboardData(w.CF_UNICODETEXT, w.HANDLE(memory)) == nil {
		log.errorf("SetClipboardData failed: %d", w.GetLastError())
		return false
	}
	transferred = true
	return true
}

@(require_results)
clipboard_get_text :: proc(
	p: ^Platform,
	allocator: runtime.Allocator,
) -> (
	text: string,
	ok: bool,
) {
	if p.host.hwnd == nil {return "", false}
	if !os_ok(w.OpenClipboard(p.host.hwnd), "OpenClipboard") {return "", false}
	defer {
		if !os_ok(w.CloseClipboard(), "CloseClipboard") {
			if ok {
				delete(text, allocator)
			}
			text, ok = "", false
		}
	}
	memory := w.GetClipboardData(w.CF_UNICODETEXT)
	if memory == nil {
		log.errorf("GetClipboardData failed: %d", w.GetLastError())
		return "", false
	}
	bytes := w.GlobalSize(rawptr(memory))
	if bytes == 0 {
		log.errorf("GlobalSize failed: %d", w.GetLastError())
		return "", false
	}
	data := w.GlobalLock(w.HGLOBAL(memory))
	if data == nil {
		log.errorf("GlobalLock failed: %d", w.GetLastError())
		return "", false
	}
	defer {
		if !unlock_global(w.HGLOBAL(memory)) {
			if ok {
				delete(text, allocator)
			}
			text, ok = "", false
		}
	}
	units := (cast([^]u16)data)[:int(bytes / 2)]
	n := 0
	for n < len(units) && units[n] != 0 {
		n += 1
	}
	if n == len(units) {return "", false}
	converted, alloc_error := w.utf16_to_utf8(units[:n], allocator)
	if alloc_error != nil {return "", false}
	if n != 0 && len(converted) == 0 {
		log.errorf("WideCharToMultiByte failed: Win32 %d", w.GetLastError())
		return "", false
	}
	return converted, true
}

@(require_results)
open_path :: proc(path: string) -> bool {
	if len(path) == 0 {return false}
	for c in path {
		if c == 0 {return false}
	}
	text := w.utf8_to_wstring(path, context.allocator)
	if text == nil {return false}
	defer delete(text)
	result := w.ShellExecuteW(nil, nil, text, nil, nil, w.SW_SHOWNORMAL)
	if uintptr(result) <= SHELL_EXECUTE_ERROR_MAX {
		log.errorf("ShellExecuteW failed: code %d", uintptr(result))
		return false
	}
	return true
}
