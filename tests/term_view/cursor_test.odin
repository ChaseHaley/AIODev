package term_view_test

import "aio:render"
import "aio:term_view"
import "core:math"
import "core:slice"
import "core:testing"
import "core:time"

// Frames on a 50 Hz grid, so a five-refresh motion lands on an exact frame.
@(private)
PERIOD :: 20 * time.Millisecond

@(private)
BLACK :: [4]u8{0, 0, 0, 255}

@(private)
frame_at :: proc(n: int, resuming := false) -> render.Frame_Time {
	return {display = time.tick_add({}, time.Second + time.Duration(n) * PERIOD), period = PERIOD, resuming = resuming}
}

@(private)
effects_style :: proc(
	f: ^Fixture, preset: term_view.Cursor_Preset, movement := true, strength := f32(1),
) -> term_view.Style {
	return {
		family = f.family,
		cursor_text = {0, 0, 0, 1},
		focused = true,
		cursor_phase_visible = true,
		cursor_effects = {preset = preset, duration = 5 * PERIOD, strength = strength, movement = movement},
	}
}

// The same screen drawn with no cursor effects, which a settled cursor must match byte for byte.
@(private)
render_still :: proc(t: ^testing.T, f: ^Fixture) -> []u8 {
	style := effects_style(f, .Off)
	_, pixels := render_frame(t, f, style)
	return pixels
}

@(private = "file")
head_rect :: proc(f: ^Fixture) -> render.Rect {
	layer := f.list.layers[len(f.list.layers) - 1]
	return f.list.rects[layer.rect_start].rect
}

@(test)
smooth_cursor_retargets_from_where_it_is_and_lands_exactly :: proc(t: ^testing.T) {
	f, ok := headless_create(t)
	defer fixture_destroy(&f)
	if !ok {return}
	m := f.metrics
	style := effects_style(&f, .Smooth)
	_, first := render_frame(t, &f, style, frame_at(0))
	testing.expect(t, !term_view.cursor_animating(&f.view), "a cursor's first appearance must not move")
	cursor := cell_pixel(&f, first, 0, 0, 1, 1)
	testing.expect(t, cursor != BLACK)

	// Typing changes the first row in place; it keeps its identity, so the cursor glides.
	write(&f, "hello")
	_, gliding := render_frame(t, &f, style, frame_at(1))
	testing.expect(t, term_view.cursor_animating(&f.view))
	head := head_rect(&f)
	testing.expectf(t, head.x > 0 && head.x < 5 * m.cell_width && head.y == 0, "head at %v", head)
	testing.expect_value(t, head.width, m.cell_width)
	testing.expect_value(t, cell_pixel(&f, gliding, 0, 0, head.x + 1, 1), cursor)
	// The destination is not painted as the cursor before the head gets there.
	testing.expect_value(t, cell_pixel(&f, gliding, 5, 0, 1, 1), BLACK)
	// The text under the head is drawn again over it in the cursor text colour, and only there.
	ink := false
	for y in int(head.y) ..< int(head.y + head.height) {
		for x in int(head.x) ..< int(head.x + head.width) {
			ink ||= cell_pixel(&f, gliding, 0, 0, f32(x), f32(y)) == BLACK
		}
	}
	testing.expect(t, ink, "the moving opaque block must keep the covered text readable")

	testing.expect(t, term_view.cursor_animate(&f.view, frame_at(2), true))
	render_frame(t, &f, style, frame_at(2))
	testing.expect(t, head_rect(&f).x > head.x)
	testing.expect(t, term_view.cursor_animate(&f.view, frame_at(3), true))
	render_frame(t, &f, style, frame_at(3))
	shown := head_rect(&f)

	// A new destination mid-flight starts from the moving head, not from either cell.
	write(&f, "\x1b[3;1H")
	testing.expect(t, term_view.cursor_animate(&f.view, frame_at(4), true))
	render_frame(t, &f, style, frame_at(4))
	turned := head_rect(&f)
	testing.expectf(t, turned.x > 0 && turned.x < shown.x, "head x %v after %v", turned.x, shown.x)
	testing.expectf(t, turned.y > 0 && turned.y < 2 * m.cell_height, "head y %v", turned.y)
	u := f32(1) - f32(1) / 5
	step := 1 - u * u * u
	testing.expect_value(t, turned.x, math.round(shown.x + (0 - shown.x) * step))
	testing.expect_value(t, turned.y, math.round(2 * m.cell_height * step))

	// It started one refresh before frame 4, so it lands on frame 8, reports that once and then rests.
	for n in 5 ..< 8 {
		testing.expect(t, term_view.cursor_animate(&f.view, frame_at(n), true))
		testing.expectf(t, term_view.cursor_animating(&f.view), "still moving at frame %d", n)
	}
	testing.expect(t, term_view.cursor_animate(&f.view, frame_at(8), true))
	testing.expect(t, !term_view.cursor_animating(&f.view))
	testing.expect(t, !term_view.cursor_animate(&f.view, frame_at(9), true))
	_, landed := render_frame(t, &f, style, frame_at(9))
	landed = slice.clone(landed, context.temp_allocator)
	testing.expect(t, slice.equal(landed, render_still(t, &f)), "a settled cursor draws as with no effects")
}

