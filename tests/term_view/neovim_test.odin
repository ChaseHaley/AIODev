package term_view_test

import "aio:neovim"
import "aio:render"
import "aio:term_view"
import "core:testing"

// One redraw notification: a 20x4 grid on black with white text, "hello" on row 0, the cursor at
// (column, row) in a block-cursor mode, then flush.
@(private = "file")
neovim_screen :: proc(c: ^neovim.Client, column, row: int) -> bool {
	w: neovim.Msgpack_Writer
	defer delete(w.bytes)
	event :: proc(w: ^neovim.Msgpack_Writer, name: string, args: int) {
		neovim.msgpack_write_array(w, 2)
		neovim.msgpack_write_str(w, name)
		neovim.msgpack_write_array(w, args)
	}
	neovim.msgpack_write_array(&w, 3)
	neovim.msgpack_write_uint(&w, 2)
	neovim.msgpack_write_str(&w, "redraw")
	neovim.msgpack_write_array(&w, 7)
	event(&w, "grid_resize", 3)
	for value in ([3]i64{1, COLUMNS, ROWS}) {neovim.msgpack_write_int(&w, value)}
	event(&w, "default_colors_set", 5)
	for value in ([5]i64{0xFFFFFF, 0x000000, 0xFF0000, 7, 0}) {neovim.msgpack_write_int(&w, value)}
	event(&w, "mode_info_set", 2)
	neovim.msgpack_write_bool(&w, true)
	neovim.msgpack_write_array(&w, 1)
	neovim.msgpack_write_map(&w, 1)
	neovim.msgpack_write_str(&w, "cursor_shape")
	neovim.msgpack_write_str(&w, "block")
	event(&w, "mode_change", 2)
	neovim.msgpack_write_str(&w, "normal")
	neovim.msgpack_write_int(&w, 0)
	event(&w, "grid_line", 4)
	neovim.msgpack_write_int(&w, 1)
	neovim.msgpack_write_int(&w, 0)
	neovim.msgpack_write_int(&w, 0)
	neovim.msgpack_write_array(&w, 5)
	for letter in ([5]string{"h", "e", "l", "l", "o"}) {
		neovim.msgpack_write_array(&w, 1)
		neovim.msgpack_write_str(&w, letter)
	}
	event(&w, "grid_cursor_goto", 3)
	for value in ([3]i64{1, i64(row), i64(column)}) {neovim.msgpack_write_int(&w, value)}
	event(&w, "flush", 0)
	polled, err := neovim.receive(c, w.bytes[:])
	return err == .None && polled.flushed
}

@(private = "file")
neovim_render :: proc(
	t: ^testing.T, f: ^Fixture, v: ^term_view.Neovim_View, c: ^neovim.Client, style: term_view.Neovim_Style,
	frame_time: render.Frame_Time,
) -> (term_view.Neovim_Frame, []u8) {
	render.draw_list_reset(&f.list)
	clip := render.Rect{0, 0, f.metrics.cell_width * COLUMNS, f.metrics.cell_height * ROWS}
	testing.expect_value(t, render.push_layer(&f.list, clip, 0), render.Error.None)
	frame, result := term_view.neovim_build(v, c, f.fonts, &f.cache, &f.list, {0, 0}, f.metrics, style, frame_time)
	testing.expect_value(t, result, render.Build_Status.Ok)
	testing.expect_value(t, render.frame_render(f.device, f.surface, &f.list, frame.background), render.Error.None)
	pixels, err := render.surface_read_pixels(f.device, f.surface, context.temp_allocator)
	testing.expect_value(t, err, render.Error.None)
	return frame, pixels
}

// The owner's report: a Neovim pane's cursor took the colour of the character under it and never moved
// smoothly. It is AIODev's cursor now, in the cursor colour, and with Cursor Animation on it glides
// from cell to cell; a moving block keeps the text it passes readable and the build ends.
@(test)
neovim_cursor_is_aiodevs_cursor_and_moves_with_its_effects :: proc(t: ^testing.T) {
	f, ok := headless_create(t)
	defer fixture_destroy(&f)
	if !ok {return}
	c: neovim.Client
	defer neovim.destroy(&c)
	v: term_view.Neovim_View
	defer term_view.neovim_view_destroy(&v)
	green := [4]u8{0, 255, 0, 255}
	style := term_view.Neovim_Style {
		family = f.family, focused = true, cursor_visible = true,
		cursor_color = {0, 1, 0, 1}, cursor_text = {0, 0, 0, 1}, minimum_contrast = 1,
		cursor_effects = {preset = .Smooth, duration = 5 * PERIOD, strength = 1, movement = true},
	}
	if !testing.expect(t, neovim_screen(&c, 0, 0)) {return}
	frame, first := neovim_render(t, &f, &v, &c, style, frame_at(0))
	testing.expect(t, frame.cursor != nil)
	testing.expect(t, !term_view.neovim_cursor_animating(&v), "a cursor's first appearance must not move")
	// The block over the white "h" is the cursor colour, not the text's.
	testing.expect_value(t, cell_pixel(&f, first, 0, 0, 1, 1), green)

	if !testing.expect(t, neovim_screen(&c, 4, 0)) {return}
	frame, _ = neovim_render(t, &f, &v, &c, style, frame_at(1))
	testing.expect(t, term_view.neovim_cursor_animating(&v), "a move with Cursor Animation on glides")
	paint := frame.cursor.?
	testing.expectf(t, paint.head.x > 0 && paint.head.x < 4 * f.metrics.cell_width, "head at %v", paint.head)
	testing.expect_value(t, paint.color, render.Color{0, 1, 0, 1})

	for n in 2 ..< 7 {
		_ = term_view.neovim_cursor_animate(&v, frame_at(n), true)
	}
	testing.expect(t, !term_view.neovim_cursor_animating(&v))
	landed: []u8
	frame, landed = neovim_render(t, &f, &v, &c, style, frame_at(7))
	paint = frame.cursor.?
	testing.expect_value(t, paint.head.x, 4 * f.metrics.cell_width)
	testing.expect_value(t, cell_pixel(&f, landed, 4, 0, 1, 1), green)

	// With Cursor Animation off it lands at once.
	style.cursor_effects = {preset = .Off}
	if !testing.expect(t, neovim_screen(&c, 1, 0)) {return}
	frame, _ = neovim_render(t, &f, &v, &c, style, frame_at(8))
	testing.expect(t, !term_view.neovim_cursor_animating(&v))
	paint = frame.cursor.?
	testing.expect_value(t, paint.head.x, f.metrics.cell_width)
}
