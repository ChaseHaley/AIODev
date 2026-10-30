package platform

import "aio:input"
import "base:runtime"
import "core:log"
import "core:sync"
import w "core:sys/windows"
import "core:unicode/utf16"
import "core:unicode/utf8"

@(private)
ACTIVATE_MESSAGE :: w.WM_APP + 1
@(private)
TRAY_MESSAGE :: w.WM_APP + 2
@(private)
EVENT_CAPACITY :: 2048
@(private)
TEXT_CAPACITY :: 65536

@(private)
Event_Queue :: struct {
	events:    []Event,
	count:     int,
	text:      []u8,
	text_used: int,
}
@(private)
Window :: struct {
	owner:                            ^Platform,
	id:                               Window_Id,
	hwnd:                             w.HWND,
	cursor:                           w.HCURSOR,
	tracking, sizing:                 bool,
	buttons:                          u8,
	high_surrogate:                   u16,
	previous_move:                    Mouse_Move_Event,
	has_previous_move:                bool,
	tabbed_title_bar:                 bool,
	title_height, title_controls_end: i32,
}
Platform :: struct {
	allocator:                  runtime.Allocator,
	callback_context:           runtime.Context,
	instance:                   w.HINSTANCE,
	mutex, wake_event:          w.HANDLE,
	wake_pending:               u32,
	class_name:                 [256]u16,
	class_registered:           bool,
	host:                       Window,
	windows:                    [dynamic]^Window,
	next_id:                    u64,
	queues:                     [2]Event_Queue,
	write_queue:                int,
	error:                      Error,
	taskbar_created:            u32,
	icon:                       w.HICON,
	tray_requested, tray_added: bool,
	tray_data:                  w.NOTIFYICONDATAW,
	menu:                       w.HMENU,
	menu_ids:                   []u32,
	modal_callback:             proc(user: rawptr),
	modal_user:                 rawptr,
	frequency:                  w.LARGE_INTEGER,
	taskbar:                    ^w.ITaskbarList3,
	taskbar_failed:             bool,
	com_initialized:            bool,
}

@(require_results)
@(private)
os_ok :: proc(ok: w.BOOL, call: string) -> bool {
	if !bool(ok) {
		log.errorf("%s failed: Win32 %d", call, w.GetLastError())
		return false
	}
	return true
}

@(private)
record_os :: proc(p: ^Platform, ok: w.BOOL, call: string) {
	if !os_ok(ok, call) {
		p.error = .Os
	}
}

@(private, require_results)
user_identity :: proc(out: []u16) -> (length: int, err: Error) {
	token: w.HANDLE
	if !os_ok(
		w.OpenProcessToken(w.GetCurrentProcess(), w.TOKEN_QUERY, &token),
		"OpenProcessToken",
	) {
		return 0, .Os
	}
	defer {
		if !os_ok(w.CloseHandle(token), "CloseHandle(token)") {
			err = .Os
		}
	}
	storage: [16]u64
	needed: u32
	if !os_ok(
		w.GetTokenInformation(token, .TokenUser, &storage, size_of(storage), &needed),
		"GetTokenInformation",
	) {
		return 0, .Os
	}
	user := cast(^w.TOKEN_USER)&storage
	sid := cast(^w.SID)user.User.Sid
	count := 8 + 4 * int(sid.SubAuthorityCount)
	if count > size_of(w.SID) || count * 2 > len(out) {return 0, .Invalid_Argument}
	bytes := (cast([^]u8)sid)[:count]
	digits := "0123456789abcdef"
	for byte, i in bytes {
		out[i * 2] = u16(digits[byte >> 4])
		out[i * 2 + 1] = u16(digits[byte & 15])
	}
	return count * 2, .None
}

@(private, require_results)
mutex_name :: proc(app_id: string) -> (name: [512]u16, err: Error) {
	if len(app_id) == 0 || len(app_id) > 120 || !utf8.valid_string(app_id) {
		return {}, .Invalid_Argument
	}
	for c in app_id {
		if c == 0 || c == '\\' || c == '/' {return {}, .Invalid_Argument}
	}
	n := utf16.encode_string(name[:], "Local\\")
	n += utf16.encode_string(name[n:], app_id)
	name[n] = '.'
	n += 1
	_, err = user_identity(name[n:])
	return
}

@(require_results)
instance_running :: proc(app_id: string) -> (running: bool, err: Error) {
	name, name_error := mutex_name(app_id)
	if name_error != .None {return false, name_error}
	mutex := OpenMutexW(w.SYNCHRONIZE, false, cstring16(raw_data(name[:])))
	if mutex == nil {
		if w.GetLastError() == w.ERROR_FILE_NOT_FOUND {return false, .None}
		log.errorf("OpenMutexW failed: Win32 %d", w.GetLastError())
		return false, .Os
	}
	if !os_ok(w.CloseHandle(mutex), "CloseHandle(mutex)") {return false, .Os}
	return true, .None
}

