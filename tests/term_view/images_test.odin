package term_view_test

import "aio:font"
import "aio:glyphs"
import "aio:render"
import "aio:term"
import "aio:term_view"
import "core:encoding/base64"
import "core:fmt"
import "core:testing"

// A fixture with no shell behind it, so a test decides exactly what the terminal receives.
@(private = "file")
headless_create :: proc(t: ^testing.T) -> (f: Fixture, ok: bool) {
	font_error: font.Error
	f.fonts, font_error = font.system_create()
	if !testing.expect_value(t, font_error, font.Error.None) {return}
	f.family, font_error = font.family_load(f.fonts, "Consolas")
	render_error: render.Error
	f.device, render_error = render.device_create()
	if font_error != .None || render_error != .None {
		testing.fail(t)
		return
	}
	f.metrics = term_view.compute_metrics(f.fonts, f.family, SIZE_PX, 1)
	width, height := i32(f.metrics.cell_width * COLUMNS), i32(f.metrics.cell_height * ROWS)
	f.surface, render_error = render.surface_create_offscreen(f.device, width, height)
	if !testing.expect_value(t, render_error, render.Error.None) || !term_view.create(&f.view) {return}
	glyphs.init(&f.cache, f.fonts, f.device)
	render.set_text_gamma(f.device, {1, 0})
	f.list = render.draw_list_init()
	session_error: term.Error
	f.session, session_error = term.create_headless(
		{
			columns = COLUMNS,
			rows = ROWS,
			cell_width = u32(f.metrics.cell_width),
			cell_height = u32(f.metrics.cell_height),
			surface_width = u32(width),
			surface_height = u32(height),
		},
		100,
	)
	return f, testing.expect_value(t, session_error, term.Error.None)
}

// A solid image of `cols` by `rows` cells at the cursor, one source pixel scaled to fill them.
@(private = "file")
place :: proc(f: ^Fixture, id: int, color: [3]u8, cols, rows: int, z := 0) {
	pixel := color
	encoded, _ := base64.encode(pixel[:], allocator = context.temp_allocator)
	sequence := fmt.tprintf(
		"\x1b_Ga=T,f=24,s=1,v=1,i=%d,c=%d,r=%d,z=%d,C=1;%s\x1b\\",
		id, cols, rows, z, encoded,
	)
	term.replay_write(f.session, transmute([]u8)sequence)
}

@(private = "file")
write :: proc(f: ^Fixture, text: string) {
	term.replay_write(f.session, transmute([]u8)text)
}

@(private = "file")
pixel_at :: proc(f: ^Fixture, pixels: []u8, column, row: int) -> [4]u8 {
	width := int(f.metrics.cell_width) * COLUMNS
	x := column * int(f.metrics.cell_width) + int(f.metrics.cell_width) / 2
	y := row * int(f.metrics.cell_height) + int(f.metrics.cell_height) / 2
	at := (y * width + x) * 4
	return {pixels[at], pixels[at + 1], pixels[at + 2], pixels[at + 3]}
}

@(private = "file")
BGRA_RED := [4]u8{0, 0, 255, 255}
@(private = "file")
BGRA_GREEN := [4]u8{0, 255, 0, 255}

@(test)
frames_without_images_add_no_layers :: proc(t: ^testing.T) {
	f, ok := headless_create(t)
	defer fixture_destroy(&f)
	if !ok {return}
	write(&f, "text")
	render_frame(t, &f, {family = f.family})
	testing.expect_value(t, len(f.list.layers), 1)
	testing.expect_value(t, len(f.list.images), 0)
}

@(test)
image_draws_where_the_terminal_placed_it :: proc(t: ^testing.T) {
	f, ok := headless_create(t)
	defer fixture_destroy(&f)
	if !ok {return}
	write(&f, "\x1b[2;3H")
	place(&f, 1, {255, 0, 0}, 2, 1)
	_, pixels := render_frame(t, &f, {family = f.family})
	testing.expect_value(t, pixel_at(&f, pixels, 2, 1), BGRA_RED)
	testing.expect_value(t, pixel_at(&f, pixels, 3, 1), BGRA_RED)
	testing.expect_value(t, pixel_at(&f, pixels, 1, 1), [4]u8{0, 0, 0, 255})
	testing.expect_value(t, pixel_at(&f, pixels, 4, 1), [4]u8{0, 0, 0, 255})
	testing.expect_value(t, pixel_at(&f, pixels, 2, 0), [4]u8{0, 0, 0, 255})
	testing.expect_value(t, pixel_at(&f, pixels, 2, 2), [4]u8{0, 0, 0, 255})
}

