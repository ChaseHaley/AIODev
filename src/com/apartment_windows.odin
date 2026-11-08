package com

import "core:log"
import w "core:sys/windows"

// RPC_E_CHANGED_MODE: COM is already initialized on this thread in another apartment, which serves.
@(private)
COM_CHANGED_MODE :: 0x80010106

// Enters a single-threaded COM apartment on the calling thread. `entered` means the caller owes one
// CoUninitialize, including for S_FALSE. COM already initialized in another apartment kind serves, so it
// is `usable` with nothing owed; any other failure is logged.
@(require_results)
apartment :: proc() -> (entered, usable: bool) {
	result := w.CoInitializeEx(nil, .APARTMENTTHREADED)
	if result >= 0 {return true, true}
	if u32(result) == COM_CHANGED_MODE {return false, true}
	log.errorf("CoInitializeEx failed: HRESULT 0x%x", u32(result))
	return false, false
}
