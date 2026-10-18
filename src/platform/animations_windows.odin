package platform

import "core:log"
import win "core:sys/windows"

client_animations_enabled :: proc() -> bool {
	enabled: win.BOOL
	if !win.SystemParametersInfoW(win.SPI_GETCLIENTAREAANIMATION, 0, &enabled, 0) {
		log.errorf("SystemParametersInfoW client area animations failed: %v", win.GetLastError())
		return false
	}
	return enabled != false
}
