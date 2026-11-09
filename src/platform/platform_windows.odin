package platform

@(require) import "aio:input"
@(require) import "base:runtime"
@(require) import "core:log"
@(require) import "core:sync"
@(require) import w "core:sys/windows"
@(require) import "core:unicode/utf16"
@(require) import "core:unicode/utf8"

// The Win32 backend; a headless build compiles another (see AIO_HEADLESS in platform.odin).
when !AIO_HEADLESS {
	@(private)
	ACTIVATE_MESSAGE :: w.WM_APP + 1
	@(private)
	TRAY_MESSAGE :: w.WM_APP + 2
	@(private)
	NOTIFICATION_MESSAGE :: w.WM_APP + 3
	// native/windows_notifications.cpp posts a toast failure as the message it was given plus one.
	@(private)
	NOTIFICATION_FAILED_MESSAGE :: NOTIFICATION_MESSAGE + 1
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
	// While the user drags a window's edge or caption, Windows runs its own message loop inside
	// DispatchMessageW, and the app's loop runs only when the window procedure calls back into it.
	@(private)
	Size_Move :: enum u8 {
		None,
		Looping,
		// The app's tick is running. A message it causes must not start a second tick inside it.
		Ticking,
	}
	// Full screen keeps what leaving it restores; a window without it is windowed.
	@(private)
	Screen_Full :: struct {
		style:     w.LONG_PTR,
		placement: w.WINDOWPLACEMENT,
	}
	@(private)
	Window :: struct {
		owner:                            ^Platform,
		id:                               input.Window_Id,
		hwnd:                             w.HWND,
		cursor:                           w.HCURSOR,
		tracking:                         bool,
		size_move:                        Size_Move,
		buttons:                          u8,
		high_surrogate:                   u16,
		previous_move:                    input.Mouse_Move_Event,
		has_previous_move:                bool,
		tabbed_title_bar:                 bool,
		title_height, title_controls_end: i32,
		screen:                           Maybe(Screen_Full),
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
		tray:                       Tray,
		tray_data:                  w.NOTIFYICONDATAW,
		notifications:              Service(rawptr),
		menu:                       w.HMENU,
		menu_ids:                   []u32,
		modal_callback:             proc(user: rawptr),
		modal_user:                 rawptr,
		frequency:                  w.LARGE_INTEGER,
		taskbar:                    Service(^w.ITaskbarList3),
		com_initialized:            bool,
	}

	// A service the platform starts on first use. Its failure is kept, so a broken service is neither
	// retried nor reported again on every use. No variant means it has not been started.
	@(private)
	Service :: union($T: typeid) {
		T,
		Service_Failed,
	}
	@(private)
	Service_Failed :: struct {}

	// The tray icon the app asked for. No variant means none was. Requested means the shell does not hold
	// it because adding it failed, as it can when Explorer restarts; the next restart tries again.
	@(private)
	Tray :: union {
		Tray_Requested,
		Tray_Added,
	}
	@(private)
	Tray_Requested :: struct {}
	// The shell holds the icon. `balloon` is the token of the last balloon shown on it.
	@(private)
	Tray_Added :: struct {
		balloon: Notification_Token,
	}

	@(private)
	record_os :: proc(p: ^Platform, ok: w.BOOL, call: string) {
		if !os_ok(ok, call) {
			p.error = .Os
		}
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
			// In-process instances already share foreground rights; Windows may deny a redundant grant.
			if primary_pid != w.GetCurrentProcessId() &&
			   (primary_pid == 0 || !bool(AllowSetForegroundWindow(primary_pid))) {
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
		notifications_destroy(p)
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

	// Sleeps until a message, a wake or one of `frames` signals, or the timeout passes. `frames` are swap
	// chain waitables of windows that want to draw; a wait satisfied by one consumes its signal, so the
	// returned index names the window that may now draw without waiting, or -1 when none signaled.
	@(require_results)
	wait_events :: proc(p: ^Platform, timeout_ms: u32, frames: []rawptr) -> (signaled: int, err: Error) {
		signaled = -1
		if p.wake_event == nil {return signaled, .Not_Initialized}
		if p.queues[p.write_queue].count != 0 || sync.atomic_load(&p.wake_pending) != 0 {
			return signaled, .None
		}
		// MsgWaitForMultipleObjectsEx takes at most MAXIMUM_WAIT_OBJECTS - 1 (63) handles.
		handles: [63]w.HANDLE
		handles[0] = p.wake_event
		count := 1
		for frame in frames {
			if count == len(handles) {break}
			handles[count] = w.HANDLE(frame)
			count += 1
		}
		result := MsgWaitForMultipleObjectsEx(
			u32(count),
			&handles[0],
			timeout_ms,
			w.QS_ALLINPUT,
			MWMO_INPUTAVAILABLE,
		)
		if result == w.WAIT_FAILED {
			log.errorf("MsgWaitForMultipleObjectsEx failed: %d", w.GetLastError())
			return signaled, .Os
		}
		if index := int(result - w.WAIT_OBJECT_0); index >= 1 && index < count {signaled = index - 1}
		return signaled, .None
	}

	// Room for every event one more message can produce.
	@(private)
	queue_has_room :: proc(q: ^Event_Queue) -> bool {
		return q.count < len(q.events) - 16 && q.text_used < len(q.text) - 1024
	}

	@(require_results)
	poll_events :: proc(p: ^Platform) -> ([]Event, Error) {
		if p.wake_event == nil {return nil, .Not_Initialized}
		if sync.atomic_exchange(&p.wake_pending, 0) != 0 {
			enqueue(p, Wake_Event{})
		}
		// A modal size/move loop inside DispatchMessageW runs the app's tick, which polls and swaps the
		// queues, so the queue being filled is looked up afresh rather than held across a dispatch.
		message: w.MSG
		for queue_has_room(&p.queues[p.write_queue]) && bool(w.PeekMessageW(&message, nil, 0, 0, w.PM_REMOVE)) {
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
		q := &p.queues[p.write_queue]
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
			runes, count := utf16_feed(&window.high_surrogate, u16(message.wParam & 0xffff))
			for r in runes[:count] {enqueue(p, input.Text_Event{window.id, queue_rune(p, r)})}
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
		event := input.Key_Event {
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
			layout, layout_ok := keyboard_layout()
			if !layout_ok {
				p.error = .Os
				return
			}
			event.unshifted = unshifted_rune(u32(vk), scan, layout)
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
					runes, count := utf16_feed(&pending_high, unit)
					for r in runes[:count] {queue_rune(p, r)}
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
	find_window :: proc(p: ^Platform, id: input.Window_Id) -> ^Window {
		for window in p.windows {
			if window.id == id {return window}
		}
		return nil
	}

	@(require_results)
	window_create :: proc(p: ^Platform, desc: Window_Desc) -> (input.Window_Id, Error) {
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
		window.id = input.Window_Id(p.next_id)
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
				cyTopHeight = i32(TITLE_BAR_HEIGHT * dpi / 96),
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
	window_destroy :: proc(p: ^Platform, id: input.Window_Id) -> Error {
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

	window_native_handle :: proc(p: ^Platform, id: input.Window_Id) -> rawptr {
		window := find_window(p, id)
		return window != nil ? rawptr(window.hwnd) : nil
	}

	@(require_results)
	window_hide :: proc(p: ^Platform, id: input.Window_Id) -> Error {
		window := find_window(p, id)
		if window == nil {return .Invalid_Window}
		w.ShowWindow(window.hwnd, w.SW_HIDE)
		return .None
	}

	window_title_bar :: proc(p: ^Platform, id: input.Window_Id, height, controls_end: i32) {
		if window := find_window(p, id); window != nil {
			window.title_height, window.title_controls_end = height, controls_end
		}
	}

	@(require_results)
	window_client_size :: proc(p: ^Platform, id: input.Window_Id) -> (width, height: i32, err: Error) {
		window := find_window(p, id)
		if window == nil {return 0, 0, .Invalid_Window}
		rect: w.RECT
		if !os_ok(w.GetClientRect(window.hwnd, &rect), "GetClientRect") {return 0, 0, .Os}
		return rect.right, rect.bottom, .None
	}

	@(require_results)
	window_to_screen :: proc(p: ^Platform, id: input.Window_Id, x, y: i32) -> (i32, i32, Error) {
		window := find_window(p, id)
		if window == nil {return 0, 0, .Invalid_Window}
		point := w.POINT{x, y}
		if !os_ok(w.ClientToScreen(window.hwnd, &point), "ClientToScreen") {return 0, 0, .Os}
		return point.x, point.y, .None
	}

	@(require_results)
	window_from_screen :: proc(p: ^Platform, id: input.Window_Id, x, y: i32) -> (i32, i32, Error) {
		window := find_window(p, id)
		if window == nil {return 0, 0, .Invalid_Window}
		point := w.POINT{x, y}
		if !os_ok(w.ScreenToClient(window.hwnd, &point), "ScreenToClient") {return 0, 0, .Os}
		return point.x, point.y, .None
	}

	@(require_results)
	window_at_point :: proc(p: ^Platform, screen_x, screen_y: i32) -> (input.Window_Id, i32, i32, Error) {
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
	window_set_position :: proc(p: ^Platform, id: input.Window_Id, screen_x, screen_y: i32) -> Error {
		window := find_window(p, id)
		if window == nil {return .Invalid_Window}
		flags := u32(w.SWP_NOSIZE | w.SWP_NOZORDER | w.SWP_NOACTIVATE)
		if !os_ok(
			w.SetWindowPos(window.hwnd, nil, screen_x, screen_y, 0, 0, flags),
			"SetWindowPos(position)",
		) {return .Os}
		return .None
	}

	// Moves the window's top-left corner to the point, staying inside the work area of the point's monitor.
	@(require_results)
	window_place_on_monitor :: proc(p: ^Platform, id: input.Window_Id, screen_x, screen_y: i32) -> Error {
		window := find_window(p, id)
		if window == nil {return .Invalid_Window}
		frame: w.RECT
		if !os_ok(w.GetWindowRect(window.hwnd, &frame), "GetWindowRect") {return .Os}
		monitor := w.MonitorFromPoint({screen_x, screen_y}, .MONITOR_DEFAULTTONEAREST)
		info := w.MONITORINFO{cbSize = size_of(w.MONITORINFO)}
		if !os_ok(w.GetMonitorInfoW(monitor, &info), "GetMonitorInfoW") {return .Os}
		area := info.rcWork
		x := max(area.left, min(screen_x, area.right - (frame.right - frame.left)))
		y := max(area.top, min(screen_y, area.bottom - (frame.bottom - frame.top)))
		return window_set_position(p, id, x, y)
	}

	// A small always-on-top copy of part of a window, composed by the desktop window manager. It stays
	// live without the app drawing anything, and the pointer passes through it.
	Thumbnail :: struct {
		hwnd: w.HWND,
		link: w.HANDLE,
	}

	@(require_results)
	thumbnail_create :: proc(
		p: ^Platform,
		source: input.Window_Id,
		region_x, region_y, region_width, region_height: i32,
		width, height: i32,
		border: [3]u8,
	) -> (
		Thumbnail,
		Error,
	) {
		window := find_window(p, source)
		if window == nil {return {}, .Invalid_Window}
		if width <= 0 || height <= 0 || region_width <= 0 || region_height <= 0 {return {}, .Invalid_Argument}
		hwnd := w.CreateWindowExW(
			w.WS_EX_TOOLWINDOW | w.WS_EX_NOACTIVATE | w.WS_EX_TOPMOST | w.WS_EX_LAYERED | w.WS_EX_TRANSPARENT,
			w.L("Static"),
			nil,
			w.WS_POPUP | SS_BLACKRECT,
			0,
			0,
			width,
			height,
			nil,
			nil,
			p.instance,
			nil,
		)
		if hwnd == nil {
			log.errorf("CreateWindowExW(thumbnail) failed: %d", w.GetLastError())
			return {}, .Os
		}
		thumbnail := Thumbnail{hwnd = hwnd}
		if !os_ok(w.SetLayeredWindowAttributes(hwnd, 0, 255, w.LWA_ALPHA), "SetLayeredWindowAttributes") {
			thumbnail_destroy(&thumbnail)
			return {}, .Os
		}
		// Rounded corners and a border are Windows 11 attributes; older systems keep a plain rectangle.
		corner := i32(DWMWCP_ROUND)
		corner_attribute := u32(w.DWMWINDOWATTRIBUTE.DWMWA_WINDOW_CORNER_PREFERENCE)
		_ = w.DwmSetWindowAttribute(hwnd, corner_attribute, &corner, size_of(corner))
		color := u32(border[0]) | u32(border[1]) << 8 | u32(border[2]) << 16
		border_attribute := u32(w.DWMWINDOWATTRIBUTE.DWMWA_BORDER_COLOR)
		_ = w.DwmSetWindowAttribute(hwnd, border_attribute, &color, size_of(color))
		if hr := DwmRegisterThumbnail(hwnd, window.hwnd, &thumbnail.link); hr < 0 {
			log.errorf("DwmRegisterThumbnail failed: HRESULT %x", u32(hr))
			thumbnail_destroy(&thumbnail)
			return {}, .Os
		}
		properties := DWM_THUMBNAIL_PROPERTIES {
			dwFlags               = DWM_TNP_RECTDESTINATION |
				DWM_TNP_RECTSOURCE |
				DWM_TNP_VISIBLE |
				DWM_TNP_SOURCECLIENTAREAONLY,
			rcDestination         = {0, 0, width, height},
			rcSource              = {region_x, region_y, region_x + region_width, region_y + region_height},
			fVisible              = true,
			fSourceClientAreaOnly = true,
		}
		if hr := DwmUpdateThumbnailProperties(thumbnail.link, &properties); hr < 0 {
			log.errorf("DwmUpdateThumbnailProperties failed: HRESULT %x", u32(hr))
			thumbnail_destroy(&thumbnail)
			return {}, .Os
		}
		return thumbnail, .None
	}

	// Shows the thumbnail at the point without activating it.
	thumbnail_place :: proc(thumbnail: Thumbnail, screen_x, screen_y: i32) {
		flags := u32(w.SWP_NOSIZE | w.SWP_NOACTIVATE | w.SWP_SHOWWINDOW)
		if !w.SetWindowPos(thumbnail.hwnd, w.HWND_TOPMOST, screen_x, screen_y, 0, 0, flags) {
			log.errorf("SetWindowPos(thumbnail) failed: %d", w.GetLastError())
		}
	}

	thumbnail_hide :: proc(thumbnail: Thumbnail) {
		w.ShowWindow(thumbnail.hwnd, w.SW_HIDE)
	}

	// A zero Thumbnail is none; thumbnail_create made this one and thumbnail_destroy has not run.
	thumbnail_exists :: proc(thumbnail: Thumbnail) -> bool {
		return thumbnail != {}
	}

	thumbnail_destroy :: proc(thumbnail: ^Thumbnail) {
		if thumbnail.link != nil {
			if hr := DwmUnregisterThumbnail(thumbnail.link); hr < 0 {
				log.errorf("DwmUnregisterThumbnail failed: HRESULT %x", u32(hr))
			}
		}
		if thumbnail.hwnd != nil && !w.DestroyWindow(thumbnail.hwnd) {
			log.errorf("DestroyWindow(thumbnail) failed: %d", w.GetLastError())
		}
		thumbnail^ = {}
	}

	@(require_results)
	window_set_client_size :: proc(p: ^Platform, id: input.Window_Id, width, height: i32) -> Error {
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

	window_dpi :: proc(p: ^Platform, id: input.Window_Id) -> u32 {
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

	window_is_focused :: proc(p: ^Platform, id: input.Window_Id) -> bool {
		window := find_window(p, id)
		return window != nil && w.GetFocus() == window.hwnd
	}

	@(require_results)
	window_focus :: proc(p: ^Platform, id: input.Window_Id) -> Error {
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

	// Keeps the window's maximized state and raises it above other applications without taking focus.
	@(require_results)
	window_show_raised :: proc(p: ^Platform, id: input.Window_Id) -> Error {
		window := find_window(p, id)
		if window == nil {return .Invalid_Window}
		flags := u32(w.SWP_NOMOVE | w.SWP_NOSIZE | w.SWP_NOACTIVATE | w.SWP_SHOWWINDOW)
		if !os_ok(w.SetWindowPos(window.hwnd, w.HWND_TOP, 0, 0, 0, 0, flags), "SetWindowPos(raise)") {return .Os}
		return .None
	}

	window_maximize :: proc(p: ^Platform, id: input.Window_Id) {
		if window := find_window(p, id); window != nil {w.ShowWindow(window.hwnd, w.SW_MAXIMIZE)}
	}

	@(require_results)
	window_placement :: proc(p: ^Platform, id: input.Window_Id) -> (Window_Placement, Error) {
		window := find_window(p, id)
		if window == nil {return {}, .Invalid_Window}
		placement := w.WINDOWPLACEMENT {
			length = size_of(w.WINDOWPLACEMENT),
		}
		if !os_ok(w.GetWindowPlacement(window.hwnd, &placement), "GetWindowPlacement") {return {}, .Os}
		r := placement.rcNormalPosition
		return {r.left, r.top, r.right, r.bottom, bool(w.IsZoomed(window.hwnd))}, .None
	}

	// Moves a hidden window to its restored rectangle and leaves it hidden. Windows pulls the rectangle back
	// on screen if its monitor has gone. Maximizing waits until the window is shown.
	@(require_results)
	window_set_placement :: proc(p: ^Platform, id: input.Window_Id, target: Window_Placement) -> Error {
		window := find_window(p, id)
		if window == nil {return .Invalid_Window}
		placement := w.WINDOWPLACEMENT {
			length = size_of(w.WINDOWPLACEMENT),
		}
		if !os_ok(w.GetWindowPlacement(window.hwnd, &placement), "GetWindowPlacement") {return .Os}
		placement.showCmd = u32(w.SW_HIDE)
		placement.rcNormalPosition = {target.left, target.top, target.right, target.bottom}
		if !os_ok(w.SetWindowPlacement(window.hwnd, &placement), "SetWindowPlacement") {return .Os}
		return .None
	}

	@(require_results)
	window_show_inactive :: proc(p: ^Platform, id: input.Window_Id) -> Error {
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
	window_set_title :: proc(p: ^Platform, id: input.Window_Id, title: string) -> Error {
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
		id: input.Window_Id,
		rgb: [3]u8,
		foreground: [3]u8,
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
	window_set_cursor :: proc(p: ^Platform, id: input.Window_Id, shape: Cursor_Shape) -> Error {
		window := find_window(p, id)
		if window == nil {return .Invalid_Window}
		if shape == .Hidden {
			window.cursor = nil
		} else {
			ids := #partial [Cursor_Shape]w.LPCWSTR {
				.Arrow                          = transmute(cstring16)w.IDC_ARROW,
				.Text                           = transmute(cstring16)w.IDC_IBEAM,
				.Hand                           = transmute(cstring16)w.IDC_HAND,
				.Resize_Horizontal              = transmute(cstring16)w.IDC_SIZEWE,
				.Resize_Vertical                = transmute(cstring16)w.IDC_SIZENS,
				.Resize_Northwest_Southeast     = transmute(cstring16)w.IDC_SIZENWSE,
				.Resize_Northeast_Southwest     = transmute(cstring16)w.IDC_SIZENESW,
				.Resize_All                     = transmute(cstring16)w.IDC_SIZEALL,
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
	window_flash :: proc(p: ^Platform, id: input.Window_Id) -> Error {
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

	// Runs the app's loop from inside the modal loop. The tick may close the window, so the window is
	// looked up again afterwards, and it may end the loop, which must not be undone.
	@(private)
	size_move_tick :: proc(p: ^Platform, window: ^Window) {
		if window.size_move != .Looping || p.modal_callback == nil {return}
		id := window.id
		window.size_move = .Ticking
		p.modal_callback(p.modal_user)
		if still := find_window(p, id); still != nil && still.size_move == .Ticking {still.size_move = .Looping}
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
				// A window maximized before going full screen stays zoomed underneath it, with no frame to hide.
				params.rgrc[0].top = top + (window.screen == nil && bool(w.IsZoomed(hwnd)) ? border : 0)
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
			// A move outside the client area, not Mouse_Leave_Event: the pointer may still be over the client,
			// and an ordinary move lets the app's pointer routing clear only the caption buttons' hover.
			if message == w.WM_NCMOUSELEAVE {
				enqueue(p, input.Mouse_Move_Event{window = window.id, x = -1, y = -1})
			}
			result: w.LRESULT
			if message != w.WM_NCHITTEST && bool(DwmDefWindowProc(hwnd, message, wp, lp, &result)) {
				return result
			}
			if message == w.WM_NCHITTEST {
				result = w.DefWindowProcW(hwnd, message, wp, lp)
				if window.screen != nil {return result}
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
				button_width := i32(CAPTION_BUTTON_WIDTH * w.GetDpiForWindow(hwnd) / 96)
				count := i32(len(Caption_Button))
				if point.y < window.title_height && point.x >= client.right - count * button_width {
					index := clamp(
						(point.x - client.right + count * button_width) / max(1, button_width),
						0,
						count - 1,
					)
					hits := [Caption_Button]w.LRESULT {
						.Minimize = w.HTMINBUTTON,
						.Maximize = w.HTMAXBUTTON,
						.Close    = w.HTCLOSE,
					}
					return hits[Caption_Button(index)]
				}
				if point.y < window.title_height &&
				   point.x >= window.title_controls_end {return w.HTCAPTION}
				return w.HTCLIENT
			}
		}
		if message == p.taskbar_created && p.tray != nil {
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
		case NOTIFICATION_MESSAGE:
			enqueue(p, Tray_Notification_Event{Notification_Token(wp)})
			return 0
		case NOTIFICATION_FAILED_MESSAGE:
			enqueue(p, Notification_Error_Event{u32(wp)})
			return 0
		case TRAY_MESSAGE:
			code := u32(uintptr(lp) & 0xffff)
			if code == w.WM_LBUTTONUP ||
			   code == w.WM_LBUTTONDBLCLK ||
			   code == w.NIN_SELECT ||
			   code == NIN_KEYSELECT {
				enqueue(p, Tray_Event{})
			}
			if code == NIN_BALLOONUSERCLICK {tray_balloon_clicked(p)}
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
			size_move_tick(p, window)
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
			window.size_move = .Looping
			if w.SetTimer(hwnd, SIZING_TIMER_ID, 16, nil) == 0 {
				log.errorf("SetTimer failed: %d", w.GetLastError())
				p.error = .Os
			}
			return 0
		case w.WM_EXITSIZEMOVE:
			window.size_move = .None
			record_os(p, w.KillTimer(hwnd, SIZING_TIMER_ID), "KillTimer")
			return 0
		case w.WM_TIMER:
			if wp == SIZING_TIMER_ID {size_move_tick(p, window)}
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

	window_maximized :: proc(p: ^Platform, id: input.Window_Id) -> bool {
		window := find_window(p, id)
		return window != nil && bool(w.IsZoomed(window.hwnd))
	}

	// window_set_screen covers the monitor with no caption or frame, and restores the prior placement.
	// An error means the window stayed as it was, so the caller's view of it stays true.
	window_set_screen :: proc(p: ^Platform, id: input.Window_Id, on: bool) -> Error {
		window := find_window(p, id)
		if window == nil {return .Invalid_Window}
		full, is_full := window.screen.?
		if on == is_full {return .None}
		if on {
			full = {
				placement = {length = size_of(w.WINDOWPLACEMENT)},
			}
			if !os_ok(w.GetWindowPlacement(window.hwnd, &full.placement), "GetWindowPlacement") {return .Os}
			info := w.MONITORINFO {
				cbSize = size_of(w.MONITORINFO),
			}
			// MONITOR_DEFAULTTONEAREST: the monitor that holds most of the window, or the nearest one.
			monitor := w.MonitorFromWindow(window.hwnd, w.Monitor_From_Flags(2))
			if !os_ok(w.GetMonitorInfoW(monitor, &info), "GetMonitorInfoW") {return .Os}
			full.style = w.GetWindowLongPtrW(window.hwnd, w.GWL_STYLE)
			_ = w.SetWindowLongPtrW(window.hwnd, w.GWL_STYLE, screen_style(full))
			rect := info.rcMonitor
			// Set first: moving the window recalculates its frame, which reads this.
			window.screen = full
			if !os_ok(
				w.SetWindowPos(
					window.hwnd,
					w.HWND_TOP,
					rect.left,
					rect.top,
					rect.right - rect.left,
					rect.bottom - rect.top,
					w.SWP_FRAMECHANGED | w.SWP_NOOWNERZORDER,
				),
				"SetWindowPos(screen)",
			) {
				window.screen = nil
				_ = w.SetWindowLongPtrW(window.hwnd, w.GWL_STYLE, full.style)
				return .Os
			}
			return .None
		}
		// Cleared first for the same reason; a refused placement puts full screen back.
		_ = w.SetWindowLongPtrW(window.hwnd, w.GWL_STYLE, full.style)
		window.screen = nil
		if !os_ok(w.SetWindowPlacement(window.hwnd, &full.placement), "SetWindowPlacement") {
			window.screen = full
			_ = w.SetWindowLongPtrW(window.hwnd, w.GWL_STYLE, screen_style(full))
			return .Os
		}
		// The window is back in its place; a frame left stale until the next resize is not worth
		// reporting as a refusal, which would leave the app believing it is still full screen.
		_ = os_ok(
			w.SetWindowPos(
				window.hwnd,
				nil,
				0,
				0,
				0,
				0,
				w.SWP_NOMOVE | w.SWP_NOSIZE | w.SWP_NOZORDER | w.SWP_FRAMECHANGED,
			),
			"SetWindowPos(restore frame)",
		)
		return .None
	}

	@(private)
	screen_style :: proc(full: Screen_Full) -> w.LONG_PTR {
		return full.style & ~(w.LONG_PTR(w.WS_CAPTION) | w.LONG_PTR(w.WS_THICKFRAME))
	}

	window_caption_action :: proc(p: ^Platform, id: input.Window_Id, button: Caption_Button) {
		window := find_window(p, id)
		if window == nil {return}
		command: w.WPARAM
		switch button {
		case .Minimize:
			command = w.SC_MINIMIZE
		case .Maximize:
			command = w.SC_MAXIMIZE
			if bool(w.IsZoomed(window.hwnd)) {command = w.SC_RESTORE}
		case .Close:
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
				move := input.Mouse_Move_Event{window.id, x, y, buttons, mods, time}
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
				input.Mouse_Wheel_Event {
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
		enqueue(p, input.Mouse_Button_Event{window.id, button, pressed, x, y, mods, time})
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
}
