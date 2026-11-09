package platform

@(require) import "aio:input"
@(require) import "base:runtime"
@(require) import "core:log"
@(require) import "core:strings"
@(require) import "core:sync"
@(require) import w "core:sys/windows"
@(require) import "core:unicode/utf16"

// The headless backend (WORK-349): the app runs as usual, but its windows exist only on a virtual
// desktop held here. Nothing appears on the owner's desktop and nothing asks for the foreground.
// Window handles are nil, so surfaces render offscreen. Events come only from the app's own calls,
// such as a resize, and from whoever drives it: tests through the app, a harness through verify.
when AIO_HEADLESS {
	@(private)
	EVENT_CAPACITY :: 2048
	@(private)
	TEXT_CAPACITY :: 65536

	// The default virtual desktop: one 1920x1080 display at 96 DPI, with no taskbar, so the work area
	// is the whole display and workspace coordinates are screen coordinates.
	DEFAULT_DISPLAY :: Display {
		rect = {0, 0, 1920, 1080},
		dpi  = 96,
	}

	// A rectangle in virtual desktop pixels; right and bottom are exclusive.
	Desktop_Rect :: struct {
		left, top, right, bottom: i32,
	}

	Display :: struct {
		rect: Desktop_Rect,
		dpi:  u32,
	}

	@(private)
	Event_Queue :: struct {
		events:    []Event,
		count:     int,
		text:      []u8,
		text_used: int,
	}

	@(private)
	Window :: struct {
		id:                               input.Window_Id,
		title:                            string,
		// The client area on the virtual desktop. Headless windows have no OS frame.
		rect:                             Desktop_Rect,
		visible, maximized:               bool,
		// Where a maximized or full-screen window returns to.
		restored:                         Desktop_Rect,
		screen:                           Maybe(Desktop_Rect),
		cursor:                           Cursor_Shape,
		title_height, title_controls_end: i32,
		frame_color, frame_text:          [3]u8,
		progress:                         Progress_State,
		progress_percent:                 int,
	}

	// What the app asked of the operating system's services, for tests and the harness to read.
	Record :: struct {
		notifications:    [dynamic]Notification_Record,
		flashes:          int,
		tray_tooltip:     string,
		tray_shown:       bool,
		tray_menu:        [dynamic]Tray_Menu_Item,
		// How many times a drag thumbnail was placed on the desktop.
		thumbnail_places: int,
	}

	// A notification or tray balloon, with the token a click on it reports.
	Notification_Record :: struct {
		title, text: string,
		token:       Notification_Token,
		balloon:     bool,
		sound:       bool,
	}

	Platform :: struct {
		allocator:        runtime.Allocator,
		mutex:            w.HANDLE,
		wake_event:       w.HANDLE,
		wake_pending:     u32,
		displays:         [dynamic]Display,
		// Bottom to top: the last visible window under a point is the one hit.
		windows:          [dynamic]^Window,
		focused:          input.Window_Id,
		next_id:          u64,
		queues:           [2]Event_Queue,
		write_queue:      int,
		error:            Error,
		clipboard:        string,
		// Paths the next file dialogs choose, oldest first; an empty string or none cancels.
		file_picks:       [dynamic]string,
		record:           Record,
		modal_callback:   proc(user: rawptr),
		modal_user:       rawptr,
		next_thumbnail:   u32,
	}

	// The two platform services that take no Platform read these.
	@(private)
	headless_animations := true

	// What client_animations_enabled reports from now on; Windows' own setting is never read.
	set_client_animations :: proc(enabled: bool) {
		headless_animations = enabled
	}

	@(require_results)
	init :: proc(p: ^Platform, app_id: string, allocator := context.allocator) -> Init_Result {
		if p.wake_event != nil {return .Failed}
		name, name_error := mutex_name(app_id)
		if name_error != .None {return .Failed}
		p.allocator = allocator
		success := false
		defer if !success {_ = destroy(p)}
		// The same mutex as the Win32 backend, so instance_running finds a headless instance. Another
		// process of the same app id is not told to activate: there is nothing to show.
		p.mutex = CreateMutexW(nil, false, cstring16(raw_data(name[:])))
		if p.mutex == nil {
			log.errorf("CreateMutexW failed: %d", w.GetLastError())
			return .Failed
		}
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
		p.windows = make([dynamic]^Window, 0, 4, allocator)
		p.displays = make([dynamic]Display, 0, 2, allocator)
		p.file_picks = make([dynamic]string, allocator)
		p.record = {
			notifications = make([dynamic]Notification_Record, allocator),
			tray_menu     = make([dynamic]Tray_Menu_Item, allocator),
		}
		if _, err := append(&p.displays, DEFAULT_DISPLAY); err != nil {return .Failed}
		success = true
		return .Primary
	}

	@(require_results)
	destroy :: proc(p: ^Platform) -> Error {
		if p == nil {return .None}
		first_error := p.error
		for window in p.windows {window_free(p, window)}
		delete(p.windows)
		delete(p.displays)
		for &q in p.queues {
			delete(q.events, p.allocator)
			delete(q.text, p.allocator)
		}
		delete(p.clipboard, p.allocator)
		for path in p.file_picks {delete(path, p.allocator)}
		delete(p.file_picks)
		record_clear(p)
		delete(p.record.notifications)
		delete(p.record.tray_menu)
		if p.wake_event != nil && !os_ok(w.CloseHandle(p.wake_event), "CloseHandle(wake)") {
			first_error = .Os
		}
		if p.mutex != nil && !os_ok(w.CloseHandle(p.mutex), "CloseHandle(mutex)") {first_error = .Os}
		p^ = {}
		return first_error
	}

	// Empties the record, so a test reads only what follows.
	record_clear :: proc(p: ^Platform) {
		for n in p.record.notifications {
			delete(n.title, p.allocator)
			delete(n.text, p.allocator)
		}
		for item in p.record.tray_menu {delete(item.title, p.allocator)}
		delete(p.record.tray_tooltip, p.allocator)
		clear(&p.record.notifications)
		clear(&p.record.tray_menu)
		p.record.tray_tooltip = ""
		p.record.flashes, p.record.thumbnail_places = 0, 0
	}

	// Replaces the virtual desktop's displays; the first is the primary. Windows keep their places.
	set_displays :: proc(p: ^Platform, displays: []Display) -> Error {
		if len(displays) == 0 {return .Invalid_Argument}
		for d in displays {
			if d.dpi == 0 || d.rect.right <= d.rect.left || d.rect.bottom <= d.rect.top {
				return .Invalid_Argument
			}
		}
		previous := make([]u32, len(p.windows), context.temp_allocator)
		for window, i in p.windows {previous[i] = display_at(p, window.rect).dpi}
		clear(&p.displays)
		if _, err := append(&p.displays, ..displays); err != nil {return .Out_Of_Memory}
		for window, i in p.windows {dpi_follow(p, window, previous[i])}
		return .None
	}

	@(private)
	window_free :: proc(p: ^Platform, window: ^Window) {
		delete(window.title, p.allocator)
		free(window, p.allocator)
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

	// Sleeps until a wake or the timeout. Offscreen surfaces have no frame waitables, so `frames` is
	// always empty here and nothing signals.
	@(require_results)
	wait_events :: proc(p: ^Platform, timeout_ms: u32, frames: []rawptr) -> (signaled: int, err: Error) {
		signaled = -1
		if p.wake_event == nil {return signaled, .Not_Initialized}
		if p.queues[p.write_queue].count != 0 || sync.atomic_load(&p.wake_pending) != 0 {
			return signaled, .None
		}
		if w.WaitForSingleObject(p.wake_event, timeout_ms) == w.WAIT_FAILED {
			log.errorf("WaitForSingleObject failed: %d", w.GetLastError())
			return signaled, .Os
		}
		return signaled, .None
	}

	@(require_results)
	poll_events :: proc(p: ^Platform) -> ([]Event, Error) {
		if p.wake_event == nil {return nil, .Not_Initialized}
		if sync.atomic_exchange(&p.wake_pending, 0) != 0 {enqueue(p, Wake_Event{})}
		q := &p.queues[p.write_queue]
		result := q.events[:q.count]
		p.write_queue = 1 - p.write_queue
		p.queues[p.write_queue].count = 0
		p.queues[p.write_queue].text_used = 0
		err := p.error
		p.error = .None
		return result, err
	}

	@(private)
	find_window :: proc(p: ^Platform, id: input.Window_Id) -> ^Window {
		for window in p.windows {
			if window.id == id {return window}
		}
		return nil
	}

	@(private)
	rect_width :: proc(r: Desktop_Rect) -> i32 {return r.right - r.left}
	@(private)
	rect_height :: proc(r: Desktop_Rect) -> i32 {return r.bottom - r.top}

	// The display holding the rectangle's centre, or the nearest one to it.
	@(private)
	display_at :: proc(p: ^Platform, r: Desktop_Rect) -> Display {
		x, y := r.left + rect_width(r) / 2, r.top + rect_height(r) / 2
		best := p.displays[0]
		best_distance := max(i64)
		for d in p.displays {
			dx := i64(max(d.rect.left - x, 0, x - (d.rect.right - 1)))
			dy := i64(max(d.rect.top - y, 0, y - (d.rect.bottom - 1)))
			if distance := dx * dx + dy * dy; distance < best_distance {best, best_distance = d, distance}
		}
		return best
	}

	// A window that now sits on a display of another DPI hears about it, as WM_DPICHANGED tells it.
	@(private)
	dpi_follow :: proc(p: ^Platform, window: ^Window, before: u32) {
		if after := display_at(p, window.rect).dpi; after != before {enqueue(p, Dpi_Event{window.id, after})}
	}

	@(private)
	set_rect :: proc(p: ^Platform, window: ^Window, r: Desktop_Rect) {
		before_dpi := display_at(p, window.rect).dpi
		resized := rect_width(r) != rect_width(window.rect) || rect_height(r) != rect_height(window.rect)
		window.rect = r
		if resized {enqueue(p, Resize_Event{window.id, rect_width(r), rect_height(r)})}
		dpi_follow(p, window, before_dpi)
	}

	// Moves the window to the top of the stack, as raising it does.
	@(private)
	raise :: proc(p: ^Platform, window: ^Window) {
		for other, i in p.windows {
			if other != window {continue}
			ordered_remove(&p.windows, i)
			append(&p.windows, window)
			return
		}
	}

	@(private)
	set_focus :: proc(p: ^Platform, id: input.Window_Id) {
		if p.focused == id {return}
		if p.focused != 0 && find_window(p, p.focused) != nil {enqueue(p, Focus_Event{p.focused, false})}
		p.focused = id
		if id != 0 {enqueue(p, Focus_Event{id, true})}
	}

	@(require_results)
	window_create :: proc(p: ^Platform, desc: Window_Desc) -> (input.Window_Id, Error) {
		if p.wake_event == nil {return 0, .Not_Initialized}
		if desc.width <= 0 || desc.height <= 0 || desc.width > 32767 || desc.height > 32767 {
			return 0, .Invalid_Argument
		}
		for c in desc.title {
			if c == 0 {return 0, .Invalid_Argument}
		}
		window, alloc_error := new(Window, p.allocator)
		if alloc_error != nil {return 0, .Out_Of_Memory}
		title, title_error := strings.clone(desc.title, p.allocator)
		if title_error != nil {
			free(window, p.allocator)
			return 0, .Out_Of_Memory
		}
		p.next_id += 1
		window.id, window.title = input.Window_Id(p.next_id), title
		// Cascaded from the primary display's corner, as CW_USEDEFAULT places windows.
		step := i32(len(p.windows) % 8) * 32
		left, top := p.displays[0].rect.left + step, p.displays[0].rect.top + step
		window.rect = {left, top, left + desc.width, top + desc.height}
		if _, err := append(&p.windows, window); err != nil {
			window_free(p, window)
			return 0, .Out_Of_Memory
		}
		enqueue(p, Resize_Event{window.id, desc.width, desc.height})
		if !desc.hidden {
			window.visible = true
			if !desc.inactive {set_focus(p, window.id)}
		}
		return window.id, .None
	}

	@(require_results)
	window_destroy :: proc(p: ^Platform, id: input.Window_Id) -> Error {
		for window, i in p.windows {
			if window.id != id {continue}
			if p.focused == id {p.focused = 0}
			ordered_remove(&p.windows, i)
			window_free(p, window)
			return .None
		}
		return .Invalid_Window
	}

	// Always nil: surfaces made for headless windows render offscreen.
	window_native_handle :: proc(p: ^Platform, id: input.Window_Id) -> rawptr {
		return nil
	}

	@(require_results)
	window_hide :: proc(p: ^Platform, id: input.Window_Id) -> Error {
		window := find_window(p, id)
		if window == nil {return .Invalid_Window}
		window.visible = false
		if p.focused == id {set_focus(p, 0)}
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
		return rect_width(window.rect), rect_height(window.rect), .None
	}

	@(require_results)
	window_to_screen :: proc(p: ^Platform, id: input.Window_Id, x, y: i32) -> (i32, i32, Error) {
		window := find_window(p, id)
		if window == nil {return 0, 0, .Invalid_Window}
		return window.rect.left + x, window.rect.top + y, .None
	}

	@(require_results)
	window_from_screen :: proc(p: ^Platform, id: input.Window_Id, x, y: i32) -> (i32, i32, Error) {
		window := find_window(p, id)
		if window == nil {return 0, 0, .Invalid_Window}
		return x - window.rect.left, y - window.rect.top, .None
	}

	// The topmost visible window under the point, as WindowFromPoint finds it, or 0 for none.
	@(require_results)
	window_at_point :: proc(p: ^Platform, screen_x, screen_y: i32) -> (input.Window_Id, i32, i32, Error) {
		if p.wake_event == nil {return 0, 0, 0, .Not_Initialized}
		#reverse for window in p.windows {
			r := window.rect
			inside := screen_x >= r.left && screen_x < r.right && screen_y >= r.top && screen_y < r.bottom
			if !window.visible || !inside {continue}
			return window.id, screen_x - r.left, screen_y - r.top, .None
		}
		return 0, 0, 0, .None
	}

	@(require_results)
	window_set_position :: proc(p: ^Platform, id: input.Window_Id, screen_x, screen_y: i32) -> Error {
		window := find_window(p, id)
		if window == nil {return .Invalid_Window}
		r := window.rect
		set_rect(p, window, {screen_x, screen_y, screen_x + rect_width(r), screen_y + rect_height(r)})
		return .None
	}

	@(require_results)
	window_place_on_monitor :: proc(p: ^Platform, id: input.Window_Id, screen_x, screen_y: i32) -> Error {
		window := find_window(p, id)
		if window == nil {return .Invalid_Window}
		area := display_at(p, {screen_x, screen_y, screen_x + 1, screen_y + 1}).rect
		width, height := rect_width(window.rect), rect_height(window.rect)
		x := max(area.left, min(screen_x, area.right - width))
		y := max(area.top, min(screen_y, area.bottom - height))
		return window_set_position(p, id, x, y)
	}

	// The window's display: virtual displays have no taskbar, so the work area is all of it.
	@(require_results)
	window_work_area :: proc(p: ^Platform, id: input.Window_Id) -> (left, top, right, bottom: i32, err: Error) {
		window := find_window(p, id)
		if window == nil {return 0, 0, 0, 0, .Invalid_Window}
		r := display_at(p, window.rect).rect
		return r.left, r.top, r.right, r.bottom, .None
	}

	// A drag thumbnail has nothing to draw headless; placing one is only counted.
	Thumbnail :: struct {
		id:    u32,
		owner: ^Platform,
	}

	@(require_results)
	thumbnail_create :: proc(
		p: ^Platform,
		source: input.Window_Id,
		x, y, width, height: i32,
		thumbnail_width, thumbnail_height: i32,
		accent: [3]u8,
	) -> (
		Thumbnail,
		Error,
	) {
		if find_window(p, source) == nil {return {}, .Invalid_Window}
		if width <= 0 || height <= 0 || thumbnail_width <= 0 || thumbnail_height <= 0 {return {}, .Invalid_Argument}
		p.next_thumbnail += 1
		return {p.next_thumbnail, p}, .None
	}

	thumbnail_place :: proc(thumbnail: Thumbnail, screen_x, screen_y: i32) {
		if thumbnail.owner != nil {thumbnail.owner.record.thumbnail_places += 1}
	}

	thumbnail_hide :: proc(thumbnail: Thumbnail) {}

	thumbnail_exists :: proc(thumbnail: Thumbnail) -> bool {
		return thumbnail.id != 0
	}

	thumbnail_destroy :: proc(thumbnail: ^Thumbnail) {
		thumbnail^ = {}
	}

	@(require_results)
	window_set_client_size :: proc(p: ^Platform, id: input.Window_Id, width, height: i32) -> Error {
		window := find_window(p, id)
		if window == nil {return .Invalid_Window}
		if width <= 0 || height <= 0 || width > 32767 || height > 32767 {return .Invalid_Argument}
		r := window.rect
		set_rect(p, window, {r.left, r.top, r.left + width, r.top + height})
		return .None
	}

	window_dpi :: proc(p: ^Platform, id: input.Window_Id) -> u32 {
		window := find_window(p, id)
		return window != nil ? display_at(p, window.rect).dpi : 0
	}

	primary_dpi :: proc(p: ^Platform) -> u32 {
		return len(p.displays) > 0 ? p.displays[0].dpi : 0
	}

	window_is_focused :: proc(p: ^Platform, id: input.Window_Id) -> bool {
		return id != 0 && p.focused == id
	}

	// Shows, raises and focuses the window. No other application exists to refuse it.
	@(require_results)
	window_focus :: proc(p: ^Platform, id: input.Window_Id) -> Error {
		window := find_window(p, id)
		if window == nil {return .Invalid_Window}
		window.visible = true
		raise(p, window)
		set_focus(p, id)
		return .None
	}

	@(require_results)
	window_show_raised :: proc(p: ^Platform, id: input.Window_Id) -> Error {
		window := find_window(p, id)
		if window == nil {return .Invalid_Window}
		window.visible = true
		raise(p, window)
		return .None
	}

	window_maximize :: proc(p: ^Platform, id: input.Window_Id) {
		window := find_window(p, id)
		if window == nil || window.maximized {return}
		window.restored, window.maximized, window.visible = window.rect, true, true
		set_rect(p, window, display_at(p, window.rect).rect)
	}

	window_maximized :: proc(p: ^Platform, id: input.Window_Id) -> bool {
		window := find_window(p, id)
		return window != nil && window.maximized
	}

	@(require_results)
	window_placement :: proc(p: ^Platform, id: input.Window_Id) -> (Window_Placement, Error) {
		window := find_window(p, id)
		if window == nil {return {}, .Invalid_Window}
		r := window.maximized ? window.restored : window.rect
		if full, is_full := window.screen.?; is_full {r = full}
		return {r.left, r.top, r.right, r.bottom, window.maximized}, .None
	}

	// Moves a hidden window to its restored rectangle and leaves it hidden.
	@(require_results)
	window_set_placement :: proc(p: ^Platform, id: input.Window_Id, target: Window_Placement) -> Error {
		window := find_window(p, id)
		if window == nil {return .Invalid_Window}
		if target.right <= target.left || target.bottom <= target.top {return .Invalid_Argument}
		window.visible = false
		set_rect(p, window, {target.left, target.top, target.right, target.bottom})
		return .None
	}

	@(require_results)
	window_show_inactive :: proc(p: ^Platform, id: input.Window_Id) -> Error {
		window := find_window(p, id)
		if window == nil {return .Invalid_Window}
		window.visible = true
		return .None
	}

	@(require_results)
	window_set_title :: proc(p: ^Platform, id: input.Window_Id, title: string) -> Error {
		window := find_window(p, id)
		if window == nil {return .Invalid_Window}
		for c in title {
			if c == 0 {return .Invalid_Argument}
		}
		copied, err := strings.clone(title, p.allocator)
		if err != nil {return .Out_Of_Memory}
		delete(window.title, p.allocator)
		window.title = copied
		return .None
	}

	@(require_results)
	window_set_frame_color :: proc(p: ^Platform, id: input.Window_Id, rgb: [3]u8, foreground: [3]u8) -> Error {
		window := find_window(p, id)
		if window == nil {return .Invalid_Window}
		window.frame_color, window.frame_text = rgb, foreground
		return .None
	}

	@(require_results)
	window_set_cursor :: proc(p: ^Platform, id: input.Window_Id, shape: Cursor_Shape) -> Error {
		window := find_window(p, id)
		if window == nil {return .Invalid_Window}
		window.cursor = shape
		return .None
	}

	@(require_results)
	window_flash :: proc(p: ^Platform, id: input.Window_Id) -> Error {
		if find_window(p, id) == nil {return .Invalid_Window}
		p.record.flashes += 1
		return .None
	}

	// Kept for parity; headless windows have no modal size loop to run the app from.
	set_modal_loop_callback :: proc(p: ^Platform, callback: proc(user: rawptr), user: rawptr) {
		p.modal_callback, p.modal_user = callback, user
	}

	// Covers the window's display, and restores its previous rectangle.
	window_set_screen :: proc(p: ^Platform, id: input.Window_Id, on: bool) -> Error {
		window := find_window(p, id)
		if window == nil {return .Invalid_Window}
		previous, is_full := window.screen.?
		if on == is_full {return .None}
		if on {
			window.screen = window.rect
			raise(p, window)
			set_rect(p, window, display_at(p, window.rect).rect)
		} else {
			window.screen = nil
			set_rect(p, window, previous)
		}
		return .None
	}

	// What a click on a caption button does: minimizing hides, maximizing toggles, closing asks.
	window_caption_action :: proc(p: ^Platform, id: input.Window_Id, button: Caption_Button) {
		window := find_window(p, id)
		if window == nil {return}
		switch button {
		case .Minimize:
			window.visible = false
			if p.focused == id {set_focus(p, 0)}
			enqueue(p, Resize_Event{id, 0, 0})
		case .Maximize:
			if window.maximized {
				window.maximized = false
				set_rect(p, window, window.restored)
			} else {
				window_maximize(p, id)
			}
		case .Close:
			enqueue(p, Close_Request_Event{id})
		}
	}

	// The US English layout, the same on every machine. Loading it does not change the user's input
	// language: it is not activated.
	@(private, require_results)
	keyboard_layout :: proc() -> (HKL, bool) {
		@(static) layout: HKL
		if layout == nil {
			id: [9]u16
			utf16.encode_string(id[:8], "00000409")
			layout = LoadKeyboardLayoutW(cstring16(raw_data(id[:])), KLF_NOTELLSHELL)
			if layout == nil {log.errorf("LoadKeyboardLayoutW failed: %v", w.GetLastError())}
		}
		return layout, layout != nil
	}
}