@(test)
z_decides_what_covers_the_cell_background :: proc(t: ^testing.T) {
	f, ok := headless_create(t)
	defer fixture_destroy(&f)
	if !ok {return}
	// A blue cell background on the first cell.
	write(&f, "\x1b[48;2;0;0;200m \x1b[0m\x1b[H")
	place(&f, 1, {255, 0, 0}, 1, 1, -1073741825)
	_, under := render_frame(t, &f, {family = f.family})
	testing.expect_value(t, pixel_at(&f, under, 0, 0), [4]u8{200, 0, 0, 255})
	place(&f, 2, {0, 255, 0}, 1, 1, -1)
	_, between := render_frame(t, &f, {family = f.family})
	testing.expect_value(t, pixel_at(&f, between, 0, 0), BGRA_GREEN)
}

@(test)
below_text_image_keeps_text_on_top_and_above_text_covers_it :: proc(t: ^testing.T) {
	f, ok := headless_create(t)
	defer fixture_destroy(&f)
	if !ok {return}
	// A full block fills the whole cell, so its colour is what the cell's middle shows.
	write(&f, "\x1b[38;2;255;255;255m█\x1b[0m\x1b[H")
	place(&f, 1, {255, 0, 0}, 1, 1, -1)
	_, below := render_frame(t, &f, {family = f.family})
	testing.expect_value(t, pixel_at(&f, below, 0, 0), [4]u8{255, 255, 255, 255})
	place(&f, 2, {0, 255, 0}, 1, 1, 1)
	_, above := render_frame(t, &f, {family = f.family})
	testing.expect_value(t, pixel_at(&f, above, 0, 0), BGRA_GREEN)
}

@(test)
decorations_stay_above_a_below_text_image :: proc(t: ^testing.T) {
	f, ok := headless_create(t)
	defer fixture_destroy(&f)
	if !ok {return}
	write(&f, "\x1b[38;2;255;255;255;4;9m  \x1b[0m\x1b[H")
	place(&f, 1, {255, 0, 0}, 2, 1, -1)
	_, pixels := render_frame(t, &f, {family = f.family})
	width := int(f.metrics.cell_width) * COLUMNS
	x := int(f.metrics.cell_width) / 2
	underline := int(f.metrics.baseline + f.metrics.underline_offset)
	strikethrough := int(f.metrics.baseline - f.metrics.strikethrough_offset)
	for y in ([?]int{underline, strikethrough}) {
		at := (y * width + x) * 4
		testing.expect_value(t, [4]u8{pixels[at], pixels[at + 1], pixels[at + 2], pixels[at + 3]}, [4]u8{255, 255, 255, 255})
	}
	testing.expect_value(t, pixel_at(&f, pixels, 0, 0), BGRA_RED)
}

@(test)
block_cursor_stays_above_a_below_text_image :: proc(t: ^testing.T) {
	f, ok := headless_create(t)
	defer fixture_destroy(&f)
	if !ok {return}
	place(&f, 1, {255, 0, 0}, 4, 1, -1)
	style := term_view.Style {
		family               = f.family,
		focused              = true,
		cursor_phase_visible = true,
	}
	_, pixels := render_frame(t, &f, style)
	testing.expect(t, pixel_at(&f, pixels, 0, 0) != BGRA_RED)
	testing.expect_value(t, pixel_at(&f, pixels, 1, 0), BGRA_RED)
}

