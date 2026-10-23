package main

import "aio:control"
import "core:strings"

_ :: control
_ :: strings

// PTY evidence: start or stop capturing the focused session's raw output for vtreplay.

when AIO_CONTROL {
	@(require_results)
	vt_record :: proc(
		app: ^App,
		out: ^strings.Builder,
		request: control.Vt,
	) -> control.Error {
		return .Invalid_Argument
	}
}
