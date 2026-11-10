package term_view_test

import "aio:caret"
import "aio:term_view"
import "core:slice"
import "core:testing"

@(test)
zero_strength_smear_matches_smooth_without_a_fringe :: proc(t: ^testing.T) {
	f, ok := headless_create(t)
	defer fixture_destroy(&f)
	if !ok {return}
	frames: [2][]u8
	for preset, i in ([2]caret.Preset{.Smooth, .Smear}) {
		term_view.cursor_reset(&f.view)
		write(&f, "\x1b[H")
		style := effects_style(&f, preset, strength = 0)
		render_frame(t, &f, style, frame_at(0))
		write(&f, "\x1b[1;10H")
		_, pixels := render_frame(t, &f, style, frame_at(1))
		frames[i] = slice.clone(pixels, context.temp_allocator)
	}
	testing.expect(t, slice.equal(frames[0], frames[1]), "zero strength must remove every smear pixel")
}

@(test)
scrolling_a_subregion_cancels_cursor_motion :: proc(t: ^testing.T) {
	f, ok := headless_create(t, rows = 512)
	defer fixture_destroy(&f)
	if !ok {return}
	write(&f, "\x1b[400;450r\x1b[410;1H")
	style := effects_style(&f, .Smear)
	render_frame(t, &f, style, frame_at(0))
	write(&f, "\x1b[420;11H")
	render_frame(t, &f, style, frame_at(1))
	testing.expect(t, term_view.cursor_animating(&f.view))
	// The scrolling region is in a later terminal page, leaving the first page untouched.
	write(&f, "\x1b[450;1H\n\x1b[420;11H")
	_, scrolled := render_frame(t, &f, style, frame_at(2))
	scrolled = slice.clone(scrolled, context.temp_allocator)
	testing.expect(t, !term_view.cursor_animating(&f.view))
	testing.expect(t, slice.equal(scrolled, render_still(t, &f)), "scrolling must not retain stale trails")
}

@(test)
moving_block_respects_the_panes_rounded_corner :: proc(t: ^testing.T) {
	f, ok := headless_create(t)
	defer fixture_destroy(&f)
	if !ok {return}
	style := effects_style(&f, .Smooth)
	write(&f, "\x1b[1;5H")
	render_frame(t, &f, style, frame_at(0), clip_radius = 16)
	write(&f, "\x1b[H")
	render_frame(t, &f, style, frame_at(1), clip_radius = 16)
	_, moving := render_frame(t, &f, style, frame_at(4), clip_radius = 16)
	testing.expect(t, term_view.cursor_animating(&f.view))
	testing.expect_value(t, cell_pixel(&f, moving, 0, 0, 0, 0), BLACK)
	testing.expect(t, cell_pixel(&f, moving, 0, 0, f.metrics.cell_width - 2, f.metrics.cell_height / 2) != BLACK,
		"the cursor remains visible inside the pane mask")
}
