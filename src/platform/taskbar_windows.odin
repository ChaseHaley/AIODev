package platform

import "core:log"
import w "core:sys/windows"

@(private)
taskbar_list :: proc(p: ^Platform) -> ^w.ITaskbarList3 {
	if p.taskbar != nil || p.taskbar_failed {return p.taskbar}
	p.taskbar_failed = true
	result := w.CoInitializeEx(nil, .APARTMENTTHREADED)
	// S_FALSE means COM was already initialized on this thread, and still needs a matching uninit.
	if result >= 0 {
		p.com_initialized = true
	} else if u32(result) != 0x80010106 {
		log.errorf("CoInitializeEx failed: HRESULT 0x%x", u32(result))
		return nil
	}
	list: rawptr
	result = w.CoCreateInstance(
		w.CLSID_TaskbarList,
		nil,
		w.CLSCTX_INPROC_SERVER,
		w.IID_ITaskbarList3,
		&list,
	)
	if result < 0 || list == nil {
		log.errorf("creating the taskbar list failed: HRESULT 0x%x", u32(result))
		return nil
	}
	taskbar := (^w.ITaskbarList3)(list)
	if result = taskbar->HrInit(); result < 0 {
		log.errorf("ITaskbarList3::HrInit failed: HRESULT 0x%x", u32(result))
		taskbar->Release()
		return nil
	}
	p.taskbar, p.taskbar_failed = taskbar, false
	return taskbar
}

@(private)
taskbar_destroy :: proc(p: ^Platform) {
	if p.taskbar != nil {
		p.taskbar->Release()
		p.taskbar = nil
	}
	if p.com_initialized {
		w.CoUninitialize()
		p.com_initialized = false
	}
}

// Shows progress on the window's taskbar button. `percent` is ignored for None and Indeterminate.
window_set_progress :: proc(p: ^Platform, id: Window_Id, state: Progress_State, percent: int) -> Error {
	window := find_window(p, id)
	if window == nil {return .Invalid_Window}
	taskbar := taskbar_list(p)
	if taskbar == nil {return .Os}
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