@(test)
smear_without_movement_lands_at_once_and_contracts :: proc(t: ^testing.T) {
	f, ok := headless_create(t)
	defer fixture_destroy(&f)
	if !ok {return}
	m := f.metrics
	style := effects_style(&f, .Smear, movement = false)
	render_frame(t, &f, style, frame_at(0))
	write(&f, "\x1b[1;11H")
	// Even a resuming frame, whose motions wait for the next, shows the cursor at its cell.
	_, smeared := render_frame(t, &f, style, frame_at(1, resuming = true))
	testing.expect(t, term_view.cursor_animating(&f.view))
	testing.expect_value(t, head_rect(&f), render.Rect{10 * m.cell_width, 0, m.cell_width, m.cell_height})
	testing.expect(t, cell_pixel(&f, smeared, 5, 0, m.cell_width / 2, m.cell_height / 2) != BLACK)
	testing.expect_value(t, cell_pixel(&f, smeared, 5, 1, m.cell_width / 2, m.cell_height / 2), BLACK)

	// The resuming frame did not start it; frame 2 does, one refresh in, so it ends on frame 6.
	testing.expect(t, !term_view.cursor_animate(&f.view, frame_at(1, resuming = true), true))
	for n in 2 ..< 6 {
		testing.expect(t, term_view.cursor_animate(&f.view, frame_at(n), true))
		testing.expect(t, term_view.cursor_animating(&f.view))
	}
	testing.expect(t, term_view.cursor_animate(&f.view, frame_at(6), true))
	testing.expect(t, !term_view.cursor_animating(&f.view))
	_, landed := render_frame(t, &f, style, frame_at(6))
	landed = slice.clone(landed, context.temp_allocator)
	testing.expect(t, slice.equal(landed, render_still(t, &f)))

	// No strength and no movement leave nothing to animate.
	none := effects_style(&f, .Smear, movement = false, strength = 0)
	render_frame(t, &f, none, frame_at(7))
	write(&f, "\x1b[2;3H")
	_, instant := render_frame(t, &f, none, frame_at(8))
	instant = slice.clone(instant, context.temp_allocator)
	testing.expect(t, !term_view.cursor_animating(&f.view))
	testing.expect(t, slice.equal(instant, render_still(t, &f)))
	still := effects_style(&f, .Smooth, movement = false)
	render_frame(t, &f, still, frame_at(9))
	write(&f, "\x1b[4;9H")
	render_frame(t, &f, still, frame_at(10))
	testing.expect(t, !term_view.cursor_animating(&f.view))
}

