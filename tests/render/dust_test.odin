package render_test

import "aio:render"
import "core:testing"

@(private = "file")
DUST_KEY :: render.IMAGE_KEY_RENDERED | 1

// Renders an opaque size x size square, red on the left half and blue on the right, into DUST_KEY.
@(private = "file")
dust_source :: proc(t: ^testing.T, f: ^Fixture, size: f32) -> bool {
	source := render.draw_list_init()
	defer render.draw_list_destroy(&source)
	layer(t, &source, {0, 0, size, size})
	rect(t, &source, {rect = {0, 0, size / 2, size}, color = {1, 0, 0, 1}})
	rect(t, &source, {rect = {size / 2, 0, size / 2, size}, color = {0, 0, 1, 1}})
	err := render.image_render(f.device, DUST_KEY, int(size), int(size), &source)
	return testing.expect_value(t, err, render.Error.None)
}

@(private = "file")
dust_draw :: proc(t: ^testing.T, f: ^Fixture, r: render.Rect, progress: f32) -> []u8 {
	render.draw_list_reset(&f.list)
	layer(t, &f.list, {0, 0, f32(f.surface.width), f32(f.surface.height)})
	dust := render.Dust{progress = progress, seed = 0.3, rise = 40, grain = 1, ash = {0.8, 0.78, 0.7, 1}}
	err := render.push_image(&f.list, {rect = r, uv = {0, 0, 1, 1}, key = DUST_KEY, dust = dust})
	testing.expect_value(t, err, render.Error.None)
	return render_pixels(t, f)
}

// How many pixels in the w x h area at (x, y) are drawn at all.
@(private = "file")
drawn :: proc(pixels: []u8, width, x, y, w, h: int) -> int {
	count := 0
	for row in y ..< y + h {
		for column in x ..< x + w {
			if pixels[(row * width + column) * 4 + 3] > 0 {count += 1}
		}
	}
	return count
}

// A list drawn into a texture shows as the same pixels when the texture is drawn back at its size.
@(test)
rendered_image_shows_what_its_list_drew :: proc(t: ^testing.T) {
	f, ok := fixture_create(t, 16, 16)
	if !ok {return}
	defer fixture_destroy(&f)
	if !dust_source(t, &f, 8) {return}
	layer(t, &f.list, {0, 0, 16, 16})
	testing.expect_value(t, render.push_image(&f.list, {rect = {4, 4, 8, 8}, uv = {0, 0, 1, 1}, key = DUST_KEY}), render.Error.None)
	pixels := render_pixels(t, &f, {0, 0, 0, 1})
	defer delete(pixels)
	// The surface is BGRA.
	expect_pixel(t, pixels, 16, 5, 6, {0, 0, 255, 255})
	expect_pixel(t, pixels, 16, 10, 6, {255, 0, 0, 255})
	expect_pixel(t, pixels, 16, 3, 6, {0, 0, 0, 255})
}

// Dust that has barely begun is the image, grain for grain, and dust at progress 1 has all gone.
@(test)
dust_starts_as_the_image_and_ends_as_nothing :: proc(t: ^testing.T) {
	f, ok := fixture_create(t, 64, 64)
	if !ok {return}
	defer fixture_destroy(&f)
	if !dust_source(t, &f, 32) {return}
	start := dust_draw(t, &f, {16, 24, 32, 32}, 0.0001)
	defer delete(start)
	testing.expect_value(t, drawn(start, 64, 0, 0, 64, 64), 32 * 32)
	expect_pixel(t, start, 64, 18, 30, {0, 0, 255, 255})
	expect_pixel(t, start, 64, 46, 30, {255, 0, 0, 255})
	end := dust_draw(t, &f, {16, 24, 32, 32}, 1)
	defer delete(end)
	testing.expect_value(t, drawn(end, 64, 0, 0, 64, 64), 0)
}

// Midway the bottom left has crumbled further than the top right, and the dust has risen above the image.
@(test)
dust_crumbles_from_the_bottom_left_and_rises :: proc(t: ^testing.T) {
	f, ok := fixture_create(t, 64, 96)
	if !ok {return}
	defer fixture_destroy(&f)
	if !dust_source(t, &f, 32) {return}
	pixels := dust_draw(t, &f, {16, 56, 32, 32}, 0.35)
	defer delete(pixels)
	bottom_left := drawn(pixels, 64, 16, 72, 16, 16)
	top_right := drawn(pixels, 64, 32, 56, 16, 16)
	testing.expectf(t, bottom_left < top_right, "bottom left keeps %d pixels, top right %d", bottom_left, top_right)
	testing.expect(t, drawn(pixels, 64, 0, 0, 64, 56) > 0, "dust rises above the image")
}
