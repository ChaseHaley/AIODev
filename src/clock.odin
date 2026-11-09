package main

import platform_api "aio:platform"
import "aio:term"
import "core:time"

// The app's one source of time. Everything the main thread times, animates or shows as an age reads
// it, so a build that drives time itself replaces these procs alone (WORK-349). Frame statistics,
// search work budgets, pipe timeouts and the synchronized-output hold keep the system clock: they
// measure real work or cross threads, and change no frame's content.
when platform_api.AIO_HEADLESS {
	// Follows the system clock until a test sets `stepped`; from then on the clock reads `now` and
	// `wall`, and time moves only when the test advances them.
	Clock :: struct {
		stepped: bool,
		now:     time.Tick,
		wall:    time.Time,
	}

	clock_now :: proc(c: ^Clock) -> time.Tick {
		return c.stepped ? c.now : time.tick_now()
	}

	// The time of day, for ages shown on screen.
	clock_wall :: proc(c: ^Clock) -> time.Time {
		return c.stepped ? c.wall : time.now()
	}
} else {
	Clock :: struct {}

	clock_now :: proc(c: ^Clock) -> time.Tick {
		return time.tick_now()
	}

	// The time of day, for ages shown on screen.
	clock_wall :: proc(c: ^Clock) -> time.Time {
		return time.now()
	}
}

// clock_wall for sessions, which stamp program status reports on their reader threads.
clock_wall_source :: proc(c: ^Clock) -> term.Wall_Clock {
	return {proc(user: rawptr) -> time.Time {return clock_wall((^Clock)(user))}, c}
}
