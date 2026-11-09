package platform

@(require) import "core:log"
@(require) import w "core:sys/windows"

// The Win32 backend; a headless build compiles another (see AIO_HEADLESS in platform.odin).
when !AIO_HEADLESS {
	// The user's keyboard layout, which synthesize_key types with.
	@(private, require_results)
	keyboard_layout :: proc() -> (HKL, bool) {
		layout := GetKeyboardLayout(0)
		if layout == nil {log.errorf("GetKeyboardLayout failed: %v", w.GetLastError())}
		return layout, layout != nil
	}
}
