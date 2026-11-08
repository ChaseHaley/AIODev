package render

import "core:time"

// The moment a frame will be on screen, on the display's vblank grid, and how long the display holds
// each frame. Every motion samples at `display`, so consecutive frames step by exactly one refresh and
// the screen never shows the same instant twice or skips one.
//
// `resuming` marks a frame that follows a pause in presenting. Such a frame is built at any point of
// the refresh, so whether the compositor takes it for the next vblank or the one after is unknown;
// frames presented back to back are built just after a vblank and always land the same distance
// after it. Motions therefore start on the next frame instead: a resuming frame shows them where they
// are, and every frame that moves them lands exactly one refresh after the one before.
Frame_Time :: struct {
	display:  time.Tick,
	period:   time.Duration,
	resuming: bool,
	// When the compositor takes the frame, on its own vblank grid: `display` itself, except on a display
	// that refreshes at another rate than the compositor (see Display_Clock). Zero without a display clock.
	composed: time.Tick,
	// Started too close to the vblank it was due to make it, so built for the one after.
	late:     bool,
}

// The refresh assumed where no display reports one: offscreen surfaces, tests and the moments before
// a new swap chain has shown anything.
FRAME_PERIOD_DEFAULT :: time.Second / 60

// A frame shown now at the assumed refresh, for drawing that has no display clock.
frame_time_now :: proc() -> Frame_Time {
	return {display = time.tick_now(), period = FRAME_PERIOD_DEFAULT}
}