@(require_results)
init :: proc(p: ^Platform, app_id: string, allocator := context.allocator) -> Init_Result {
	if p.wake_event != nil {return .Failed}
	name, name_error := mutex_name(app_id)
	if name_error != .None {return .Failed}
	p.allocator = allocator
	p.callback_context = context
	p.callback_context.allocator = allocator
	success := false
	defer {
		if !success {
			err := destroy(p)
			if err != .None {
				log.error("platform init cleanup failed")
			}
		}
	}
	p.instance = w.HINSTANCE(w.GetModuleHandleW(nil))
	if p.instance == nil {
		log.errorf("GetModuleHandleW failed: %d", w.GetLastError())
		return .Failed
	}
	p.mutex = CreateMutexW(nil, false, cstring16(raw_data(name[:])))
	mutex_error := w.GetLastError()
	if p.mutex == nil {
		log.errorf("CreateMutexW failed: %d", mutex_error)
		return .Failed
	}
	utf16.encode_string(p.class_name[:], app_id)
	if mutex_error == w.ERROR_ALREADY_EXISTS {
		host: w.HWND
		for _ in 0 ..< 100 {
			host = w.FindWindowW(
				cstring16(raw_data(p.class_name[:])),
				cstring16(raw_data(name[:])),
			)
			if host != nil {
				break
			}
			// The mutex becomes visible before the primary has created its host.
			w.Sleep(10)
		}
		if host == nil {
			log.error("primary host is unavailable")
			return .Failed
		}
		// The launched process owns the foreground; hand it to the primary so its window can take it.
		primary_pid: w.DWORD
		w.GetWindowThreadProcessId(host, &primary_pid)
		if primary_pid == 0 || !bool(AllowSetForegroundWindow(primary_pid)) {
			log.errorf("AllowSetForegroundWindow failed: %d", w.GetLastError())
		}
		if !os_ok(w.PostMessageW(host, ACTIVATE_MESSAGE, 0, 0), "PostMessageW") {return .Failed}
		return .Secondary
	}
	// A manifest may already have established process awareness.
	if !bool(w.SetProcessDpiAwarenessContext(w.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)) {
		code := w.GetLastError()
		if code != w.ERROR_ACCESS_DENIED {
			log.errorf("SetProcessDpiAwarenessContext failed: %d", code)
			return .Failed
		}
	}
	if !os_ok(
		w.QueryPerformanceFrequency(&p.frequency),
		"QueryPerformanceFrequency",
	) {return .Failed}
	p.wake_event = w.CreateEventW(nil, false, false, nil)
	if p.wake_event == nil {
		log.errorf("CreateEventW failed: %d", w.GetLastError())
		return .Failed
	}
	for &q in p.queues {
		alloc_error: runtime.Allocator_Error
		q.events, alloc_error = make([]Event, EVENT_CAPACITY, allocator)
		if alloc_error != nil {return .Failed}
		q.text, alloc_error = make([]u8, TEXT_CAPACITY, allocator)
		if alloc_error != nil {return .Failed}
	}
	window_alloc_error: runtime.Allocator_Error
	p.windows, window_alloc_error = make([dynamic]^Window, 0, 4, allocator)
	if window_alloc_error != nil {return .Failed}
	p.icon = w.LoadIconW(p.instance, cstring16(w.MAKEINTRESOURCEW(1)))
	if p.icon == nil {
		// Test executables do not embed the application resources.
		log.debugf("LoadIconW(resource 1) failed: %d", w.GetLastError())
		p.icon = w.LoadIconW(nil, transmute(cstring16)w.IDI_APPLICATION)
		if p.icon == nil {
			log.errorf("LoadIconW failed: %d", w.GetLastError())
			return .Failed
		}
	}
	cursor := w.LoadCursorW(nil, transmute(cstring16)w.IDC_ARROW)
	if cursor == nil {
		log.errorf("LoadCursorW failed: %d", w.GetLastError())
		return .Failed
	}
	class := w.WNDCLASSEXW {
		cbSize        = size_of(w.WNDCLASSEXW),
		style         = w.CS_DBLCLKS,
		lpfnWndProc   = window_proc,
		hInstance     = p.instance,
		hIcon         = p.icon,
		hIconSm       = p.icon,
		hCursor       = cursor,
		lpszClassName = cstring16(raw_data(p.class_name[:])),
	}
	if w.RegisterClassExW(&class) == 0 {
		log.errorf("RegisterClassExW failed: %d", w.GetLastError())
		return .Failed
	}
	p.class_registered = true
	taskbar: [32]u16
	utf16.encode_string(taskbar[:], "TaskbarCreated")
	p.taskbar_created = w.RegisterWindowMessageW(cstring16(raw_data(taskbar[:])))
	if p.taskbar_created == 0 {
		log.errorf("RegisterWindowMessageW failed: %d", w.GetLastError())
		return .Failed
	}
	p.host.owner = p
	// Message-only windows cannot receive Explorer's TaskbarCreated broadcast.
	p.host.hwnd = w.CreateWindowExW(
		0,
		cstring16(raw_data(p.class_name[:])),
		cstring16(raw_data(name[:])),
		0,
		0,
		0,
		0,
		0,
		nil,
		nil,
		p.instance,
		&p.host,
	)
	if p.host.hwnd == nil {
		log.errorf("CreateWindowExW(host) failed: %d", w.GetLastError())
		return .Failed
	}
	success = true
	return .Primary
}

@(require_results)
destroy :: proc(p: ^Platform) -> Error {
	if p == nil {return .None}
	first_error := p.error
	for window in p.windows {
		if !os_ok(w.DestroyWindow(window.hwnd), "DestroyWindow") {
			if first_error == .None {
				first_error = .Os
			}
			detach_window(p, window.hwnd)
		}
		free(window, p.allocator)
	}
	tray_error := tray_destroy(p)
	taskbar_destroy(p)
	if first_error == .None {
		first_error = tray_error
	}
	if p.menu != nil {
		record_os(p, w.DestroyMenu(p.menu), "DestroyMenu")
	}
	if p.host.hwnd != nil {
		if !os_ok(w.DestroyWindow(p.host.hwnd), "DestroyWindow(host)") {
			if first_error == .None {
				first_error = .Os
			}
			detach_window(p, p.host.hwnd)
		}
	}
	if p.class_registered {
		record_os(
			p,
			w.UnregisterClassW(cstring16(raw_data(p.class_name[:])), p.instance),
			"UnregisterClassW",
		)
	}
	if p.wake_event != nil {
		record_os(p, w.CloseHandle(p.wake_event), "CloseHandle(wake)")
	}
	if p.mutex != nil {
		record_os(p, w.CloseHandle(p.mutex), "CloseHandle(mutex)")
	}
	for &q in p.queues {
		delete(q.events, p.allocator)
		delete(q.text, p.allocator)
	}
	delete(p.windows)
	delete(p.menu_ids, p.allocator)
	if first_error == .None {
		first_error = p.error
	}
	p^ = {}
	return first_error
}

@(private)
detach_window :: proc(p: ^Platform, hwnd: w.HWND) {
	// A failed destruction must not leave the OS pointing at released owner state.
	w.SetLastError(0)
	previous := w.SetWindowLongPtrW(hwnd, w.GWLP_USERDATA, 0)
	if previous == 0 && w.GetLastError() != 0 {
		record_os(p, false, "SetWindowLongPtrW(detach)")
	}
}

@(private)
enqueue :: proc(p: ^Platform, event: Event) {
	q := &p.queues[p.write_queue]
	if q.count == len(q.events) {
		p.error = .Queue_Full
		return
	}
	q.events[q.count] = event
	q.count += 1
}