@(test)
placement_is_trimmed_to_the_cells_with_its_source_kept_aligned :: proc(t: ^testing.T) {
	f, ok := headless_create(t)
	defer fixture_destroy(&f)
	if !ok {return}
	write(&f, "\x1b[1;20H")
	place(&f, 1, {255, 0, 0}, 2, 2)
	write(&f, "\x1b[4;1H\n")
	render_frame(t, &f, {family = f.family})
	if !testing.expect_value(t, len(f.list.images), 1) {return}
	image := f.list.images[0]
	m := f.metrics
	testing.expect_value(t, image.rect, render.Rect{19 * m.cell_width, 0, m.cell_width, m.cell_height})
	testing.expect_value(t, image.uv, render.Rect{0, 0.5, 0.5, 0.5})
}

@(test)
image_scrolls_with_the_text_and_is_clipped_by_the_pane :: proc(t: ^testing.T) {
	f, ok := headless_create(t)
	defer fixture_destroy(&f)
	if !ok {return}
	place(&f, 1, {255, 0, 0}, 2, 2)
	write(&f, "\x1b[4;1H\n")
	_, pixels := render_frame(t, &f, {family = f.family})
	testing.expect_value(t, pixel_at(&f, pixels, 0, 0), BGRA_RED)
	testing.expect_value(t, pixel_at(&f, pixels, 0, 1), [4]u8{0, 0, 0, 255})
}

@(test)
pixels_upload_once_until_the_image_changes :: proc(t: ^testing.T) {
	f, ok := headless_create(t)
	defer fixture_destroy(&f)
	if !ok {return}
	place(&f, 1, {255, 0, 0}, 2, 1)
	render_frame(t, &f, {family = f.family})
	key := f.list.images[0].key
	testing.expect(t, render.image_known(f.device, key))
	render_frame(t, &f, {family = f.family})
	testing.expect_value(t, f.list.images[0].key, key)
	write(&f, "\x1b[H")
	place(&f, 1, {0, 255, 0}, 2, 1)
	_, third := render_frame(t, &f, {family = f.family})
	testing.expect(t, f.list.images[0].key != key)
	testing.expect_value(t, pixel_at(&f, third, 0, 0), BGRA_GREEN)
}

// A list retained across frames must still show an evicted image, because the epoch forces a rebuild.
@(test)
evicted_texture_returns_on_the_next_build :: proc(t: ^testing.T) {
	f, ok := headless_create(t)
	defer fixture_destroy(&f)
	if !ok {return}
	place(&f, 1, {255, 0, 0}, 2, 1)
	render_frame(t, &f, {family = f.family})
	key := f.list.images[0].key
	f.device.image_budget = 0
	empty := render.draw_list_init()
	defer render.draw_list_destroy(&empty)
	testing.expect_value(t, render.frame_render(f.device, f.surface, &empty, {}), render.Error.None)
	testing.expect(t, !render.image_known(f.device, key))
	_, rebuilt := render_frame(t, &f, {family = f.family})
	testing.expect_value(t, pixel_at(&f, rebuilt, 0, 0), BGRA_RED)
}

@(test)
translated_origin_moves_the_image_with_the_cells :: proc(t: ^testing.T) {
	f, ok := headless_create(t)
	defer fixture_destroy(&f)
	if !ok {return}
	place(&f, 1, {255, 0, 0}, 1, 1)
	testing.expect_value(t, render.push_layer(&f.list, {0, 0, 4096, 4096}), render.Error.None)
	origin := [2]f32{f.metrics.cell_width, f.metrics.cell_height}
	frame, result := term_view.build(
		&f.view, f.session, f.fonts, &f.cache, &f.list, origin, f.metrics, {family = f.family},
	)
	testing.expect_value(t, result, render.Build_Status.Ok)
	testing.expect_value(t, render.frame_render(f.device, f.surface, &f.list, frame.background), render.Error.None)
	pixels, err := render.surface_read_pixels(f.device, f.surface, context.allocator)
	testing.expect_value(t, err, render.Error.None)
	defer delete(pixels)
	testing.expect_value(t, pixel_at(&f, pixels, 1, 1), BGRA_RED)
	testing.expect_value(t, pixel_at(&f, pixels, 0, 0), [4]u8{0, 0, 0, 255})
}
