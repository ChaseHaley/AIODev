package platform

@(require) import "core:log"
@(require) import w "core:sys/windows"

@(require) foreign import notifications {
	"../../build/native/notifications.lib",
	"system:runtimeobject.lib",
	"system:windowsapp.lib",
	"system:propsys.lib",
	"system:shell32.lib",
}

// The Win32 backend; a headless build compiles another (see AIO_HEADLESS in platform.odin).
when !AIO_HEADLESS {
	foreign notifications {
		aio_notifications_create :: proc "c"(window: w.HWND, message: u32, out: ^rawptr) -> i32 ---
		aio_notifications_destroy :: proc "c"(state: rawptr) ---
		aio_notifications_show :: proc "c"(
			state: rawptr, title, text: cstring16, token: Notification_Token, sound: bool, operation: ^cstring,
		) -> i32 ---
	}

	// Windows owns banner visibility (including Do Not Disturb); this reports API failures explicitly.
	// Unavailable means notifications could not start, which the first attempt already reported.
	@(require_results)
	notification_show :: proc(
		p: ^Platform,
		title, text: string,
		token: Notification_Token,
		sound: bool,
	) -> Error {
		if p.host.hwnd == nil {return .Not_Initialized}
		state: rawptr
		switch service in p.notifications {
		case rawptr:
			state = service
		case Service_Failed:
			return .Unavailable
		case nil:
			if result := aio_notifications_create(p.host.hwnd, NOTIFICATION_MESSAGE, &state); result < 0 {
				log.errorf("initializing Windows notifications failed: HRESULT 0x%x", u32(result))
				p.notifications = Service_Failed{}
				return .Os
			}
			p.notifications = state
		}
		title_w := w.utf8_to_wstring(title, context.temp_allocator)
		text_w := w.utf8_to_wstring(text, context.temp_allocator)
		if title_w == nil || text_w == nil {return .Os}
		operation: cstring
		result := aio_notifications_show(state, title_w, text_w, token, sound, &operation)
		if result < 0 {
			log.errorf("Windows notification %s failed: HRESULT 0x%x", operation, u32(result))
			return .Os
		}
		return .None
	}

	@(private)
	notifications_destroy :: proc(p: ^Platform) {
		if state, ready := p.notifications.(rawptr); ready {aio_notifications_destroy(state)}
		p.notifications = nil
	}

	@(require_results)
	notification_sound :: proc() -> Error {
		if !os_ok(w.MessageBeep(MB_ICONINFORMATION), "MessageBeep") {return .Os}
		return .None
	}
}
