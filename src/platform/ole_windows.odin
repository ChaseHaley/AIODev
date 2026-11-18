package platform

@(require) import "aio:input"
@(require) import "core:log"
@(require) import w "core:sys/windows"
@(require) import "core:unicode/utf16"

@(require) foreign import ole_ole32 "system:ole32.lib"

// Files dragged in from Explorer: each window registers an OLE drop target, so the app hears the drag
// moving over the window (Files_Drag_Event) and then the drop (Files_Drop_Event). The calls arrive on the
// UI thread, inside the message dispatch of poll_events, and only add events to the queue: the main loop
// owns every decision. The target answers DROPEFFECT_COPY for files and nothing for any other data.
when !AIO_HEADLESS {
	DROPEFFECT_NONE :: 0
	DROPEFFECT_COPY :: 1
	TYMED_HGLOBAL :: 1
	DVASPECT_CONTENT :: 1

	// The longest path a drop carries: the app's local path checks admit nothing longer (localpath).
	@(private)
	DROP_PATH_MAX :: 4096

	// E_NOINTERFACE, E_POINTER and E_FAIL; the constants in core:sys/windows do not fit an HRESULT.
	@(private)
	E_NOINTERFACE_RESULT :: w.HRESULT(-2147467262)
	@(private)
	E_POINTER_RESULT :: w.HRESULT(-2147467261)
	@(private)
	E_FAIL_RESULT :: w.HRESULT(-2147467259)

	@(private)
	IID_IUnknown := w.GUID{0x00000000, 0x0000, 0x0000, {0xC0, 0, 0, 0, 0, 0, 0, 0x46}}
	@(private)
	IID_IDropTarget := w.GUID{0x00000122, 0x0000, 0x0000, {0xC0, 0, 0, 0, 0, 0, 0, 0x46}}

	// A point in screen coordinates, as COM passes it by value.
	Point_L :: struct {
		x, y: i32,
	}

	Format_Etc :: struct {
		format:  u16,
		device:  rawptr,
		aspect:  w.DWORD,
		index:   i32,
		storage: w.DWORD,
	}

	Storage_Medium :: struct {
		storage: w.DWORD,
		global:  w.HGLOBAL,
		release: rawptr,
	}

	// IDataObject, of which a drop reads only the files. The entries a drop never calls are left as rawptr.
	Data_Object :: struct {
		vtable: ^Data_Object_VTable,
	}

	Data_Object_VTable :: struct {
		QueryInterface:        proc "system" (this: ^Data_Object, riid: w.REFIID, object: ^rawptr) -> w.HRESULT,
		AddRef:                proc "system" (this: ^Data_Object) -> w.ULONG,
		Release:               proc "system" (this: ^Data_Object) -> w.ULONG,
		GetData:               proc "system" (
			this: ^Data_Object,
			format: ^Format_Etc,
			medium: ^Storage_Medium,
		) -> w.HRESULT,
		GetDataHere:           rawptr,
		QueryGetData:          proc "system" (this: ^Data_Object, format: ^Format_Etc) -> w.HRESULT,
		GetCanonicalFormatEtc: rawptr,
		SetData:               rawptr,
		EnumFormatEtc:         rawptr,
		DAdvise:               rawptr,
		DUnadvise:             rawptr,
		EnumDAdvise:           rawptr,
	}

	// IDropTarget, embedded in the window it serves and alive until RevokeDragDrop, so its reference count
	// never frees it. `files` is whether the drag now over the window carries files.
	Drop_Target :: struct {
		vtable:     ^Drop_Target_VTable,
		references: w.ULONG,
		window:     ^Window,
		registered: bool,
		files:      bool,
	}

	Drop_Target_VTable :: struct {
		QueryInterface: proc "system" (this: ^Drop_Target, riid: w.REFIID, object: ^rawptr) -> w.HRESULT,
		AddRef:         proc "system" (this: ^Drop_Target) -> w.ULONG,
		Release:        proc "system" (this: ^Drop_Target) -> w.ULONG,
		DragEnter:      proc "system" (
			this: ^Drop_Target,
			data: ^Data_Object,
			keys: w.DWORD,
			point: Point_L,
			effect: ^w.DWORD,
		) -> w.HRESULT,
		DragOver:       proc "system" (
			this: ^Drop_Target,
			keys: w.DWORD,
			point: Point_L,
			effect: ^w.DWORD,
		) -> w.HRESULT,
		DragLeave:      proc "system" (this: ^Drop_Target) -> w.HRESULT,
		Drop:           proc "system" (
			this: ^Drop_Target,
			data: ^Data_Object,
			keys: w.DWORD,
			point: Point_L,
			effect: ^w.DWORD,
		) -> w.HRESULT,
	}

	@(private)
	DROP_TARGET_VTABLE := Drop_Target_VTable {
		QueryInterface = drop_target_query,
		AddRef         = drop_target_add_ref,
		Release        = drop_target_release,
		DragEnter      = drop_target_enter,
		DragOver       = drop_target_over,
		DragLeave      = drop_target_leave,
		Drop           = drop_target_drop,
	}

	@(default_calling_convention = "system")
	foreign ole_ole32 {
		OleInitialize :: proc(reserved: rawptr) -> w.HRESULT ---
		OleUninitialize :: proc() ---
		RegisterDragDrop :: proc(hwnd: w.HWND, target: ^Drop_Target) -> w.HRESULT ---
		RevokeDragDrop :: proc(hwnd: w.HWND) -> w.HRESULT ---
		ReleaseStgMedium :: proc(medium: ^Storage_Medium) ---
	}

	// The drop target the window registered, for tests to call as the OLE drag loop would.
	@(require_results)
	window_drop_target :: proc(p: ^Platform, id: input.Window_Id) -> ^Drop_Target {
		window := find_window(p, id)
		return window == nil || !window.drop_target.registered ? nil : &window.drop_target
	}

	// Registers the window's drop target. Failing leaves the window without drops, which the log records.
	@(private)
	drop_target_register :: proc(p: ^Platform, window: ^Window) {
		if !p.ole {return}
		window.drop_target = {
			vtable = &DROP_TARGET_VTABLE,
			window = window,
		}
		if hr := RegisterDragDrop(window.hwnd, &window.drop_target); hr < 0 {
			log.errorf("RegisterDragDrop failed: HRESULT 0x%x", u32(hr))
			return
		}
		window.drop_target.registered = true
	}

	// Must run before the window is destroyed: COM holds the target until it is revoked.
	@(private)
	drop_target_revoke :: proc(window: ^Window) {
		if !window.drop_target.registered {return}
		window.drop_target.registered = false
		if hr := RevokeDragDrop(window.hwnd); hr < 0 {log.errorf("RevokeDragDrop failed: HRESULT 0x%x", u32(hr))}
	}

	@(private)
	files_format :: proc() -> Format_Etc {
		return {format = w.CF_HDROP, aspect = DVASPECT_CONTENT, index = -1, storage = TYMED_HGLOBAL}
	}

	// Whether the drag carries files as a list of paths.
	@(private)
	data_has_files :: proc(data: ^Data_Object) -> bool {
		if data == nil {return false}
		format := files_format()
		return data.vtable.QueryGetData(data, &format) == 0
	}

	// A drag may copy: that is all a drop of files does here.
	@(private)
	drop_effect :: proc(this: ^Drop_Target, effect: ^w.DWORD) {
		if effect == nil {return}
		effect^ = this.files && effect^ & DROPEFFECT_COPY != 0 ? DROPEFFECT_COPY : DROPEFFECT_NONE
	}

	@(private)
	drop_target_query :: proc "system" (this: ^Drop_Target, riid: w.REFIID, object: ^rawptr) -> w.HRESULT {
		if object == nil {return E_POINTER_RESULT}
		if riid != nil && (riid^ == IID_IUnknown || riid^ == IID_IDropTarget) {
			object^ = this
			this.references += 1
			return 0
		}
		object^ = nil
		return E_NOINTERFACE_RESULT
	}

	@(private)
	drop_target_add_ref :: proc "system" (this: ^Drop_Target) -> w.ULONG {
		this.references += 1
		return this.references
	}

	@(private)
	drop_target_release :: proc "system" (this: ^Drop_Target) -> w.ULONG {
		if this.references > 0 {this.references -= 1}
		return this.references
	}

	// Tells the app where the drag is, in the window's client coordinates.
	@(private)
	drag_event :: proc(this: ^Drop_Target, phase: Files_Drag_Phase, point: Point_L) {
		window := this.window
		client := w.POINT{point.x, point.y}
		if !w.ScreenToClient(window.hwnd, &client) {
			log.errorf("ScreenToClient(drag) failed: %d", w.GetLastError())
			return
		}
		enqueue(window.owner, Files_Drag_Event{window.id, phase, client.x, client.y})
	}

	@(private)
	drop_target_enter :: proc "system" (
		this: ^Drop_Target,
		data: ^Data_Object,
		keys: w.DWORD,
		point: Point_L,
		effect: ^w.DWORD,
	) -> w.HRESULT {
		context = this.window.owner.callback_context
		this.files = data_has_files(data)
		drop_effect(this, effect)
		if this.files {drag_event(this, .Enter, point)}
		return 0
	}

	@(private)
	drop_target_over :: proc "system" (
		this: ^Drop_Target,
		keys: w.DWORD,
		point: Point_L,
		effect: ^w.DWORD,
	) -> w.HRESULT {
		context = this.window.owner.callback_context
		drop_effect(this, effect)
		if this.files {drag_event(this, .Over, point)}
		return 0
	}

	@(private)
	drop_target_leave :: proc "system" (this: ^Drop_Target) -> w.HRESULT {
		context = this.window.owner.callback_context
		if this.files {
			window := this.window
			enqueue(window.owner, Files_Drag_Event{window.id, .Leave, 0, 0})
		}
		this.files = false
		return 0
	}

	@(private)
	drop_target_drop :: proc "system" (
		this: ^Drop_Target,
		data: ^Data_Object,
		keys: w.DWORD,
		point: Point_L,
		effect: ^w.DWORD,
	) -> w.HRESULT {
		context = this.window.owner.callback_context
		window := this.window
		this.files = false
		if effect != nil {effect^ = DROPEFFECT_NONE}
		if !data_has_files(data) {return 0}
		client := w.POINT{point.x, point.y}
		if !w.ScreenToClient(window.hwnd, &client) {
			log.errorf("ScreenToClient(drop) failed: %d", w.GetLastError())
			return E_FAIL_RESULT
		}
		format := files_format()
		medium: Storage_Medium
		if hr := data.vtable.GetData(data, &format, &medium); hr < 0 {
			log.errorf("IDataObject::GetData(CF_HDROP) failed: HRESULT 0x%x", u32(hr))
			return hr
		}
		drop_files(window.owner, window, w.HDROP(medium.global), client)
		ReleaseStgMedium(&medium)
		drop_activate(window)
		if effect != nil {effect^ = DROPEFFECT_COPY}
		return 0
	}

	// Brings the window forward for a drop and gives it the keyboard, so the pane the files opened in can be
	// typed into. It runs inside Drop, while the user's gesture is the latest input. Windows still decides
	// (SetForegroundWindow's rules: the foreground lock, menus, the last input event): when it refuses,
	// the window stays where it was and Windows flashes its taskbar button, which the log notes.
	@(private)
	drop_activate :: proc(window: ^Window) {
		if w.IsIconic(window.hwnd) {w.ShowWindow(window.hwnd, w.SW_RESTORE)}
		if !w.SetForegroundWindow(window.hwnd) {
			log.warn("platform: Windows did not bring the window forward for a drop")
			return
		}
		w.SetFocus(window.hwnd)
	}

	// Queues the files of a drop as one Files_Drop_Event. The paths are written straight into the queue's
	// text storage, so a drop allocates nothing. A path too long to open, or that no longer fits the
	// storage, is skipped.
	@(private)
	drop_files :: proc(p: ^Platform, window: ^Window, drop: w.HDROP, point: w.POINT) {
		q := &p.queues[p.write_queue]
		start := q.text_used
		wide: [DROP_PATH_MAX]u16 = ---
		count := w.DragQueryFileW(drop, 0xFFFFFFFF, nil, 0)
		for i in 0 ..< count {
			length := int(w.DragQueryFileW(drop, i, nil, 0))
			if length == 0 || length >= len(wide) {
				log.warnf("platform: skipped a dropped path of %d UTF-16 units", length)
				continue
			}
			// Each UTF-16 unit becomes at most three bytes, and a separator may precede the path.
			if q.text_used + 3 * length + 1 > len(q.text) {
				log.warn("platform: the drop's paths no longer fit the event queue")
				break
			}
			if int(w.DragQueryFileW(drop, i, &wide[0], DROP_PATH_MAX)) != length {continue}
			if q.text_used > start {
				q.text[q.text_used] = '\n'
				q.text_used += 1
			}
			q.text_used += utf16.decode_to_utf8(q.text[q.text_used:], wide[:length])
		}
		if q.text_used == start {return}
		enqueue(p, Files_Drop_Event{window.id, point.x, point.y, string(q.text[start:q.text_used])})
	}
}
