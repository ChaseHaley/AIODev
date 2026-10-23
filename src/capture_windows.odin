package main

import "aio:control"
import "core:strings"

_ :: control
_ :: strings

// Pixel evidence: render the last built frame offscreen, then write or compare its pixels.
// The renderer lives in capture_windows.odin so the control protocol stays free of graphics.

when AIO_CONTROL {
	@(require_results)
	capture_read :: proc(
		app: ^App,
		out: ^strings.Builder,
		request: control.Capture,
	) -> control.Error {
		return .Invalid_Argument
	}

	@(require_results)
	pixels_read :: proc(
		app: ^App,
		out: ^strings.Builder,
		request: control.Pixels,
	) -> control.Error {
		return .Invalid_Argument
	}

	@(require_results)
	pixels_diff :: proc(
		app: ^App,
		out: ^strings.Builder,
		request: control.Diff,
	) -> control.Error {
		return .Invalid_Argument
	}
}
