package dwrite

import windows "core:sys/windows"

@(private, require_results)
failure :: proc "contextless" (code: u32) -> windows.HRESULT {
	return windows.HRESULT(cast(i32)code)
}
