#+private
package platform

import w "core:sys/windows"

foreign import user32 "system:user32.lib"
foreign import kernel32 "system:kernel32.lib"
foreign import dwmapi "system:dwmapi.lib"

MWMO_INPUTAVAILABLE :: 0x0004
FLASHW_ALL :: 0x00000003
NIIF_INFO :: 0x00000001
NOTIFYICON_VERSION_4 :: 4
NINF_KEY :: 0x1
NIN_KEYSELECT :: w.NIN_SELECT | NINF_KEY
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

@(default_calling_convention = "system")
foreign dwmapi {
	DwmDefWindowProc :: proc(hwnd: w.HWND, message: w.UINT, wp: w.WPARAM, lp: w.LPARAM, result: ^w.LRESULT) -> w.BOOL ---
}

@(default_calling_convention = "system")
foreign user32 {
	MsgWaitForMultipleObjectsEx :: proc(nCount: w.DWORD, pHandles: [^]w.HANDLE, dwMilliseconds, dwWakeMask, dwFlags: w.DWORD) -> w.DWORD ---
	GetKeyboardLayout :: proc(idThread: w.DWORD) -> HKL ---
	ToUnicodeEx :: proc(wVirtKey, wScanCode: w.UINT, lpKeyState: ^w.BYTE, pwszBuff: w.LPWSTR, cchBuff: w.INT, wFlags: w.UINT, dwhkl: HKL) -> w.INT ---
	FlashWindowEx :: proc(pfwi: ^FLASHWINFO) -> w.BOOL ---
}

@(default_calling_convention = "system")
foreign kernel32 {
	CreateMutexW :: proc(lpMutexAttributes: ^w.SECURITY_ATTRIBUTES, bInitialOwner: w.BOOL, lpName: w.LPCWSTR) -> w.HANDLE ---
	OpenMutexW :: proc(dwDesiredAccess: w.DWORD, bInheritHandle: w.BOOL, lpName: w.LPCWSTR) -> w.HANDLE ---
}
