package render_test

import "core:testing"
import "core:time"
import "aio:render"

@(private = "file")
PERIOD :: 4 * time.Millisecond

@(private = "file")
at :: proc(vblank: time.Tick, refreshes: f64) -> time.Tick {
	return time.tick_add(vblank, time.Duration(refreshes * f64(PERIOD)))
}

@(test)
frame_clock_builds_each_frame_for_the_vblank_that_shows_it :: proc(t: ^testing.T) {
	v := time.tick_now()
	c := render.Frame_Clock {
		vblank = v,
		period = PERIOD,
	}
	// After a pause the frame takes the next vblank, and says its moment on screen is uncertain.
	first := render.frame_clock_predict(c, at(v, 0.3))
	testing.expect_value(t, first, render.Frame_Time{at(v, 1), PERIOD, true, at(v, 1), false})
	// Woken early, before the last frame reached its vblank: the next one after it, back to back.
	c.presented = first.display
	testing.expect_value(t, render.frame_clock_predict(c, at(v, 0.6)), render.Frame_Time{at(v, 2), PERIOD, false, at(v, 2), false})
	// Woken just after that vblank: the same next frame.
	testing.expect_value(t, render.frame_clock_predict(c, at(v, 1.1)), render.Frame_Time{at(v, 2), PERIOD, false, at(v, 2), false})
	// A frame built after a vblank it missed catches up to the grid rather than falling behind.
	testing.expect_value(t, render.frame_clock_predict(c, at(v, 2.2)), render.Frame_Time{at(v, 3), PERIOD, true, at(v, 3), false})
}

@(test)
frame_clock_without_a_refresh_shows_frames_now :: proc(t: ^testing.T) {
	now := time.tick_now()
	frame := render.frame_clock_predict({}, now)
	testing.expect_value(t, frame, render.Frame_Time{display = now, period = render.FRAME_PERIOD_DEFAULT})
}

// A window on a slower display than the compositor's is built for that display's vblanks: each frame for
// the first of them after the compositor tick that takes it, so frames sharing one show the same instant.
@(test)
frame_clock_on_a_slower_display_builds_for_its_vblanks :: proc(t: ^testing.T) {
	v := time.tick_now()
	slow :: 7 * time.Millisecond
	c := render.Frame_Clock {
		vblank = v,
		period = PERIOD,
		display = {vblank = time.tick_add(v, 1500 * time.Microsecond), period = slow},
	}
	first := render.frame_clock_predict(c, at(v, 0.3))
	testing.expect_value(t, first, render.Frame_Time{time.tick_add(v, 8500 * time.Microsecond), slow, true, at(v, 1), false})
	c.presented, c.presented_display = first.composed, first.display
	// The next compositor tick lands before the same display vblank.
	second := render.frame_clock_predict(c, at(v, 1.1))
	testing.expect_value(t, second, render.Frame_Time{first.display, slow, false, at(v, 2), false})
	c.presented, c.presented_display = second.composed, second.display
	// The one after takes the display's next vblank, back to back.
	third := render.frame_clock_predict(c, at(v, 2.1))
	testing.expect_value(t, third, render.Frame_Time{time.tick_add(v, 15500 * time.Microsecond), slow, false, at(v, 3), false})
}

// A window too slow to draw back to back still starts its motions: after four resuming frames in a row,
// the next one moves even when late.
@(test)
frame_clock_resumes_at_most_four_frames_in_a_row :: proc(t: ^testing.T) {
	v := time.tick_now()
	c := render.Frame_Clock {
		vblank = v,
		period = PERIOD,
	}
	first := render.frame_clock_predict(c, at(v, 0.3))
	testing.expect(t, first.resuming)
	c.presented, c.presented_display, c.resumed = first.composed, first.display, 4
	late := render.frame_clock_predict(c, at(v, 2.2))
	testing.expect_value(t, late.display, at(v, 3))
	testing.expect(t, !late.resuming, "the frame after a resuming one starts motions even when late")
}

// The grid follows a compositor whose refresh changed at once, then measures the new period exactly.
@(test)
frame_clock_follows_a_change_of_refresh :: proc(t: ^testing.T) {
	v := time.tick_now()
	c: render.Frame_Clock
	count := u32(1000)
	for i in 0 ..< 70 {
		render.frame_clock_vblank(&c, time.tick_add(v, time.Duration(i) * PERIOD), count)
		count += 1
	}
	testing.expect_value(t, c.period, PERIOD)
	slower :: 16 * time.Millisecond
	last := time.tick_add(v, 69 * PERIOD)
	for i in 1 ..= 3 {
		render.frame_clock_vblank(&c, time.tick_add(last, time.Duration(i) * slower), count)
		count += 1
	}
	testing.expect_value(t, c.period, slower)
	next := render.frame_clock_predict(c, time.tick_add(last, 3 * slower + time.Millisecond))
	testing.expect_value(t, next.display, time.tick_add(last, 4 * slower))
}

// A frame woken late in its refresh is uncertain to make its vblank, so no motion starts on it; one that
// cannot make it is built for the vblank after, which it then shows on time.
@(test)
frame_clock_defers_starts_and_skips_vblanks_it_cannot_make :: proc(t: ^testing.T) {
	v := time.tick_now()
	c := render.Frame_Clock {
		vblank = v,
		period = PERIOD,
	}
	c.presented = at(v, 1)
	tight := render.frame_clock_predict(c, at(v, 1.7))
	testing.expect_value(t, tight, render.Frame_Time{at(v, 2), PERIOD, true, at(v, 2), false})
	late := render.frame_clock_predict(c, at(v, 1.95))
	testing.expect_value(t, late, render.Frame_Time{at(v, 3), PERIOD, true, at(v, 3), true})
	// The late frame may still have made the vblank it was due, so the next frame woken after that
	// vblank takes the following one rather than one further on.
	c.presented, c.presented_late = late.composed, true
	next := render.frame_clock_predict(c, at(v, 2.1))
	testing.expect_value(t, next, render.Frame_Time{at(v, 3), PERIOD, false, at(v, 3), false})
}
