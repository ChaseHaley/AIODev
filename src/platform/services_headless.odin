package platform

@(require) import "aio:input"
@(require) import "aio:links"
@(require) import "base:runtime"
@(require) import "core:log"
@(require) import "core:strings"

// The headless backend's operating system services. Each records what the app asked for in
// Platform.record, scripted inputs come from the Platform, and nothing reaches the real desktop:
// no tray icon, notification, browser, clipboard or dialog.
when AIO_HEADLESS {
	EXECUTABLE_ICON_MAX :: 256
	// The colour every executable icon reads as, premultiplied RGBA.
	HEADLESS_ICON :: [4]u8{0x30, 0x60, 0xc0, 0xff}

	client_animations_enabled :: proc() -> bool {
		return headless_animations
	}

	@(require_results)
	tray_create :: proc(p: ^Platform, tooltip: string) -> Error {
		if p.wake_event == nil {return .Not_Initialized}
		if p.record.tray_shown || len(tooltip) > 127 {return .Invalid_Argument}
		copied, err := strings.clone(tooltip, p.allocator)
		if err != nil {return .Out_Of_Memory}
		delete(p.record.tray_tooltip, p.allocator)
		p.record.tray_tooltip, p.record.tray_shown = copied, true
		return .None
	}

	@(require_results)
	tray_destroy :: proc(p: ^Platform) -> Error {
		p.record.tray_shown = false
		return .None
	}

	@(require_results)
	tray_set_menu :: proc(p: ^Platform, items: []Tray_Menu_Item) -> Error {
		if p.wake_event == nil {return .Not_Initialized}
		for item in p.record.tray_menu {delete(item.title, p.allocator)}
		clear(&p.record.tray_menu)
		for item in items {
			copied := item
			err: runtime.Allocator_Error
			if copied.title, err = strings.clone(item.title, p.allocator); err != nil {return .Out_Of_Memory}
			if _, err = append(&p.record.tray_menu, copied); err != nil {
				delete(copied.title, p.allocator)
				return .Out_Of_Memory
			}
		}
		return .None
	}

	@(require_results)
	tray_notify :: proc(
		p: ^Platform,
		title, text: string,
		token: Notification_Token = 0,
		sound := true,
	) -> Error {
		if !p.record.tray_shown {return .Not_Initialized}
		return record_notification(p, title, text, token, true, sound)
	}

	@(require_results)
	notification_show :: proc(
		p: ^Platform,
		title, text: string,
		token: Notification_Token,
		sound: bool,
	) -> Error {
		return record_notification(p, title, text, token, false, sound)
	}

	@(private, require_results)
	record_notification :: proc(
		p: ^Platform,
		title, text: string,
		token: Notification_Token,
		balloon, sound: bool,
	) -> Error {
		n := Notification_Record{token = token, balloon = balloon, sound = sound}
		err: runtime.Allocator_Error
		if n.title, err = strings.clone(title, p.allocator); err != nil {return .Out_Of_Memory}
		if n.text, err = strings.clone(text, p.allocator); err == nil {
			_, err = append(&p.record.notifications, n)
		}
		if err != nil {
			delete(n.title, p.allocator)
			delete(n.text, p.allocator)
			return .Out_Of_Memory
		}
		return .None
	}

	// A click on a recorded notification or balloon, which reports its token back as the system would.
	notification_click :: proc(p: ^Platform, token: Notification_Token) {
		enqueue(p, Tray_Notification_Event{token})
	}

	// Counted rather than played. Takes no Platform, as the Win32 one does not, so the count is global.
	notification_sound :: proc() -> Error {
		headless_sounds += 1
		return .None
	}

	@(private)
	headless_sounds: int

	// How many times notification_sound has run in this process.
	notification_sounds :: proc() -> int {
		return headless_sounds
	}

	// The in-memory clipboard. Like the Win32 one it stores line breaks as CRLF.
	@(require_results)
	clipboard_set_text :: proc(p: ^Platform, text: string) -> (ok: bool) {
		if p.wake_event == nil {return false}
		out, err := make([]u8, 2 * len(text), p.allocator)
		if err != nil {return false}
		converted, fits := clipboard_crlf(text, out)
		if !fits {
			delete(out, p.allocator)
			return false
		}
		delete(p.clipboard, p.allocator)
		p.clipboard = converted
		return true
	}

	@(require_results)
	clipboard_get_text :: proc(p: ^Platform, allocator: runtime.Allocator) -> (text: string, ok: bool) {
		if p.wake_event == nil {return "", false}
		copied, err := strings.clone(p.clipboard, allocator)
		return copied, err == nil
	}

	@(require_results)
	open_path :: proc(path: string) -> bool {
		if !open_path_allowed(path) {
			log.warnf("platform: refusing to open a non-local path")
			return false
		}
		return record_opened(&headless_opened_paths, path)
	}

	@(require_results)
	open_url :: proc(uri: string) -> bool {
		if !links.allowed(uri) {
			log.warnf("platform: refusing to open a non-web target")
			return false
		}
		return record_opened(&headless_opened_urls, uri)
	}

	// open_path and open_url take no Platform, so what they opened is kept per process.
	@(private)
	headless_opened_paths, headless_opened_urls: [dynamic]string

	@(private, require_results)
	record_opened :: proc(list: ^[dynamic]string, target: string) -> bool {
		copied, err := strings.clone(target, runtime.heap_allocator())
		if err != nil {return false}
		if list.allocator.procedure == nil {list.allocator = runtime.heap_allocator()}
		if _, append_error := append(list, copied); append_error != nil {
			delete(copied, runtime.heap_allocator())
			return false
		}
		return true
	}

	// The paths and addresses open_path and open_url handed on, oldest first.
	opened_paths :: proc() -> []string {return headless_opened_paths[:]}
	opened_urls :: proc() -> []string {return headless_opened_urls[:]}

	// Forgets what was opened; run between tests that check it.
	opened_clear :: proc() {
		for s in headless_opened_paths {delete(s, runtime.heap_allocator())}
		for s in headless_opened_urls {delete(s, runtime.heap_allocator())}
		clear(&headless_opened_paths)
		clear(&headless_opened_urls)
	}

	// A dialog that has already closed with the next scripted path, or with nothing.
	File_Pick :: struct {
		path: string,
	}

	// Queues the path the next file dialog chooses; an empty path cancels it.
	file_pick_script :: proc(p: ^Platform, path: string) -> Error {
		copied, err := strings.clone(path, p.allocator)
		if err != nil {return .Out_Of_Memory}
		if _, append_error := append(&p.file_picks, copied); append_error != nil {
			delete(copied, p.allocator)
			return .Out_Of_Memory
		}
		return .None
	}

	@(require_results)
	file_pick_start :: proc(
		p: ^Platform,
		id: input.Window_Id,
		filter_name, pattern, directory: string,
		folders := false,
	) -> ^File_Pick {
		if find_window(p, id) == nil {return nil}
		pick, err := new(File_Pick)
		if err != nil {return nil}
		if len(p.file_picks) > 0 {
			chosen := pop_front(&p.file_picks)
			pick.path, _ = strings.clone(chosen)
			delete(chosen, p.allocator)
		}
		return pick
	}

	@(require_results)
	file_pick_finished :: proc(pick: ^File_Pick) -> (path: string, finished: bool) {
		return pick.path, true
	}

	file_pick_destroy :: proc(pick: ^File_Pick) {
		delete(pick.path)
		free(pick)
	}

	// Every executable has the same plain square icon.
	@(require_results)
	executable_icon :: proc(path: string, size: int, pixels: []u8) -> bool {
		if size < 1 || size > EXECUTABLE_ICON_MAX || len(pixels) < size * size * 4 {return false}
		for i in 0 ..< size * size {
			color := HEADLESS_ICON
			copy(pixels[i * 4:], color[:])
		}
		return true
	}

	// No distributions: detection reads nothing from the machine.
	wsl_distributions :: proc(allocator := context.allocator) -> ([]string, runtime.Allocator_Error) {
		return nil, nil
	}

	@(require_results)
	window_set_progress :: proc(
		p: ^Platform,
		id: input.Window_Id,
		state: Progress_State,
		percent: int,
	) -> Error {
		window := find_window(p, id)
		if window == nil {return .Invalid_Window}
		window.progress, window.progress_percent = state, percent
		return .None
	}
}