@(private)
queue_rune :: proc(p: ^Platform, r: rune) -> string {
	q := &p.queues[p.write_queue]
	bytes, n := utf8.encode_rune(r)
	if q.text_used + n > len(q.text) {
		p.error = .Queue_Full
		return ""
	}
	start := q.text_used
	copy(q.text[start:], bytes[:n])
	q.text_used += n
	return string(q.text[start:q.text_used])
}

@(require_results)
wake :: proc(p: ^Platform) -> Error {
	if p.wake_event == nil {return .Not_Initialized}
	if sync.atomic_exchange(&p.wake_pending, 1) == 0 {
		if !os_ok(w.SetEvent(p.wake_event), "SetEvent") {
			sync.atomic_store(&p.wake_pending, 0)
			return .Os
		}
	}
	return .None
}

@(require_results)
wait_events :: proc(p: ^Platform, timeout_ms: u32) -> Error {
	if p.wake_event == nil {return .Not_Initialized}
	if p.queues[p.write_queue].count != 0 || sync.atomic_load(&p.wake_pending) != 0 {return .None}
	result := MsgWaitForMultipleObjectsEx(
		1,
		&p.wake_event,
		timeout_ms,
		w.QS_ALLINPUT,
		MWMO_INPUTAVAILABLE,
	)
	if result == w.WAIT_FAILED {
		log.errorf("MsgWaitForMultipleObjectsEx failed: %d", w.GetLastError())
		return .Os
	}
	return .None
}

@(require_results)
poll_events :: proc(p: ^Platform) -> ([]Event, Error) {
	if p.wake_event == nil {return nil, .Not_Initialized}
	if sync.atomic_exchange(&p.wake_pending, 0) != 0 {
		enqueue(p, Wake_Event{})
	}
	q := &p.queues[p.write_queue]
	message: w.MSG
	for q.count < len(q.events) - 16 &&
	    q.text_used < len(q.text) - 1024 &&
	    bool(w.PeekMessageW(&message, nil, 0, 0, w.PM_REMOVE)) {
		owned := message.hwnd == p.host.hwnd
		for window in p.windows {
			if window.hwnd == message.hwnd {
				owned = true
				break
			}
		}
		if owned && message.message >= w.WM_KEYFIRST && message.message <= w.WM_KEYLAST {
			state := (^Window)(uintptr(w.GetWindowLongPtrW(message.hwnd, w.GWLP_USERDATA)))
			if state == nil {
				log.errorf("GetWindowLongPtrW(userdata) failed: %d", w.GetLastError())
				p.error = .Os
				continue
			}
			pump_key(p, state, &message)
		} else {
			// DispatchMessage's result belongs to the window procedure, not GetLastError.
			w.DispatchMessageW(&message)
		}
	}
	result := q.events[:q.count]
	p.write_queue = 1 - p.write_queue
	p.queues[p.write_queue].count = 0
	p.queues[p.write_queue].text_used = 0
	err := p.error
	p.error = .None
	return result, err
}

@(require_results)
@(private)
keyboard_state :: proc() -> ([256]u8, bool) {
	state: [256]u8
	ok := os_ok(w.GetKeyboardState(cast(^w.BYTE)&state[0]), "GetKeyboardState")
	return state, ok
}

@(private)
pump_key :: proc(p: ^Platform, window: ^Window, message: ^w.MSG) {
	msg := message.message
	if msg == w.WM_CHAR || msg == w.WM_SYSCHAR {
		unit := u16(message.wParam & 0xffff)
		if unit >= 0xd800 && unit <= 0xdbff {
			if window.high_surrogate != 0 {
				enqueue(p, Text_Event{window.id, queue_rune(p, '\ufffd')})
			}
			window.high_surrogate = unit
			return
		}
		r := rune(unit)
		if window.high_surrogate != 0 {
			if unit >= 0xdc00 && unit <= 0xdfff {
				r = utf16.decode_surrogate_pair(rune(window.high_surrogate), r)
			} else {
				enqueue(p, Text_Event{window.id, queue_rune(p, '\ufffd')})
			}
			window.high_surrogate = 0
		} else if unit >= 0xdc00 && unit <= 0xdfff {r = '\ufffd'}
		enqueue(p, Text_Event{window.id, queue_rune(p, r)})
		return
	}
	if msg != w.WM_KEYDOWN &&
	   msg != w.WM_SYSKEYDOWN &&
	   msg != w.WM_KEYUP &&
	   msg != w.WM_SYSKEYUP {return}
	state, ok := keyboard_state()
	if !ok {
		p.error = .Os
		return
	}
	bits := uintptr(message.lParam)
	scan := u16((bits >> 16) & 255)
	extended := bits & (1 << 24) != 0
	vk := u16(message.wParam & 0xffff)
	pressed := msg == w.WM_KEYDOWN || msg == w.WM_SYSKEYDOWN
	if vk == w.VK_F4 && (bits & (1 << 29) != 0 || .Alt in modifiers_from_state(state)) {
		if pressed {
			enqueue(p, Close_Request_Event{window.id})
		}
		return
	}
	key := key_from_scan_code(scan, extended)
	if vk == w.VK_PAUSE {
		key = .Pause
	}
	if vk == w.VK_NUMLOCK {
		key = .Num_Lock
	}
	if vk == w.VK_SNAPSHOT {
		key = .Print_Screen
	}
	event := Key_Event {
		window = window.id,
		key = key,
		modifiers = modifiers_from_state(state),
		pressed = pressed,
		repeat = pressed && bits & (1 << 30) != 0,
		native = {
			vk = vk,
			scan_code = scan,
			repeat_count = u16(bits & 0xffff),
			control_key_state = control_key_state(state, extended),
		},
	}
	if pressed {
		empty: [256]w.BYTE
		units: [8]u16
		layout := GetKeyboardLayout(0)
		if layout == nil {
			log.errorf("GetKeyboardLayout failed: %d", w.GetLastError())
			p.error = .Os
			return
		}
		n := ToUnicodeEx(
			u32(vk),
			u32(scan),
			&empty[0],
			&units[0],
			i32(len(units)),
			TO_UNICODE_NO_STATE_CHANGE,
			layout,
		)
		if n > 0 {
			event.unshifted = rune(units[0])
			if n >= 2 && utf16.is_surrogate(event.unshifted) {
				event.unshifted = utf16.decode_surrogate_pair(rune(units[0]), rune(units[1]))
			}
		}
	}
	if pressed {
		translated := bool(w.TranslateMessage(message))
		if translated {
			start := p.queues[p.write_queue].text_used
			pending_high: u16
			first := true
			char_message: w.MSG
			char_first, char_last := u32(w.WM_CHAR), u32(w.WM_DEADCHAR)
			if msg == w.WM_SYSKEYDOWN {
				char_first, char_last = w.WM_SYSCHAR, w.WM_SYSDEADCHAR
			}
			// TranslateMessage posts behind already queued key-up messages.
			for bool(
				    w.PeekMessageW(
					    &char_message,
					    message.hwnd,
					    char_first,
					    char_last,
					    w.PM_REMOVE,
				    ),
			    ) {
				if char_message.message == w.WM_DEADCHAR ||
				   char_message.message == w.WM_SYSDEADCHAR {
					continue
				}
				unit := u16(char_message.wParam & 0xffff)
				if first {
					event.native.char = unit
					first = false
				}
				if unit >= 0xd800 && unit <= 0xdbff {
					pending_high = unit
					continue
				}
				r := rune(unit)
				if pending_high != 0 {
					r = utf16.decode_surrogate_pair(rune(pending_high), r)
					pending_high = 0
				} else if utf16.is_surrogate(r) {
					r = '\ufffd'
				}
				queue_rune(p, r)
			}
			if pending_high != 0 {
				queue_rune(p, '\ufffd')
			}
			q := &p.queues[p.write_queue]
			event.text = string(q.text[start:q.text_used])
		}
	}
	enqueue(p, event)
}

