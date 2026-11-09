#+private
package platform

@(require) import w "core:sys/windows"

@(require) foreign import user32 "system:user32.lib"
@(require) foreign import kernel32 "system:kernel32.lib"
@(require) foreign import dwmapi "system:dwmapi.lib"

// The Win32 backend; a headless build compiles another (see AIO_HEADLESS in platform.odin).
when !AIO_HEADLESS {
	MWMO_INPUTAVAILABLE :: 0x0004
	FLASHW_ALL :: 0x00000003
	NIIF_INFO :: 0x00000001
	NIIF_NOSOUND :: 0x00000010
	MB_ICONINFORMATION :: 0x00000040
	NOTIFYICON_VERSION_4 :: 4
	NINF_KEY :: 0x1
	NIN_KEYSELECT :: w.NIN_SELECT | NINF_KEY
	NIN_BALLOONUSERCLICK :: w.WM_USER + 5
	TO_UNICODE_NO_STATE_CHANGE :: 1 << 2
	SIZING_TIMER_ID :: 1
	SHELL_EXECUTE_ERROR_MAX :: 32

	FLASHWINFO :: struct {
		cbSize:    w.UINT,
		hwnd:      w.HWND,
		dwFlags:   w.DWORD,
		uCount:    w.UINT,
		dwTimeout: w.DWORD,
	}

	HKL :: distinct rawptr

	DWM_TNP_RECTDESTINATION :: 0x01
	DWM_TNP_RECTSOURCE :: 0x02
	DWM_TNP_VISIBLE :: 0x08
	DWM_TNP_SOURCECLIENTAREAONLY :: 0x10
	DWMWCP_ROUND :: 2
	SS_BLACKRECT :: 0x04

	// dwmapi.h declares this structure with one-byte packing.
	DWM_THUMBNAIL_PROPERTIES :: struct #packed {
		dwFlags:               w.DWORD,
		rcDestination:         w.RECT,
		rcSource:              w.RECT,
		opacity:               w.BYTE,
		fVisible:              w.BOOL,
		fSourceClientAreaOnly: w.BOOL,
	}

	@(default_calling_convention = "system")
	foreign dwmapi {
		DwmDefWindowProc :: proc(hwnd: w.HWND, message: w.UINT, wp: w.WPARAM, lp: w.LPARAM, result: ^w.LRESULT) -> w.BOOL ---
		DwmRegisterThumbnail :: proc(destination, source: w.HWND, thumbnail: ^w.HANDLE) -> w.HRESULT ---
		DwmUnregisterThumbnail :: proc(thumbnail: w.HANDLE) -> w.HRESULT ---
		DwmUpdateThumbnailProperties :: proc(thumbnail: w.HANDLE, properties: ^DWM_THUMBNAIL_PROPERTIES) -> w.HRESULT ---
	}

	@(default_calling_convention = "system")
	foreign user32 {
		MsgWaitForMultipleObjectsEx :: proc(nCount: w.DWORD, pHandles: [^]w.HANDLE, dwMilliseconds, dwWakeMask, dwFlags: w.DWORD) -> w.DWORD ---
		GetKeyboardLayout :: proc(idThread: w.DWORD) -> HKL ---
		ToUnicodeEx :: proc(wVirtKey, wScanCode: w.UINT, lpKeyState: ^w.BYTE, pwszBuff: w.LPWSTR, cchBuff: w.INT, wFlags: w.UINT, dwhkl: HKL) -> w.INT ---
		FlashWindowEx :: proc(pfwi: ^FLASHWINFO) -> w.BOOL ---
		AllowSetForegroundWindow :: proc(dwProcessId: w.DWORD) -> w.BOOL ---
	}

	@(default_calling_convention = "system")
	foreign kernel32 {
		CreateMutexW :: proc(lpMutexAttributes: ^w.SECURITY_ATTRIBUTES, bInitialOwner: w.BOOL, lpName: w.LPCWSTR) -> w.HANDLE ---
		OpenMutexW :: proc(dwDesiredAccess: w.DWORD, bInheritHandle: w.BOOL, lpName: w.LPCWSTR) -> w.HANDLE ---
	}
}