@(test)
trail_fades_toward_where_the_cursor_was :: proc(t: ^testing.T) {
	f, ok := headless_create(t)
	defer fixture_destroy(&f)
	if !ok {return}
	m := f.metrics
	style := effects_style(&f, .Trail, movement = false)
	render_frame(t, &f, style, frame_at(0))
	write(&f, "\x1b[1;20H")
	_, pixels := render_frame(t, &f, style, frame_at(1))
	brightness :: proc(p: [4]u8) -> int {return int(p[0]) + int(p[1]) + int(p[2])}
	near_tail := brightness(cell_pixel(&f, pixels, 4, 0, m.cell_width / 2, m.cell_height / 2))
	near_head := brightness(cell_pixel(&f, pixels, 16, 0, m.cell_width / 2, m.cell_height / 2))
	testing.expectf(t, near_head > near_tail, "trail %d near the head, %d near the tail", near_head, near_tail)
	// The trail tapers: its far end is thinner than the cursor.
	testing.expect_value(t, cell_pixel(&f, pixels, 4, 0, m.cell_width / 2, 0), BLACK)
}

@(test)
hidden_reset_and_scrolled_cursors_land_without_replay :: proc(t: ^testing.T) {
	f, ok := headless_create(t)
	defer fixture_destroy(&f)
	if !ok {return}
	style := effects_style(&f, .Smear)
	render_frame(t, &f, style, frame_at(0))
	write(&f, "\x1b[2;8H")
	render_frame(t, &f, style, frame_at(1))
	testing.expect(t, term_view.cursor_animating(&f.view))

	// A blink's hidden phase drops the motion and its smear.
	hidden := style
	hidden.cursor_phase_visible = false
	render_frame(t, &f, hidden, frame_at(2))
	testing.expect(t, !term_view.cursor_animating(&f.view))
	_, shown := render_frame(t, &f, style, frame_at(3))
	shown = slice.clone(shown, context.temp_allocator)
	testing.expect(t, !term_view.cursor_animating(&f.view))
	testing.expect(t, slice.equal(shown, render_still(t, &f)))

	// After a reset the next build draws the cursor where the terminal has it, with no motion.
	render_frame(t, &f, style, frame_at(4))
	write(&f, "\x1b[4;6H")
	term_view.cursor_reset(&f.view)
	_, reset := render_frame(t, &f, style, frame_at(5))
	reset = slice.clone(reset, context.temp_allocator)
	testing.expect(t, !term_view.cursor_animating(&f.view))
	testing.expect(t, slice.equal(reset, render_still(t, &f)))

	// Output that scrolls the screen moves every cell under the cursor, so it lands at once.
	render_frame(t, &f, style, frame_at(6))
	write(&f, "\r\nab")
	_, scrolled := render_frame(t, &f, style, frame_at(7))
	scrolled = slice.clone(scrolled, context.temp_allocator)
	testing.expect(t, !term_view.cursor_animating(&f.view))
	testing.expect(t, slice.equal(scrolled, render_still(t, &f)))

	// Terminal-hidden cursors also clear their history, not only a blink's hidden phase.
	render_frame(t, &f, style, frame_at(8))
	write(&f, "\x1b[?25l\x1b[2;15H")
	render_frame(t, &f, style, frame_at(9))
	testing.expect(t, !term_view.cursor_animating(&f.view))
	write(&f, "\x1b[?25h")
	render_frame(t, &f, style, frame_at(10))
	testing.expect(t, !term_view.cursor_animating(&f.view))

	write(&f, "\x1b[1;3H")
	render_frame(t, &f, style, frame_at(11))
	testing.expect(t, term_view.cursor_animating(&f.view))
	testing.expect(t, term_view.cursor_animate(&f.view, frame_at(12), false))
	testing.expect(t, !term_view.cursor_animating(&f.view))
	_, disabled := render_frame(t, &f, style, frame_at(12))
	disabled = slice.clone(disabled, context.temp_allocator)
	testing.expect(t, slice.equal(disabled, render_still(t, &f)))
}