@(private)
find_window :: proc(p: ^Platform, id: Window_Id) -> ^Window {
	for window in p.windows {
		if window.id == id {return window}
	}
	return nil
}

@(require_results)
window_create :: proc(p: ^Platform, desc: Window_Desc) -> (Window_Id, Error) {
	if p.host.hwnd == nil {return 0, .Not_Initialized}
	if desc.width <= 0 || desc.height <= 0 || desc.width > 32767 || desc.height > 32767 {
		return 0, .Invalid_Argument
	}
	for c in desc.title {
		if c == 0 {return 0, .Invalid_Argument}
	}
	title := w.utf8_to_wstring(desc.title, p.allocator)
	if title == nil {return 0, .Out_Of_Memory}
	defer delete(title, p.allocator)
	window, alloc_error := new(Window, p.allocator)
	if alloc_error != nil {return 0, .Out_Of_Memory}
	window.owner = p
	window.tabbed_title_bar = desc.tabbed_title_bar
	p.next_id += 1
	window.id = Window_Id(p.next_id)
	window.cursor = w.LoadCursorW(nil, transmute(cstring16)w.IDC_ARROW)
	if window.cursor == nil {
		log.errorf("LoadCursorW failed: %d", w.GetLastError())
		free(window, p.allocator)
		return 0, .Os
	}
	if _, append_error := append(&p.windows, window); append_error != nil {
		free(window, p.allocator)
		return 0, .Out_Of_Memory
	}
	rect := w.RECT {
		right  = desc.width,
		bottom = desc.height,
	}
	dpi := primary_dpi(p)
	if dpi == 0 ||
	   !os_ok(
			   w.AdjustWindowRectExForDpi(&rect, w.WS_OVERLAPPEDWINDOW, false, 0, dpi),
			   "AdjustWindowRectExForDpi",
		   ) {
		pop(&p.windows)
		free(window, p.allocator)
		return 0, .Os
	}
	if window.tabbed_title_bar {rect.top = 0}
	window.hwnd = w.CreateWindowExW(
		0,
		cstring16(raw_data(p.class_name[:])),
		title,
		w.WS_OVERLAPPEDWINDOW,
		w.CW_USEDEFAULT,
		w.CW_USEDEFAULT,
		rect.right - rect.left,
		rect.bottom - rect.top,
		nil,
		nil,
		p.instance,
		window,
	)
	if window.hwnd == nil {
		log.errorf("CreateWindowExW failed: %d", w.GetLastError())
		pop(&p.windows)
		free(window, p.allocator)
		return 0, .Os
	}
	if window.tabbed_title_bar {
		margins := w.MARGINS {
			cyTopHeight = i32(40 * dpi / 96),
		}
		if hr := w.DwmExtendFrameIntoClientArea(window.hwnd, &margins); hr < 0 {
			log.errorf("DwmExtendFrameIntoClientArea failed: HRESULT %x", u32(hr))
			p.error = .Os
		}
		record_os(
			p,
			w.SetWindowPos(
				window.hwnd,
				nil,
				0,
				0,
				0,
				0,
				w.SWP_NOMOVE |
				w.SWP_NOSIZE |
				w.SWP_NOZORDER |
				w.SWP_NOACTIVATE |
				w.SWP_FRAMECHANGED,
			),
			"SetWindowPos(title bar)",
		)
	}
	dark := w.BOOL(true)
	hr := w.DwmSetWindowAttribute(
		window.hwnd,
		u32(w.DWMWINDOWATTRIBUTE.DWMWA_USE_IMMERSIVE_DARK_MODE),
		&dark,
		size_of(dark),
	)
	if hr < 0 {
		log.errorf("DwmSetWindowAttribute(dark) failed: HRESULT %x", u32(hr))
		cleanup_error := window_destroy(p, window.id)
		if cleanup_error != .None {
			p.error = cleanup_error
		}
		return 0, .Os
	}
	width, height, size_error := window_client_size(p, window.id)
	if size_error != .None {
		cleanup_error := window_destroy(p, window.id)
		if cleanup_error != .None {
			p.error = cleanup_error
		}
		return 0, size_error
	}
	enqueue(p, Resize_Event{window.id, width, height})
	if !desc.hidden {
		w.ShowWindow(window.hwnd, desc.inactive ? w.SW_SHOWNOACTIVATE : w.SW_SHOW)
	}
	return window.id, .None
}

@(require_results)
window_destroy :: proc(p: ^Platform, id: Window_Id) -> Error {
	for window, i in p.windows {
		if window.id != id {
			continue
		}
		if !os_ok(w.DestroyWindow(window.hwnd), "DestroyWindow") {return .Os}
		ordered_remove(&p.windows, i)
		free(window, p.allocator)
		return .None
	}
	return .Invalid_Window
}

window_native_handle :: proc(p: ^Platform, id: Window_Id) -> rawptr {
	window := find_window(p, id)
	return window != nil ? rawptr(window.hwnd) : nil
}

