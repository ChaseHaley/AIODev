package main

import "aio:control"
import "core:strings"

_ :: control
_ :: strings

// Timing evidence: format the counters recorded in the aio:perf package.

when AIO_CONTROL {
	@(require_results)
	perf_read :: proc(
		app: ^App,
		out: ^strings.Builder,
		request: control.Perf,
	) -> control.Error {
		return .Invalid_Argument
	}
}
