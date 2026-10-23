package ui_test

import "core:testing"
import "core:time"
import "aio:ui"

// A stand-in floating surface: the frame gate reads presence_visible and the payload is
// released only when advance reports the closing motion settled.
@(private)
Presence_Probe :: struct {
	presence: ui.Presence,
	released: int,
}

@(private)
presence_probe_frame :: proc(p: ^Presence_Probe, enabled: bool, now: time.Tick) {
	_, settled := ui.presence_advance(&p.presence, enabled, now)
	if settled {p.released += 1}
}

@(private)
PRESENCE_PROBE_SPEC :: ui.Presence_Spec {
	open  = 100 * time.Millisecond,
	close = 90 * time.Millisecond,
}

@(test)
presence_probe_leaves_the_frame_after_its_close_and_releases_once :: proc(t: ^testing.T) {
	start := time.tick_now()
	p: Presence_Probe
	ui.presence_open(&p.presence, PRESENCE_PROBE_SPEC)
	presence_probe_frame(&p, true, start)
	testing.expect(t, ui.presence_visible(p.presence) && ui.presence_active(p.presence))
	presence_probe_frame(&p, true, time.tick_add(start, 200*time.Millisecond))
	testing.expect(t, ui.presence_visible(p.presence) && !ui.presence_active(p.presence))
	testing.expect_value(t, p.released, 0)

	ui.presence_close(&p.presence)
	presence_probe_frame(&p, true, time.tick_add(start, 200*time.Millisecond))
	testing.expect(t, ui.presence_visible(p.presence) && ui.presence_active(p.presence))
	presence_probe_frame(&p, true, time.tick_add(start, 240*time.Millisecond))
	testing.expect(t, ui.presence_visible(p.presence) && ui.presence_active(p.presence))
	testing.expect_value(t, p.released, 0)

	presence_probe_frame(&p, true, time.tick_add(start, 400*time.Millisecond))
	testing.expect(t, !ui.presence_visible(p.presence) && !ui.presence_active(p.presence))
	testing.expect_value(t, p.released, 1)
	presence_probe_frame(&p, true, time.tick_add(start, 500*time.Millisecond))
	testing.expect_value(t, p.released, 1)
}

@(test)
presence_without_animations_closes_and_releases_in_one_step :: proc(t: ^testing.T) {
	start := time.tick_now()
	p: Presence_Probe
	ui.presence_open(&p.presence, PRESENCE_PROBE_SPEC)
	presence_probe_frame(&p, false, start)
	testing.expect(t, ui.presence_visible(p.presence) && !ui.presence_active(p.presence))
	testing.expect_value(t, p.presence.motion.value, f32(1))

	ui.presence_close(&p.presence)
	testing.expect(t, ui.presence_visible(p.presence))
	presence_probe_frame(&p, false, start)
	testing.expect(t, !ui.presence_visible(p.presence) && !ui.presence_active(p.presence))
	testing.expect_value(t, p.released, 1)
	presence_probe_frame(&p, false, start)
	testing.expect_value(t, p.released, 1)
}

@(test)
presence_fade_rises_only_while_closing :: proc(t: ^testing.T) {
	start := time.tick_now()
	p: ui.Presence
	ui.presence_open(&p, PRESENCE_PROBE_SPEC)
	_, _ = ui.presence_advance(&p, true, start)
	_, _ = ui.presence_advance(&p, true, time.tick_add(start, 200*time.Millisecond))
	opacity, offset := ui.presence_fade(p, 6)
	testing.expect_value(t, opacity, f32(1))
	testing.expect_value(t, offset, f32(0))

	ui.presence_close(&p)
	_, _ = ui.presence_advance(&p, true, time.tick_add(start, 200*time.Millisecond))
	_, _ = ui.presence_advance(&p, true, time.tick_add(start, 245*time.Millisecond))
	opacity, offset = ui.presence_fade(p, 6)
	testing.expect(t, opacity > 0 && opacity < 1)
	testing.expect(t, offset > 0 && offset < 6)
}