@(require_results)
window_hide :: proc(p: ^Platform, id: Window_Id) -> Error {
	window := find_window(p, id)
	if window == nil {return .Invalid_Window}
	w.ShowWindow(window.hwnd, w.SW_HIDE)
	return .None
}

window_title_bar :: proc(p: ^Platform, id: Window_Id, height, controls_end: i32) {
	if window := find_window(p, id); window != nil {
		window.title_height, window.title_controls_end = height, controls_end
	}
}

@(require_results)
window_client_size :: proc(p: ^Platform, id: Window_Id) -> (width, height: i32, err: Error) {
	window := find_window(p, id)
	if window == nil {return 0, 0, .Invalid_Window}
	rect: w.RECT
	if !os_ok(w.GetClientRect(window.hwnd, &rect), "GetClientRect") {return 0, 0, .Os}
	return rect.right, rect.bottom, .None
}

@(require_results)
window_to_screen :: proc(p: ^Platform, id: Window_Id, x, y: i32) -> (i32, i32, Error) {
	window := find_window(p, id)
	if window == nil {return 0, 0, .Invalid_Window}
	point := w.POINT{x, y}
	if !os_ok(w.ClientToScreen(window.hwnd, &point), "ClientToScreen") {return 0, 0, .Os}
	return point.x, point.y, .None
}

@(require_results)
window_from_screen :: proc(p: ^Platform, id: Window_Id, x, y: i32) -> (i32, i32, Error) {
	window := find_window(p, id)
	if window == nil {return 0, 0, .Invalid_Window}
	point := w.POINT{x, y}
	if !os_ok(w.ScreenToClient(window.hwnd, &point), "ScreenToClient") {return 0, 0, .Os}
	return point.x, point.y, .None
}

@(require_results)
window_at_point :: proc(p: ^Platform, screen_x, screen_y: i32) -> (Window_Id, i32, i32, Error) {
	if p.host.hwnd == nil {return 0, 0, 0, .Not_Initialized}
	hwnd := w.WindowFromPoint({screen_x, screen_y})
	for window in p.windows {
		if window.hwnd != hwnd {continue}
		x, y, err := window_from_screen(p, window.id, screen_x, screen_y)
		return window.id, x, y, err
	}
	return 0, 0, 0, .None
}

@(require_results)
window_set_position :: proc(p: ^Platform, id: Window_Id, screen_x, screen_y: i32) -> Error {
	window := find_window(p, id)
	if window == nil {return .Invalid_Window}
	flags := u32(w.SWP_NOSIZE | w.SWP_NOZORDER | w.SWP_NOACTIVATE)
	if !os_ok(
		w.SetWindowPos(window.hwnd, nil, screen_x, screen_y, 0, 0, flags),
		"SetWindowPos(position)",
	) {return .Os}
	return .None
}

@(require_results)
window_set_client_size :: proc(p: ^Platform, id: Window_Id, width, height: i32) -> Error {
	window := find_window(p, id)
	if window == nil {return .Invalid_Window}
	if width <= 0 || height <= 0 || width > 32767 || height > 32767 {return .Invalid_Argument}
	dpi := window_dpi(p, id)
	if dpi == 0 {return .Os}
	w.SetLastError(0)
	style := w.GetWindowLongW(window.hwnd, w.GWL_STYLE)
	if style == 0 && w.GetLastError() != 0 {
		log.errorf("GetWindowLongW(style) failed: %v", w.GetLastError())
		return .Os
	}
	w.SetLastError(0)
	ex_style := w.GetWindowLongW(window.hwnd, w.GWL_EXSTYLE)
	if ex_style == 0 && w.GetLastError() != 0 {
		log.errorf("GetWindowLongW(exstyle) failed: %v", w.GetLastError())
		return .Os
	}
	rect := w.RECT {
		right  = width,
		bottom = height,
	}
	if !os_ok(
		w.AdjustWindowRectExForDpi(&rect, u32(style), false, u32(ex_style), dpi),
		"AdjustWindowRectExForDpi",
	) {return .Os}
	if window.tabbed_title_bar {rect.top = 0}
	flags := u32(w.SWP_NOMOVE | w.SWP_NOZORDER | w.SWP_NOACTIVATE)
	if !os_ok(
		w.SetWindowPos(
			window.hwnd,
			nil,
			0,
			0,
			rect.right - rect.left,
			rect.bottom - rect.top,
			flags,
		),
		"SetWindowPos(client size)",
	) {return .Os}
	return .None
}

window_dpi :: proc(p: ^Platform, id: Window_Id) -> u32 {
	window := find_window(p, id)
	if window == nil {return 0}
	dpi := w.GetDpiForWindow(window.hwnd)
	if dpi == 0 {
		log.errorf("GetDpiForWindow failed: %d", w.GetLastError())
	}
	return dpi
}

primary_dpi :: proc(p: ^Platform) -> u32 {
	if p.host.hwnd == nil {return 0}
	dpi := w.GetDpiForWindow(p.host.hwnd)
	if dpi == 0 {
		log.errorf("GetDpiForWindow(host) failed: %d", w.GetLastError())
	}
	return dpi
}

window_is_focused :: proc(p: ^Platform, id: Window_Id) -> bool {
	window := find_window(p, id)
	return window != nil && w.GetFocus() == window.hwnd
}

@(require_results)
window_focus :: proc(p: ^Platform, id: Window_Id) -> Error {
	window := find_window(p, id)
	if window == nil {return .Invalid_Window}
	// SW_RESTORE would also un-maximize; only restore when minimized.
	if w.IsIconic(window.hwnd) {w.ShowWindow(window.hwnd, w.SW_RESTORE)}
	if !os_ok(w.SetForegroundWindow(window.hwnd), "SetForegroundWindow") {return .Os}
	w.SetFocus(window.hwnd)
	if w.GetFocus() != window.hwnd {
		log.errorf("SetFocus failed: %d", w.GetLastError())
		return .Os
	}
	return .None
}

@(require_results)
window_set_title :: proc(p: ^Platform, id: Window_Id, title: string) -> Error {
	window := find_window(p, id)
	if window == nil {return .Invalid_Window}
	for c in title {
		if c == 0 {return .Invalid_Argument}
	}
	text := w.utf8_to_wstring(title, p.allocator)
	if text == nil {return .Out_Of_Memory}
	defer delete(text, p.allocator)
	if !os_ok(w.SetWindowTextW(window.hwnd, text), "SetWindowTextW") {return .Os}
	return .None
}

