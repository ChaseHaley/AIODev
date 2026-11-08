package ui_test

import "core:testing"
import "core:time"
import "aio:ui"

@(private)
TEST_FRAME_PERIOD :: 16 * time.Millisecond

// The frame shown at `display` on a display refreshing every TEST_FRAME_PERIOD.
@(private)
test_frame :: proc(display: time.Tick) -> ui.Frame_Time {
	return {display = display, period = TEST_FRAME_PERIOD}
}

@(test)
finite_motion_retargets_and_stops_exactly :: proc(t: ^testing.T) {
	for easing in ui.Easing {
		m: ui.Motion
		ui.motion_target(&m, 1, 100 * time.Millisecond, easing, true)
		testing.expect(t, ui.motion_active(m))
		ui.motion_update(&m, test_frame(time.tick_now()))
		start := m.started
		ui.motion_update(&m, test_frame(time.tick_add(start, 50 * time.Millisecond)))
		testing.expect(t, m.value > 0 && m.value < 1)
		ui.motion_target(&m, 0, 100 * time.Millisecond, easing, true)
		ui.motion_update(&m, test_frame(time.tick_add(start, 66 * time.Millisecond)))
		testing.expect(t, m.value > 0 && m.value < 1)
		ui.motion_update(&m, test_frame(time.tick_add(m.started, 100 * time.Millisecond)))
		testing.expect_value(t, m.value, f32(0))
		testing.expect(t, !ui.motion_active(m))
		testing.expect(t, !ui.motion_update(&m, test_frame(time.tick_add(start, time.Second))))
	}
	m: ui.Motion
	ui.motion_target(&m, 1, 100 * time.Millisecond, .Linear, false)
	testing.expect_value(t, m.value, f32(1))
	testing.expect(t, !ui.motion_active(m))
}

@(test)
motion_starts_one_refresh_before_its_first_frame_and_lands_on_its_last :: proc(t: ^testing.T) {
	duration :: 100 * time.Millisecond
	first := test_frame(time.tick_now())
	m: ui.Motion
	ui.motion_target(&m, 1, duration, .Decelerate, true)
	testing.expect_value(t, m.started, time.Tick{})
	testing.expect(t, ui.motion_update(&m, first))
	testing.expect_value(t, m.started, time.tick_add(first.display, -first.period))
	testing.expect(t, m.value > 0 && m.value < 1, "the first frame already moves one step")
	before_last := test_frame(time.tick_add(first.display, duration - 2 * first.period))
	testing.expect(t, ui.motion_update(&m, before_last))
	testing.expect(t, m.value < 1)
	last := test_frame(time.tick_add(first.display, duration - first.period))
	testing.expect(t, ui.motion_update(&m, last))
	testing.expect_value(t, m.value, f32(1))
	testing.expect(t, !ui.motion_active(m))
}

@(test)
motion_waits_out_a_resuming_frame_then_moves_one_step :: proc(t: ^testing.T) {
	duration :: 160 * time.Millisecond
	m: ui.Motion
	ui.motion_target(&m, 1, duration, .Linear, true)
	resuming := ui.Frame_Time{display = time.tick_now(), period = TEST_FRAME_PERIOD, resuming = true}
	testing.expect(t, !ui.motion_update(&m, resuming), "a resuming frame shows the motion where it is")
	testing.expect_value(t, m.value, f32(0))
	testing.expect_value(t, m.started, time.Tick{})
	next := test_frame(time.tick_add(resuming.display, TEST_FRAME_PERIOD))
	testing.expect(t, ui.motion_update(&m, next))
	testing.expect_value(t, m.value, f32(TEST_FRAME_PERIOD) / f32(duration))
	// Once started, a resuming frame after a missed vblank catches up to its own instant.
	late := ui.Frame_Time{display = time.tick_add(next.display, 3 * TEST_FRAME_PERIOD), period = TEST_FRAME_PERIOD,
		resuming = true}
	testing.expect(t, ui.motion_update(&m, late))
	testing.expect_value(t, m.value, f32(4 * TEST_FRAME_PERIOD) / f32(duration))
}
