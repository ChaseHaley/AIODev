package app_test

import "core:fmt"
import "core:time"

TEST_COSTS :: #config(AIO_TEST_COSTS, false)

@(private)
fixture_cost :: proc(name, phase: string, start: time.Tick, windows, sessions: int) {
	when TEST_COSTS {
		ms := f64(time.tick_since(start)) / f64(time.Millisecond)
		fmt.printf("[AIO-FIXTURE] %s %s %.3f %d %d\n", name, phase, ms, windows, sessions)
	}
}