@(require_results)
window_set_frame_color :: proc(
	p: ^Platform,
	id: Window_Id,
	rgb: [3]u8,
	foreground: [3]u8 = {0xec, 0xec, 0xf1},
) -> Error {
	window := find_window(p, id)
	if window == nil {return .Invalid_Window}
	text := u32(foreground[0]) | u32(foreground[1]) << 8 | u32(foreground[2]) << 16
	text_hr := w.DwmSetWindowAttribute(
		window.hwnd,
		u32(w.DWMWINDOWATTRIBUTE.DWMWA_TEXT_COLOR),
		&text,
		size_of(text),
	)
	if text_hr < 0 {
		log.errorf("DwmSetWindowAttribute(text) failed: HRESULT %x", u32(text_hr))
		return .Os
	}
	color := u32(rgb[0]) | u32(rgb[1]) << 8 | u32(rgb[2]) << 16
	hr := w.DwmSetWindowAttribute(
		window.hwnd,
		u32(w.DWMWINDOWATTRIBUTE.DWMWA_CAPTION_COLOR),
		&color,
		size_of(color),
	)
	if hr < 0 {
		log.errorf("DwmSetWindowAttribute(caption) failed: HRESULT %x", u32(hr))
		return .Os
	}
	return .None
}

@(require_results)
window_set_cursor :: proc(p: ^Platform, id: Window_Id, shape: Cursor_Shape) -> Error {
	window := find_window(p, id)
	if window == nil {return .Invalid_Window}
	if shape == .Hidden {
		window.cursor = nil
	} else {
		ids := #partial [Cursor_Shape]w.LPCWSTR {
			.Arrow             = transmute(cstring16)w.IDC_ARROW,
			.Text              = transmute(cstring16)w.IDC_IBEAM,
			.Hand              = transmute(cstring16)w.IDC_HAND,
			.Resize_Horizontal = transmute(cstring16)w.IDC_SIZEWE,
			.Resize_Vertical   = transmute(cstring16)w.IDC_SIZENS,
			.Resize_All        = transmute(cstring16)w.IDC_SIZEALL,
		}
		window.cursor = w.LoadCursorW(nil, ids[shape])
		if window.cursor == nil {
			log.errorf("LoadCursorW failed: %d", w.GetLastError())
			return .Os
		}
	}
	if bool(w.IsWindowVisible(window.hwnd)) {
		point: w.POINT
		if !os_ok(w.GetCursorPos(&point), "GetCursorPos") {return .Os}
		if w.WindowFromPoint(point) == window.hwnd {
			if !os_ok(w.ScreenToClient(window.hwnd, &point), "ScreenToClient") {return .Os}
			width, height, err := window_client_size(p, id)
			if err != .None {return err}
			if point.x >= 0 && point.y >= 0 && point.x < width && point.y < height {
				w.SetCursor(window.cursor)
			}
		}
	}
	return .None
}

@(require_results)
window_flash :: proc(p: ^Platform, id: Window_Id) -> Error {
	window := find_window(p, id)
	if window == nil {return .Invalid_Window}
	info := FLASHWINFO {
		cbSize  = size_of(FLASHWINFO),
		hwnd    = window.hwnd,
		dwFlags = FLASHW_ALL,
		uCount  = 3,
	}
	// FlashWindowEx returns the previous active state, not success.
	FlashWindowEx(&info)
	return .None
}

set_modal_loop_callback :: proc(p: ^Platform, callback: proc(user: rawptr), user: rawptr) {
	p.modal_callback, p.modal_user = callback, user
}

@(private)
mouse_time :: proc(p: ^Platform) -> i64 {
	counter: w.LARGE_INTEGER
	if !os_ok(w.QueryPerformanceCounter(&counter), "QueryPerformanceCounter") {
		p.error = .Os
		return 0
	}
	whole := i64(counter) / i64(p.frequency) * 1_000_000_000
	fraction := i64(counter) % i64(p.frequency) * 1_000_000_000 / i64(p.frequency)
	return whole + fraction
}

