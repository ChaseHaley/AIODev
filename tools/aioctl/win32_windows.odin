package aioctl

import w "core:sys/windows"

foreign import kernel32 "system:kernel32.lib"

@(private)
PROC_THREAD_ATTRIBUTE_HANDLE_LIST :: 0x20002

@(private)
STARTUPINFOEXW :: struct {
	StartupInfo: w.STARTUPINFOW,
	lpAttributeList: rawptr,
}

@(private, default_calling_convention = "system")
foreign kernel32 {
	QueryFullProcessImageNameW :: proc(
		hProcess: w.HANDLE, dwFlags: w.DWORD, lpExeName: w.LPWSTR, lpdwSize: ^w.DWORD,
	) -> w.BOOL ---
	InitializeProcThreadAttributeList :: proc(
		lpAttributeList: rawptr, dwAttributeCount, dwFlags: w.DWORD, lpSize: ^w.SIZE_T,
	) -> w.BOOL ---
	UpdateProcThreadAttribute :: proc(
		lpAttributeList: rawptr, dwFlags: w.DWORD, Attribute: w.DWORD_PTR,
		lpValue: rawptr, cbSize: w.SIZE_T, lpPreviousValue: rawptr, lpReturnSize: ^w.SIZE_T,
	) -> w.BOOL ---
	DeleteProcThreadAttributeList :: proc(lpAttributeList: rawptr) ---
}

