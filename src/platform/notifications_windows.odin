package platform

import "core:log"
import w "core:sys/windows"

foreign import notifications {
	"../../build/native/notifications.lib",
	"system:runtimeobject.lib",
	"system:windowsapp.lib",
	"system:propsys.lib",
	"system:shell32.lib",
}

foreign notifications {
	aio_notifications_create :: proc "c"(window: w.HWND, message: u32, out: ^rawptr) -> i32 ---
	aio_notifications_destroy :: proc "c"(state: rawptr) ---
	aio_notifications_show :: proc "c"(
		state: rawptr, title, text: cstring16, token: u32, sound: bool, operation: ^cstring,
	) -> i32 ---
}

// Windows owns banner visibility (including Do Not Disturb); this reports API failures explicitly.
@(require_results)
notification_show :: proc(p: ^Platform, title, text: string, token: u32, sound: bool) -> Error {
	if p.host.hwnd == nil {return .Not_Initialized}
	if p.notifications == nil {
		result := aio_notifications_create(p.host.hwnd, NOTIFICATION_MESSAGE, &p.notifications)
		if result < 0 {
			log.errorf("initializing Windows notifications failed: HRESULT 0x%x", u32(result))
			return .Os
		}
	}
	title_w := w.utf8_to_wstring(title, context.temp_allocator)
	text_w := w.utf8_to_wstring(text, context.temp_allocator)
	if title_w == nil || text_w == nil {return .Os}
	operation: cstring
	result := aio_notifications_show(p.notifications, title_w, text_w, token, sound, &operation)
	if result < 0 {
		log.errorf("Windows notification %s failed: HRESULT 0x%x", operation, u32(result))
		return .Os
	}
	return .None
}

@(require_results)
notification_sound :: proc() -> Error {
	if !os_ok(w.MessageBeep(0x40), "MessageBeep") {return .Os}
	return .None
}