@(private)
window_proc :: proc "system" (
	hwnd: w.HWND,
	message: u32,
	wp: w.WPARAM,
	lp: w.LPARAM,
) -> w.LRESULT {
	window := (^Window)(uintptr(w.GetWindowLongPtrW(hwnd, w.GWLP_USERDATA)))
	if message == w.WM_NCCREATE {
		create := (^w.CREATESTRUCTW)(uintptr(lp))
		window = cast(^Window)create.lpCreateParams
		w.SetLastError(0)
		previous := w.SetWindowLongPtrW(hwnd, w.GWLP_USERDATA, w.LONG_PTR(uintptr(window)))
		if previous == 0 && w.GetLastError() != 0 {return 0}
		window.hwnd = hwnd
	}
	if window == nil {return w.DefWindowProcW(hwnd, message, wp, lp)}
	context = window.owner.callback_context
	p := window.owner
	if window.tabbed_title_bar {
		if message == w.WM_NCCALCSIZE && wp != 0 {
			params := cast(^w.NCCALCSIZE_PARAMS)uintptr(lp)
			top := params.rgrc[0].top
			result := w.DefWindowProcW(hwnd, message, wp, lp)
			border :=
				w.GetSystemMetricsForDpi(w.SM_CYFRAME, w.GetDpiForWindow(hwnd)) +
				w.GetSystemMetricsForDpi(w.SM_CXPADDEDBORDER, w.GetDpiForWindow(hwnd))
			params.rgrc[0].top = top + (bool(w.IsZoomed(hwnd)) ? border : 0)
			return result
		}
		if message == w.WM_NCMOUSEMOVE || message == w.WM_NCLBUTTONDOWN {
			point := w.POINT {
				i32(cast(i16)u16(uintptr(lp) & 0xffff)),
				i32(cast(i16)u16(uintptr(lp) >> 16)),
			}
			if os_ok(w.ScreenToClient(hwnd, &point), "ScreenToClient(caption)") {
				if wp == w.HTMINBUTTON || wp == w.HTMAXBUTTON || wp == w.HTCLOSE {
					track := w.TRACKMOUSEEVENT {
						cbSize    = size_of(w.TRACKMOUSEEVENT),
						dwFlags   = w.TME_LEAVE | w.TME_NONCLIENT,
						hwndTrack = hwnd,
					}
					record_os(p, w.TrackMouseEvent(&track), "TrackMouseEvent(caption)")
					packed := w.LPARAM(u32(u16(point.x)) | (u32(u16(point.y)) << 16))
					mouse_message(
						window,
						message == w.WM_NCMOUSEMOVE ? w.WM_MOUSEMOVE : w.WM_LBUTTONDOWN,
						0,
						packed,
					)
					if message == w.WM_NCLBUTTONDOWN {return 0}
				}
			}
		}
		if message == w.WM_NCMOUSELEAVE {
			enqueue(p, Mouse_Move_Event{window = window.id, x = -1, y = -1})
		}
		result: w.LRESULT
		if message != w.WM_NCHITTEST && bool(DwmDefWindowProc(hwnd, message, wp, lp, &result)) {
			return result
		}
		if message == w.WM_NCHITTEST {
			result = w.DefWindowProcW(hwnd, message, wp, lp)
			if result != w.HTCLIENT && result != w.HTCAPTION && result != w.HTTOP {return result}
			point := w.POINT {
				i32(cast(i16)u16(uintptr(lp) & 0xffff)),
				i32(cast(i16)u16(uintptr(lp) >> 16)),
			}
			if !os_ok(w.ScreenToClient(hwnd, &point), "ScreenToClient(title bar)") {return result}
			if !bool(w.IsZoomed(hwnd)) &&
			   point.y < i32(5 * w.GetDpiForWindow(hwnd) / 96) {return w.HTTOP}
			client: w.RECT
			if !os_ok(w.GetClientRect(hwnd, &client), "GetClientRect(caption)") {return result}
			button_width := i32(46 * w.GetDpiForWindow(hwnd) / 96)
			if point.y < window.title_height && point.x >= client.right - 3 * button_width {
				index := clamp(
					(point.x - client.right + 3 * button_width) / max(1, button_width),
					0,
					2,
				)
				hits := [3]w.LRESULT{w.HTMINBUTTON, w.HTMAXBUTTON, w.HTCLOSE}
				return hits[index]
			}
			if point.y < window.title_height &&
			   point.x >= window.title_controls_end {return w.HTCAPTION}
			return w.HTCLIENT
		}
	}
	if message == p.taskbar_created && p.tray_requested {
		p.tray_added = false
		err := tray_add(p)
		if err != .None {
			p.error = err
		}
		return 0
	}
	switch message {
	case ACTIVATE_MESSAGE:
		enqueue(p, Activate_Request_Event{})
		return 0
	case TRAY_MESSAGE:
		code := u32(uintptr(lp) & 0xffff)
		if code == w.WM_LBUTTONUP ||
		   code == w.WM_LBUTTONDBLCLK ||
		   code == w.NIN_SELECT ||
		   code == NIN_KEYSELECT {
			enqueue(p, Tray_Event{})
		}
		if code == w.WM_CONTEXTMENU || code == w.WM_RBUTTONUP {
			tray_popup(p)
		}
		return 0
	case w.WM_CLOSE:
		enqueue(p, Close_Request_Event{window.id})
		return 0
	case w.WM_ERASEBKGND:
		return 1
	case w.WM_PAINT:
		record_os(p, w.ValidateRect(hwnd, nil), "ValidateRect")
		return 0
	case w.WM_SETFOCUS, w.WM_KILLFOCUS:
		if window.id != 0 {
			enqueue(p, Focus_Event{window.id, message == w.WM_SETFOCUS})
		}
		return 0
	case w.WM_SIZE:
		// Resizing beneath a stationary cursor can synthesize WM_MOUSEMOVE after WM_MOUSELEAVE.
		point: w.POINT
		if os_ok(w.GetCursorPos(&point), "GetCursorPos(resize)") &&
		   os_ok(w.ScreenToClient(hwnd, &point), "ScreenToClient(resize)") {
			window.previous_move.x, window.previous_move.y = point.x, point.y
			window.has_previous_move = true
		}
		if window.id != 0 {
			enqueue(
				p,
				Resize_Event {
					window.id,
					i32(uintptr(lp) & 0xffff),
					i32((uintptr(lp) >> 16) & 0xffff),
				},
			)
		}
		if window.sizing && p.modal_callback != nil {
			p.modal_callback(p.modal_user)
		}
		return 0
	case w.WM_SETTINGCHANGE:
		enqueue(p, Settings_Event{})
		return w.DefWindowProcW(hwnd, message, wp, lp)
	case w.WM_DPICHANGED:
		r := (^w.RECT)(uintptr(lp))
		flags := u32(w.SWP_NOZORDER | w.SWP_NOACTIVATE)
		record_os(
			p,
			w.SetWindowPos(hwnd, nil, r.left, r.top, r.right - r.left, r.bottom - r.top, flags),
			"SetWindowPos(DPI)",
		)
		enqueue(p, Dpi_Event{window.id, u32(wp & 0xffff)})
		return 0
	case w.WM_ENTERSIZEMOVE:
		window.sizing = true
		if w.SetTimer(hwnd, SIZING_TIMER_ID, 16, nil) == 0 {
			log.errorf("SetTimer failed: %d", w.GetLastError())
			p.error = .Os
		}
		return 0
	case w.WM_EXITSIZEMOVE:
		window.sizing = false
		record_os(p, w.KillTimer(hwnd, SIZING_TIMER_ID), "KillTimer")
		return 0
	case w.WM_TIMER:
		if wp == SIZING_TIMER_ID && window.sizing && p.modal_callback != nil {
			p.modal_callback(p.modal_user)
		}
		return 0
	case w.WM_SETCURSOR:
		if uintptr(lp) & 0xffff == w.HTCLIENT {
			w.SetCursor(window.cursor)
			return 1
		}
	case w.WM_SYSKEYDOWN, w.WM_SYSKEYUP, w.WM_SYSCHAR, w.WM_SYSDEADCHAR:
		return 0
	case w.WM_MOUSEMOVE,
	     w.WM_MOUSELEAVE,
	     w.WM_LBUTTONDOWN,
	     w.WM_LBUTTONUP,
	     w.WM_LBUTTONDBLCLK,
	     w.WM_RBUTTONDBLCLK,
	     w.WM_MBUTTONDBLCLK,
	     w.WM_XBUTTONDBLCLK,
	     w.WM_RBUTTONDOWN,
	     w.WM_RBUTTONUP,
	     w.WM_MBUTTONDOWN,
	     w.WM_MBUTTONUP,
	     w.WM_XBUTTONDOWN,
	     w.WM_XBUTTONUP,
	     w.WM_MOUSEWHEEL,
	     w.WM_MOUSEHWHEEL:
		mouse_message(window, message, wp, lp)
		return(
			message == w.WM_XBUTTONDOWN || message == w.WM_XBUTTONUP || message == w.WM_XBUTTONDBLCLK ? 1 : 0 \
		)
	case w.WM_CAPTURECHANGED, w.WM_CANCELMODE:
		if window.buttons != 0 {
			window.buttons = 0
			window.has_previous_move = false
			enqueue(p, Capture_Lost_Event{window.id})
		}
		if message == w.WM_CANCELMODE && w.GetCapture() == hwnd {
			record_os(p, w.ReleaseCapture(), "ReleaseCapture(cancel)")
		}
		return 0
	}
	return w.DefWindowProcW(hwnd, message, wp, lp)
}

