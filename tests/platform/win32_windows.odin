package platform_test

import w "core:sys/windows"

foreign import user32 "system:user32.lib"

@(private)
HKL :: distinct rawptr

@(private)
KLF_NOTELLSHELL :: 0x00000080

@(default_calling_convention="system")
foreign user32 {
	GetKeyboardLayout :: proc(idThread: w.DWORD) -> HKL ---
	GetKeyboardLayoutList :: proc(nBuff: w.INT, lpList: [^]HKL) -> w.INT ---
	LoadKeyboardLayoutW :: proc(pwszKLID: w.LPCWSTR, Flags: w.UINT) -> HKL ---
	ActivateKeyboardLayout :: proc(hkl: HKL, Flags: w.UINT) -> HKL ---
	UnloadKeyboardLayout :: proc(hkl: HKL) -> w.BOOL ---
}
