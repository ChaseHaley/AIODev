package term_view_test

import "aio:neovim"
import "aio:render"
import "aio:term_view"
import "core:testing"
import "core:time"

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

@(private = "file")
redraw_event :: proc(w: ^neovim.Msgpack_Writer, name: string, args: int) {
	neovim.msgpack_write_array(w, 2)
	neovim.msgpack_write_str(w, name)
	neovim.msgpack_write_array(w, args)
}

@(private = "file")
write_ints :: proc(w: ^neovim.Msgpack_Writer, values: ..i64) {
	for value in values {neovim.msgpack_write_int(w, value)}
}

// A redraw notification of `events` events, the first four of them a 20x4 grid 1 on black with white
// text in a block-cursor mode.
@(private = "file")
redraw_begin :: proc(w: ^neovim.Msgpack_Writer, events: int) {
	neovim.msgpack_write_array(w, 3)
	neovim.msgpack_write_uint(w, 2)
	neovim.msgpack_write_str(w, "redraw")
	neovim.msgpack_write_array(w, events)
	redraw_event(w, "grid_resize", 3)
	write_ints(w, 1, COLUMNS, ROWS)
	redraw_event(w, "default_colors_set", 5)
	write_ints(w, 0xFFFFFF, 0x000000, 0xFF0000, 7, 0)
	redraw_event(w, "mode_info_set", 2)
	neovim.msgpack_write_bool(w, true)
	neovim.msgpack_write_array(w, 1)
	neovim.msgpack_write_map(w, 1)
	neovim.msgpack_write_str(w, "cursor_shape")
	neovim.msgpack_write_str(w, "block")
	redraw_event(w, "mode_change", 2)
	neovim.msgpack_write_str(w, "normal")
	neovim.msgpack_write_int(w, 0)
}

@(private = "file")
redraw_send :: proc(c: ^neovim.Client, w: ^neovim.Msgpack_Writer) -> bool {
	defer delete(w.bytes)
	redraw_event(w, "flush", 0)
	polled, err := neovim.receive(c, w.bytes[:])
	return err == .None && polled.flushed
}

@(private = "file")
write_highlight :: proc(w: ^neovim.Msgpack_Writer, id, background, blend: i64) {
	redraw_event(w, "hl_attr_define", 2)
	neovim.msgpack_write_int(w, id)
	neovim.msgpack_write_map(w, 2)
	neovim.msgpack_write_str(w, "background")
	neovim.msgpack_write_int(w, background)
	neovim.msgpack_write_str(w, "blend")
	neovim.msgpack_write_int(w, blend)
}

// A grid row of `count` blank cells in one highlight.
@(private = "file")
write_blank_line :: proc(w: ^neovim.Msgpack_Writer, grid, row, highlight, count: i64) {
	redraw_event(w, "grid_line", 4)
	write_ints(w, grid, row, 0)
	neovim.msgpack_write_array(w, 1)
	neovim.msgpack_write_array(w, 3)
	neovim.msgpack_write_str(w, " ")
	write_ints(w, highlight, count)
}

// Window grid 2 over the top three rows: row 0 green, row 1 blue, row 2 Neovim's background, with the
// cursor at its top-left cell.
@(private = "file")
neovim_window :: proc(c: ^neovim.Client) -> bool {
	w: neovim.Msgpack_Writer
	redraw_begin(&w, 12)
	write_highlight(&w, 1, 0x00FF00, 0)
	write_highlight(&w, 2, 0x0000FF, 0)
	redraw_event(&w, "grid_resize", 3)
	write_ints(&w, 2, COLUMNS, 3)
	redraw_event(&w, "win_pos", 6)
	write_ints(&w, 2, 1000, 0, 0, COLUMNS, 3)
	write_blank_line(&w, 2, 0, 1, COLUMNS)
	write_blank_line(&w, 2, 1, 2, COLUMNS)
	redraw_event(&w, "grid_cursor_goto", 3)
	write_ints(&w, 2, 0, 0)
	return redraw_send(c, &w)
}

// What Neovim sends when Ctrl+E scrolls window grid 2 down a line.
@(private = "file")
neovim_scroll_down :: proc(c: ^neovim.Client) -> bool {
	w: neovim.Msgpack_Writer
	neovim.msgpack_write_array(&w, 3)
	neovim.msgpack_write_uint(&w, 2)
	neovim.msgpack_write_str(&w, "redraw")
	neovim.msgpack_write_array(&w, 5)
	redraw_event(&w, "grid_scroll", 7)
	write_ints(&w, 2, 0, 3, 0, COLUMNS, 1, 0)
	write_blank_line(&w, 2, 2, 0, COLUMNS)
	redraw_event(&w, "win_viewport", 8)
	write_ints(&w, 2, 1000, 1, 4, 1, 0, 10, 1)
	redraw_event(&w, "grid_cursor_goto", 3)
	write_ints(&w, 2, 0, 0)
	return redraw_send(c, &w)
}