@(test)
moving_bar_cursor_keeps_its_shape :: proc(t: ^testing.T) {
	f, ok := headless_create(t)
	defer fixture_destroy(&f)
	if !ok {return}
	m := f.metrics
	style := effects_style(&f, .Smooth)
	write(&f, "\x1b[6 q")
	render_frame(t, &f, style, frame_at(0))
	write(&f, "\x1b[1;11H")
	render_frame(t, &f, style, frame_at(1))
	testing.expect(t, term_view.cursor_animating(&f.view))
	bar := head_rect(&f)
	testing.expect_value(t, bar.width, 2 * max(1, m.underline_thickness))
	testing.expect_value(t, bar.height, m.cell_height)
	testing.expectf(t, bar.x > 0 && bar.x < 10 * m.cell_width, "bar at %v", bar.x)

	// Changing shape during a move does not carry the old shape through the new one.
	write(&f, "\x1b[4 q")
	render_frame(t, &f, style, frame_at(2))
	testing.expect(t, !term_view.cursor_animating(&f.view))
	underline := f.list.rects[len(f.list.rects) - 1].rect
	testing.expect_value(t, underline, render.Rect{
		10 * m.cell_width, m.cell_height - 2 * max(1, m.underline_thickness),
		m.cell_width, 2 * max(1, m.underline_thickness),
	})
}

// A cursor the terminal reports on a wide character's second cell draws over both, as on its first.
@(test)
cursor_on_a_wide_tail_covers_the_character :: proc(t: ^testing.T) {
	f, ok := headless_create(t)
	defer fixture_destroy(&f)
	if !ok {return}
	m := f.metrics
	write(&f, "\u754cx\x1b[1;1H")
	style := effects_style(&f, .Off)
	_, on_head := render_frame(t, &f, style)
	left, right := cell_pixel(&f, on_head, 0, 0, 0, 1), cell_pixel(&f, on_head, 1, 0, m.cell_width - 1, 1)
	testing.expect(t, left != BLACK)
	write(&f, "\x1b[1;2H")
	_, on_tail := render_frame(t, &f, style)
	testing.expect_value(t, cell_pixel(&f, on_tail, 0, 0, 0, 1), left)
	testing.expect_value(t, cell_pixel(&f, on_tail, 1, 0, m.cell_width - 1, 1), right)
	testing.expect_value(t, cell_pixel(&f, on_tail, 2, 0, 0, 1), BLACK)
}

@(test)
moving_block_preserves_image_z_order_and_full_image_clip :: proc(t: ^testing.T) {
	f, ok := headless_create(t)
	defer fixture_destroy(&f)
	if !ok {return}
	m := f.metrics
	// A red image across the whole row, below the text. Its pixels remain outside the moving head.
	write(&f, "\x1b_Ga=T,f=24,s=1,v=1,i=1,c=20,r=1,z=-1,C=1;/wAA\x1b\\")
	style := effects_style(&f, .Smooth)
	render_frame(t, &f, style, frame_at(0))
	write(&f, "\x1b[1;11H")
	_, below := render_frame(t, &f, style, frame_at(1))
	head := head_rect(&f)
	testing.expect(t, cell_pixel(&f, below, 0, 0, head.x + 1, m.cell_height / 2) != [4]u8{0, 0, 255, 255})
	testing.expect_value(t, cell_pixel(&f, below, 19, 0, m.cell_width / 2, m.cell_height / 2), [4]u8{0, 0, 255, 255})

	// A green above-text image covers the head and the whole row, not only the head's text clip.
	write(&f, "\x1b[H\x1b_Ga=T,f=24,s=1,v=1,i=2,c=20,r=1,z=1,C=1;AP8A\x1b\\\x1b[1;11H")
	_, above := render_frame(t, &f, style, frame_at(2))
	for column in 0 ..< COLUMNS {
		testing.expect_value(t, cell_pixel(&f, above, column, 0, m.cell_width / 2, m.cell_height / 2), [4]u8{0, 255, 0, 255})
	}
}