window_maximized :: proc(p: ^Platform, id: Window_Id) -> bool {
	window := find_window(p, id)
	return window != nil && bool(w.IsZoomed(window.hwnd))
}

window_caption_action :: proc(p: ^Platform, id: Window_Id, index: int) {
	window := find_window(p, id)
	if window == nil || index < 0 || index > 2 {return}
	command: w.WPARAM
	switch index {
	case 0:
		command = w.SC_MINIMIZE
	case 1:
		command = w.SC_MAXIMIZE
		if bool(w.IsZoomed(window.hwnd)) {command = w.SC_RESTORE}
	case 2:
		command = w.SC_CLOSE
	}
	record_os(p, w.PostMessageW(window.hwnd, w.WM_SYSCOMMAND, command, 0), "PostMessageW(caption)")
}

@(private)
mouse_message :: proc(window: ^Window, message: u32, wp: w.WPARAM, lp: w.LPARAM) {
	p := window.owner
	state, ok := keyboard_state()
	if !ok {
		p.error = .Os
		return
	}
	mods := modifiers_from_state(state)
	x := i32(cast(i16)u16(uintptr(lp) & 0xffff))
	y := i32(cast(i16)u16((uintptr(lp) >> 16) & 0xffff))
	time := mouse_time(p)
	if message == w.WM_MOUSEMOVE {
		if !window.tracking {
			track := w.TRACKMOUSEEVENT {
				cbSize    = size_of(w.TRACKMOUSEEVENT),
				dwFlags   = w.TME_LEAVE,
				hwndTrack = window.hwnd,
			}
			if os_ok(w.TrackMouseEvent(&track), "TrackMouseEvent") {
				window.tracking = true
			} else {
				p.error = .Os
			}
		}
		buttons := mouse_buttons(wp)
		previous := window.previous_move
		if !window.has_previous_move ||
		   previous.x != x ||
		   previous.y != y ||
		   previous.buttons != buttons {
			move := Mouse_Move_Event{window.id, x, y, buttons, mods, time}
			window.previous_move = move
			window.has_previous_move = true
			enqueue(p, move)
		}
		return
	}
	if message == w.WM_MOUSELEAVE {
		window.tracking = false
		window.has_previous_move = false
		enqueue(p, Mouse_Leave_Event{window.id})
		return
	}
	if message == w.WM_MOUSEWHEEL || message == w.WM_MOUSEHWHEEL {
		point := w.POINT{x, y}
		if !os_ok(w.ScreenToClient(window.hwnd, &point), "ScreenToClient") {
			p.error = .Os
			return
		}
		delta := f32(cast(i16)u16((wp >> 16) & 0xffff)) / 120
		enqueue(
			p,
			Mouse_Wheel_Event {
				window = window.id,
				x = point.x,
				y = point.y,
				delta_x = message == w.WM_MOUSEHWHEEL ? delta : 0,
				delta_y = message == w.WM_MOUSEWHEEL ? delta : 0,
				modifiers = mods,
				time_ns = time,
			},
		)
		return
	}
	button: input.Mouse_Button
	pressed := false
	switch message {
	case w.WM_LBUTTONDOWN, w.WM_LBUTTONUP, w.WM_LBUTTONDBLCLK:
		button = .Left
		pressed = message != w.WM_LBUTTONUP
	case w.WM_RBUTTONDOWN, w.WM_RBUTTONUP, w.WM_RBUTTONDBLCLK:
		button = .Right
		pressed = message != w.WM_RBUTTONUP
	case w.WM_MBUTTONDOWN, w.WM_MBUTTONUP, w.WM_MBUTTONDBLCLK:
		button = .Middle
		pressed = message != w.WM_MBUTTONUP
	case w.WM_XBUTTONDOWN, w.WM_XBUTTONUP, w.WM_XBUTTONDBLCLK:
		button = (wp >> 16) & 0xffff == 1 ? .Back : .Forward
		pressed = message != w.WM_XBUTTONUP
	}
	bit := u8(1) << u8(button)
	if pressed {
		if w.GetCapture() != window.hwnd {
			w.SetCapture(window.hwnd)
			if w.GetCapture() != window.hwnd {
				log.errorf("SetCapture failed: %d", w.GetLastError())
				p.error = .Os
			}
		}
		window.buttons |= bit
	} else {
		window.buttons &= ~bit
		if window.buttons == 0 && w.GetCapture() == window.hwnd {
			record_os(p, w.ReleaseCapture(), "ReleaseCapture")
		}
	}
	enqueue(p, Mouse_Button_Event{window.id, button, pressed, x, y, mods, time})
}

@(private)
mouse_buttons :: proc(wp: w.WPARAM) -> input.Mouse_Buttons {
	buttons: input.Mouse_Buttons
	if wp & w.MK_LBUTTON != 0 {
		buttons += {.Left}
	}
	if wp & w.MK_RBUTTON != 0 {
		buttons += {.Right}
	}
	if wp & w.MK_MBUTTON != 0 {
		buttons += {.Middle}
	}
	if wp & w.MK_XBUTTON1 != 0 {
		buttons += {.Back}
	}
	if wp & w.MK_XBUTTON2 != 0 {
		buttons += {.Forward}
	}
	return buttons
}