// Neovide's smooth scrolling, which the owner asked for as an option: when Neovim scrolls a window
// the text glides from where it was to where it is, the cursor riding with its line, and lands. Off,
// it jumps as in a terminal.
@(test)
neovim_window_scrolls_smoothly_when_neovim_scrolls_it :: proc(t: ^testing.T) {
	f, ok := headless_create(t)
	defer fixture_destroy(&f)
	if !ok {return}
	green, blue := [4]u8{0, 255, 0, 255}, [4]u8{255, 0, 0, 255}
	h := f.metrics.cell_height
	duration := 100 * time.Millisecond
	for smooth in ([2]bool{true, false}) {
		c: neovim.Client
		defer neovim.destroy(&c)
		v: term_view.Neovim_View
		defer term_view.neovim_view_destroy(&v)
		style := term_view.Neovim_Style {
			family = f.family, cursor_color = {1, 1, 1, 1}, cursor_effects = {preset = .Off},
			smooth_scroll = smooth, overlay_opacity = 1,
		}
		if !testing.expect(t, neovim_window(&c)) {return}
		_, before := neovim_render(t, &f, &v, &c, style, frame_at(0))
		testing.expect_value(t, cell_pixel(&f, before, 5, 0, 1, 1), green)
		testing.expect_value(t, cell_pixel(&f, before, 5, 1, 1, 1), blue)

		if !testing.expect(t, neovim_scroll_down(&c)) {return}
		frame, first := neovim_render(t, &f, &v, &c, style, frame_at(1))
		if !smooth {
			testing.expect(t, !term_view.neovim_scroll_animating(&v), "without smooth scrolling text jumps")
			testing.expect_value(t, cell_pixel(&f, first, 5, 0, 1, 1), blue)
			testing.expect_value(t, frame.cursor.?.head.y, 0)
			continue
		}
		testing.expect(t, term_view.neovim_scroll_animating(&v), "a scroll starts where the text was")
		testing.expect_value(t, cell_pixel(&f, first, 5, 0, 1, 1), green)
		testing.expect_value(t, cell_pixel(&f, first, 5, 1, 1, 1), blue)
		testing.expect_value(t, frame.cursor.?.head.y, h)

		testing.expect(t, term_view.neovim_scroll_animate(&v, frame_at(2), duration, true))
		frame, _ = neovim_render(t, &f, &v, &c, style, frame_at(2))
		y := frame.cursor.?.head.y
		testing.expectf(t, y > 0 && y < h, "the cursor travels with its line, at %v", y)

		for n in 3 ..< 40 {
			if !term_view.neovim_scroll_animate(&v, frame_at(n), duration, true) {break}
		}
		testing.expect(t, !term_view.neovim_scroll_animating(&v), "a scroll lands")
		landed: []u8
		frame, landed = neovim_render(t, &f, &v, &c, style, frame_at(40))
		testing.expect_value(t, cell_pixel(&f, landed, 5, 0, 1, 1), blue)
		testing.expect_value(t, cell_pixel(&f, landed, 5, 1, 1, 1), [4]u8{0, 0, 0, 255})
		testing.expect_value(t, frame.cursor.?.head.y, 0)
	}
}

// A green 10x3 window grid 2 whose top-left cell is at `column`, with the cursor at its top-left cell. The
// first call also sets up grid 1; later ones are what Neovim sends when it moves the window.
@(private = "file")
neovim_window_at :: proc(c: ^neovim.Client, column: i64, first: bool) -> bool {
	w: neovim.Msgpack_Writer
	if first {
		redraw_begin(&w, 12)
		write_highlight(&w, 1, 0x00FF00, 0)
		redraw_event(&w, "grid_resize", 3)
		write_ints(&w, 2, 10, 3)
		for row in 0 ..< i64(3) {write_blank_line(&w, 2, row, 1, 10)}
	} else {
		neovim.msgpack_write_array(&w, 3)
		neovim.msgpack_write_uint(&w, 2)
		neovim.msgpack_write_str(&w, "redraw")
		neovim.msgpack_write_array(&w, 3)
	}
	redraw_event(&w, "win_pos", 6)
	write_ints(&w, 2, 1000, 0, column, 10, 3)
	redraw_event(&w, "grid_cursor_goto", 3)
	write_ints(&w, 2, 0, 0)
	return redraw_send(c, &w)
}

