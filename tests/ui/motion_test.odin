package ui_test

import "core:testing"
import "core:time"
import "aio:ui"

@(test)
finite_motion_retargets_and_stops_exactly :: proc(t: ^testing.T) {
	start := time.tick_now()
	for easing in ui.Easing {
		m: ui.Motion
		ui.motion_target(&m, 1, 100*time.Millisecond, easing, true, start)
		testing.expect(t, ui.motion_active(m))
		ui.motion_update(&m, time.tick_add(start, 50*time.Millisecond))
		testing.expect(t, m.value > 0 && m.value < 1)
		ui.motion_target(&m, 0, 100*time.Millisecond, easing, true, time.tick_add(start, 50*time.Millisecond))
		ui.motion_update(&m, time.tick_add(start, 150*time.Millisecond))
		testing.expect_value(t, m.value, f32(0))
		testing.expect(t, !ui.motion_active(m))
		testing.expect(t, !ui.motion_update(&m, time.tick_add(start, time.Second)))
	}
	m: ui.Motion
	ui.motion_target(&m, 1, 100*time.Millisecond, .Linear, false, start)
	testing.expect_value(t, m.value, f32(1))
	testing.expect(t, !ui.motion_active(m))
}
