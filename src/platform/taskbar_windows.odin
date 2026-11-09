package platform

@(require) import "aio:com"
@(require) import "aio:input"
@(require) import "core:log"
@(require) import w "core:sys/windows"

// The Win32 backend; a headless build compiles another (see AIO_HEADLESS in platform.odin).
when !AIO_HEADLESS {
	@(private)
	taskbar_list :: proc(p: ^Platform) -> (^w.ITaskbarList3, Error) {
		switch service in p.taskbar {
		case ^w.ITaskbarList3:
			return service, .None
		case Service_Failed:
			return nil, .Unavailable
		case nil:
		}
		p.taskbar = Service_Failed{}
		entered, usable := com.apartment()
		// S_FALSE means COM was already initialized on this thread, and still needs a matching uninit.
		p.com_initialized = entered
		if !usable {return nil, .Os}
		list: rawptr
		result := w.CoCreateInstance(
			w.CLSID_TaskbarList,
			nil,
			w.CLSCTX_INPROC_SERVER,
			w.IID_ITaskbarList3,
			&list,
		)
		if result < 0 || list == nil {
			log.errorf("creating the taskbar list failed: HRESULT 0x%x", u32(result))
			return nil, .Os
		}
		taskbar := (^w.ITaskbarList3)(list)
		if result = taskbar->HrInit(); result < 0 {
			log.errorf("ITaskbarList3::HrInit failed: HRESULT 0x%x", u32(result))
			taskbar->Release()
			return nil, .Os
		}
		p.taskbar = taskbar
		return taskbar, .None
	}

	@(private)
	taskbar_destroy :: proc(p: ^Platform) {
		if taskbar, ready := p.taskbar.(^w.ITaskbarList3); ready {taskbar->Release()}
		p.taskbar = nil
		if p.com_initialized {
			w.CoUninitialize()
			p.com_initialized = false
		}
	}

	// Shows progress on the window's taskbar button. `percent` is ignored for None and Indeterminate.
	window_set_progress :: proc(
		p: ^Platform,
		id: input.Window_Id,
		state: Progress_State,
		percent: int,
	) -> Error {
		window := find_window(p, id)
		if window == nil {return .Invalid_Window}
		taskbar, err := taskbar_list(p)
		if err != .None {return err}
		flags := [Progress_State]w.TBPFLAG {
			.None          = .NOPROGRESS,
			.Indeterminate = .INDETERMINATE,
			.Normal        = .NORMAL,
			.Paused        = .PAUSED,
			.Error         = .ERROR,
		}
		if result := taskbar->SetProgressState(window.hwnd, flags[state]); result < 0 {
			log.errorf("ITaskbarList3::SetProgressState failed: HRESULT 0x%x", u32(result))
			return .Os
		}
		if state == .None || state == .Indeterminate {return .None}
		value := w.ULONGLONG(clamp(percent, 0, 100))
		if result := taskbar->SetProgressValue(window.hwnd, value, 100); result < 0 {
			log.errorf("ITaskbarList3::SetProgressValue failed: HRESULT 0x%x", u32(result))
			return .Os
		}
		return .None
	}
}
