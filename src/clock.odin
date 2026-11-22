package main

import "aio:term"
import "cosmos:host"
import "core:time"

// host.clock_wall for sessions, which stamp program status reports on their reader threads.
clock_wall_source :: proc(c: ^host.Clock) -> term.Wall_Clock {
	return {proc(user: rawptr) -> time.Time {return host.clock_wall((^host.Clock)(user))}, c}
}