// The owner asked for Neovim's windows to move as Neovide moves them: a window Neovim moves slides from
// where it was drawn to its new place, the cursor riding with it, and lands. A window shown for the first
// time does not slide, and with the setting off a moved window jumps.
@(test)
neovim_window_slides_when_neovim_moves_it :: proc(t: ^testing.T) {
	f, ok := headless_create(t)
	defer fixture_destroy(&f)
	if !ok {return}
	green, black := [4]u8{0, 255, 0, 255}, [4]u8{0, 0, 0, 255}
	place := 10 * f.metrics.cell_width
	duration := 100 * time.Millisecond
	for animate in ([2]bool{true, false}) {
		c: neovim.Client
		defer neovim.destroy(&c)
		v: term_view.Neovim_View
		defer term_view.neovim_view_destroy(&v)
		style := term_view.Neovim_Style {
			family = f.family, cursor_color = {1, 1, 1, 1}, cursor_effects = {preset = .Off},
			animate_moves = animate, overlay_opacity = 1,
		}
		if !testing.expect(t, neovim_window_at(&c, 0, true)) {return}
		_, shown := neovim_render(t, &f, &v, &c, style, frame_at(0))
		testing.expect(t, !term_view.neovim_moves_animating(&v), "a window shown for the first time does not slide")
		testing.expect_value(t, cell_pixel(&f, shown, 2, 1, 1, 1), green)

		if !testing.expect(t, neovim_window_at(&c, 10, false)) {return}
		frame, first := neovim_render(t, &f, &v, &c, style, frame_at(1))
		if !animate {
			testing.expect(t, !term_view.neovim_moves_animating(&v), "with window moves off a window jumps")
			testing.expect_value(t, cell_pixel(&f, first, 12, 1, 1, 1), green)
			testing.expect_value(t, cell_pixel(&f, first, 2, 1, 1, 1), black)
			testing.expect_value(t, frame.cursor.?.head.x, place)
			continue
		}
		testing.expect(t, term_view.neovim_moves_animating(&v), "a move starts where the window was")
		testing.expect_value(t, cell_pixel(&f, first, 2, 1, 1, 1), green)
		testing.expect_value(t, cell_pixel(&f, first, 12, 1, 1, 1), black)
		testing.expect_value(t, frame.cursor.?.head.x, 0)

		testing.expect(t, term_view.neovim_moves_animate(&v, frame_at(2), duration, true))
		frame, _ = neovim_render(t, &f, &v, &c, style, frame_at(2))
		x := frame.cursor.?.head.x
		testing.expectf(t, x > 0 && x < place, "the cursor rides with its window, at %v", x)

		for n in 3 ..< 40 {
			if !term_view.neovim_moves_animate(&v, frame_at(n), duration, true) {break}
		}
		testing.expect(t, !term_view.neovim_moves_animating(&v), "a move lands")
		landed: []u8
		frame, landed = neovim_render(t, &f, &v, &c, style, frame_at(40))
		testing.expect_value(t, cell_pixel(&f, landed, 12, 1, 1, 1), green)
		testing.expect_value(t, cell_pixel(&f, landed, 2, 1, 1, 1), black)
		testing.expect_value(t, frame.cursor.?.head.x, place)
	}
}

// A green window under three blue floats on its first three rows: one whose highlight has blend 50, one
// that takes no input (as treesitter-context's does), and one opaque.
@(private = "file")
neovim_floats :: proc(c: ^neovim.Client) -> bool {
	w: neovim.Msgpack_Writer
	redraw_begin(&w, 24)
	write_highlight(&w, 1, 0x00FF00, 0)
	write_highlight(&w, 2, 0x0000FF, 50)
	write_highlight(&w, 3, 0x0000FF, 0)
	redraw_event(&w, "grid_resize", 3)
	write_ints(&w, 2, COLUMNS, ROWS)
	redraw_event(&w, "win_pos", 6)
	write_ints(&w, 2, 1000, 0, 0, COLUMNS, ROWS)
	for row in 0 ..< i64(ROWS) {write_blank_line(&w, 2, row, 1, COLUMNS)}
	floats := [3]struct {
		highlight: i64,
		focusable: bool,
	}{{2, true}, {3, false}, {3, true}}
	for float, i in floats {
		grid, row := i64(3 + i), i64(i)
		redraw_event(&w, "grid_resize", 3)
		write_ints(&w, grid, 4, 1)
		redraw_event(&w, "win_float_pos", 11)
		write_ints(&w, grid, 1000 + grid)
		neovim.msgpack_write_str(&w, "NW")
		write_ints(&w, 2, row, 0)
		neovim.msgpack_write_bool(&w, float.focusable)
		write_ints(&w, 50, grid, row, 0)
		write_blank_line(&w, grid, 0, float.highlight, 4)
	}
	redraw_event(&w, "grid_cursor_goto", 3)
	write_ints(&w, 2, 3, 19)
	return redraw_send(c, &w)
}

