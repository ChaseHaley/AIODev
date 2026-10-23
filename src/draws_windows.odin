package main

import "aio:control"
import "core:strings"

_ :: control
_ :: strings

// Draw-list evidence: report the selected window's last built frame in draw order.

when AIO_CONTROL {
	@(require_results)
	draws_read :: proc(
		app: ^App,
		out: ^strings.Builder,
		request: control.Draws,
	) -> control.Error {
		return .Invalid_Argument
	}
}