// The owner asked for treesitter-context's float to be see-through rather than opaque: a float's blend,
// and the overlay opacity for a float that takes no input, mix its background with what is under it.
@(test)
neovim_floats_show_the_text_under_them_through_their_background :: proc(t: ^testing.T) {
	f, ok := headless_create(t)
	defer fixture_destroy(&f)
	if !ok {return}
	c: neovim.Client
	defer neovim.destroy(&c)
	v: term_view.Neovim_View
	defer term_view.neovim_view_destroy(&v)
	style := term_view.Neovim_Style {
		family = f.family, cursor_color = {1, 1, 1, 1}, cursor_effects = {preset = .Off}, overlay_opacity = 0.5,
	}
	if !testing.expect(t, neovim_floats(&c)) {return}
	testing.expect_value(t, len(c.screen.grids), 5)
	_, pixels := neovim_render(t, &f, &v, &c, style, frame_at(0))
	mixed :: proc(p: [4]u8) -> bool {return p[0] > 60 && p[0] < 200 && p[1] > 60 && p[1] < 200 && p[2] < 30}
	blended := cell_pixel(&f, pixels, 1, 0, 1, 1)
	testing.expectf(t, mixed(blended), "a float with blend 50 is half see-through: %v", blended)
	overlay := cell_pixel(&f, pixels, 1, 1, 1, 1)
	testing.expectf(t, mixed(overlay), "a float that takes no input takes the overlay opacity: %v", overlay)
	testing.expect_value(t, cell_pixel(&f, pixels, 1, 2, 1, 1), [4]u8{255, 0, 0, 255})
	testing.expect_value(t, cell_pixel(&f, pixels, 6, 0, 1, 1), [4]u8{0, 255, 0, 255})
}

// A grid row of one-cell text starting at `column`, in Neovim's default colours.
@(private = "file")
write_text_line :: proc(w: ^neovim.Msgpack_Writer, grid, row, column: i64, text: string) {
	redraw_event(w, "grid_line", 4)
	write_ints(w, grid, row, column)
	neovim.msgpack_write_array(w, len(text))
	for i in 0 ..< len(text) {
		neovim.msgpack_write_array(w, 1)
		neovim.msgpack_write_str(w, text[i:i + 1])
	}
}

// The owner's clip: dragging a split left a trail of separators across the windows. Neovim draws
// separators on the base grid and never clears the cells a window then covers, so the windows hide them.
@(test)
neovim_windows_hide_the_separators_a_split_drag_leaves_on_the_base_grid :: proc(t: ^testing.T) {
	f, ok := headless_create(t)
	defer fixture_destroy(&f)
	if !ok {return}
	c: neovim.Client
	defer neovim.destroy(&c)
	v: term_view.Neovim_View
	defer term_view.neovim_view_destroy(&v)
	style := term_view.Neovim_Style {
		family = f.family, cursor_color = {1, 1, 1, 1}, cursor_effects = {preset = .Off}, overlay_opacity = 1,
	}
	w: neovim.Msgpack_Writer
	redraw_begin(&w, 12)
	for row in 0 ..< i64(3) {write_text_line(&w, 1, row, 5, "|")}
	write_text_line(&w, 1, 3, 0, "status")
	redraw_event(&w, "grid_resize", 3)
	write_ints(&w, 2, COLUMNS, 3)
	redraw_event(&w, "win_pos", 6)
	write_ints(&w, 2, 1000, 0, 0, COLUMNS, 3)
	redraw_event(&w, "grid_cursor_goto", 3)
	write_ints(&w, 2, 0, 0)
	if !testing.expect(t, redraw_send(&c, &w)) {return}
	_, pixels := neovim_render(t, &f, &v, &c, style, frame_at(0))
	for row in 0 ..< 3 {
		testing.expectf(t, !cell_has_ink(&f, pixels, 5, row), "a stale separator shows on row %d", row)
	}
	testing.expect(t, cell_has_ink(&f, pixels, 0, 3), "the base grid's own row draws")
}
