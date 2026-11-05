package render_test

import "aio:render"
import "core:testing"

@(private = "file")
image :: proc(t: ^testing.T, f: ^Fixture, r: render.Rect, key: u64, uv := render.Rect{0, 0, 1, 1}) {
	testing.expect_value(t, render.push_image(&f.list, {rect = r, uv = uv, key = key}), render.Error.None)
}

// Four distinct RGBA corners: red, green, blue, white.
@(private = "file")
upload_corners :: proc(f: ^Fixture, key: u64) {
	pixels := [16]u8{255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255}
	render.image_upload(f.device, key, 2, 2, pixels[:])
}

@(test)
image_at_natural_size_reproduces_its_pixels_exactly :: proc(t: ^testing.T) {
	f, ok := fixture_create(t, 8, 8)
	if !ok {return}
	defer fixture_destroy(&f)
	upload_corners(&f, 1)
	testing.expect(t, render.image_known(f.device, 1))
	layer(t, &f.list, {0, 0, 8, 8})
	image(t, &f, {2, 3, 2, 2}, 1)
	pixels := render_pixels(t, &f, {0, 0, 0, 1})
	defer delete(pixels)
	// The surface is BGRA.
	expect_pixel(t, pixels, 8, 2, 3, {0, 0, 255, 255})
	expect_pixel(t, pixels, 8, 3, 3, {0, 255, 0, 255})
	expect_pixel(t, pixels, 8, 2, 4, {255, 0, 0, 255})
	expect_pixel(t, pixels, 8, 3, 4, {255, 255, 255, 255})
	expect_pixel(t, pixels, 8, 1, 3, {0, 0, 0, 255})
	expect_pixel(t, pixels, 8, 4, 4, {0, 0, 0, 255})
	expect_pixel(t, pixels, 8, 2, 2, {0, 0, 0, 255})
	expect_pixel(t, pixels, 8, 2, 5, {0, 0, 0, 255})
}

@(test)
image_scales_and_crops :: proc(t: ^testing.T) {
	f, ok := fixture_create(t, 40, 40)
	if !ok {return}
	defer fixture_destroy(&f)
	upload_corners(&f, 1)
	layer(t, &f.list, {0, 0, 40, 40})
	// Upscaled corner regions stay their own colour away from the blended middle.
	image(t, &f, {0, 0, 20, 20}, 1)
	// A crop of the top-right texel only, a colour the scaled copy cannot produce here.
	image(t, &f, {30, 30, 10, 10}, 1, {0.5, 0, 0.5, 0.5})
	pixels := render_pixels(t, &f, {0, 0, 0, 1})
	defer delete(pixels)
	expect_pixel(t, pixels, 40, 1, 1, {0, 0, 255, 255})
	expect_pixel(t, pixels, 40, 18, 1, {0, 255, 0, 255})
	expect_pixel(t, pixels, 40, 1, 18, {255, 0, 0, 255})
	expect_pixel(t, pixels, 40, 18, 18, {255, 255, 255, 255})
	// Bilinear sampling blends with the next texel inside a half-texel of the crop edge, so check its far corner.
	expect_pixel(t, pixels, 40, 38, 31, {0, 255, 0, 255})
}

@(test)
large_image_drawn_small_uses_its_mips :: proc(t: ^testing.T) {
	f, ok := fixture_create(t, 8, 8)
	if !ok {return}
	defer fixture_destroy(&f)
	// A checkerboard averages to mid gray only when minified through the mip chain.
	SIZE :: 64
	pixels := make([]u8, SIZE * SIZE * 4)
	defer delete(pixels)
	for y in 0 ..< SIZE {
		for x in 0 ..< SIZE {
			v := u8((x + y) % 2 == 0 ? 255 : 0)
			pixels[(y * SIZE + x) * 4 + 0] = v
			pixels[(y * SIZE + x) * 4 + 1] = v
			pixels[(y * SIZE + x) * 4 + 2] = v
			pixels[(y * SIZE + x) * 4 + 3] = 255
		}
	}
	render.image_upload(f.device, 1, SIZE, SIZE, pixels)
	layer(t, &f.list, {0, 0, 8, 8})
	image(t, &f, {0, 0, 8, 8}, 1)
	out := render_pixels(t, &f, {0, 0, 0, 1})
	defer delete(out)
	expect_pixel(t, out, 8, 4, 4, {128, 128, 128, 255}, 2)
}

@(test)
translucent_image_blends_over_what_is_behind_it :: proc(t: ^testing.T) {
	f, ok := fixture_create(t, 4, 4)
	if !ok {return}
	defer fixture_destroy(&f)
	// Premultiplied half-opaque red.
	pixel := [4]u8{128, 0, 0, 128}
	render.image_upload(f.device, 1, 1, 1, pixel[:])
	layer(t, &f.list, {0, 0, 4, 4})
	rect(t, &f.list, {rect = {0, 0, 4, 4}, color = {0, 0, 1, 1}})
	image(t, &f, {0, 0, 4, 4}, 1)
	pixels := render_pixels(t, &f, {0, 0, 0, 1})
	defer delete(pixels)
	expect_pixel(t, pixels, 4, 2, 2, {127, 0, 128, 255}, 1)
}

@(test)
a_layer_draws_rects_then_images_then_glyphs :: proc(t: ^testing.T) {
	f, ok := fixture_create(t, 6, 6)
	if !ok {return}
	defer fixture_destroy(&f)
	green := [4]u8{0, 255, 0, 255}
	render.image_upload(f.device, 1, 1, 1, green[:])
	slot, reserved := render.atlas_reserve(f.device, 1, 1, true)
	if !testing.expect(t, reserved) {return}
	blue := [4]u8{0, 0, 255, 255}
	render.atlas_upload(f.device, slot, blue[:], 1)
	layer(t, &f.list, {0, 0, 6, 6})
	// Pushed in reverse so the order proves the layer's rule, not the push order.
	glyph(t, &f.list, {
		rect = {0, 0, 2, 2},
		atlas = {f32(slot.x), f32(slot.y), 1, 1},
		color = {1, 1, 1, 1},
		flags = render.GLYPH_COLOR,
	})
	image(t, &f, {0, 0, 4, 4}, 1)
	rect(t, &f.list, {rect = {0, 0, 6, 6}, color = {1, 0, 0, 1}})
	pixels := render_pixels(t, &f, {0, 0, 0, 1})
	defer delete(pixels)
	expect_pixel(t, pixels, 6, 1, 1, {255, 0, 0, 255})
	expect_pixel(t, pixels, 6, 3, 3, {0, 255, 0, 255})
	expect_pixel(t, pixels, 6, 5, 5, {0, 0, 255, 255})
}

@(test)
image_respects_the_layer_clip :: proc(t: ^testing.T) {
	f, ok := fixture_create(t, 8, 8)
	if !ok {return}
	defer fixture_destroy(&f)
	white := [4]u8{255, 255, 255, 255}
	render.image_upload(f.device, 1, 1, 1, white[:])
	layer(t, &f.list, {2, 2, 4, 4})
	image(t, &f, {-4, -4, 20, 20}, 1)
	pixels := render_pixels(t, &f, {0, 0, 0, 1})
	defer delete(pixels)
	expect_pixel(t, pixels, 8, 3, 3, {255, 255, 255, 255})
	expect_pixel(t, pixels, 8, 1, 3, {0, 0, 0, 255})
	expect_pixel(t, pixels, 8, 6, 3, {0, 0, 0, 255})
}

@(test)
appended_list_keeps_each_layers_images :: proc(t: ^testing.T) {
	f, ok := fixture_create(t, 4, 4)
	if !ok {return}
	defer fixture_destroy(&f)
	red := [4]u8{255, 0, 0, 255}
	green := [4]u8{0, 255, 0, 255}
	render.image_upload(f.device, 1, 1, 1, red[:])
	render.image_upload(f.device, 2, 1, 1, green[:])
	source := render.draw_list_init()
	defer render.draw_list_destroy(&source)
	layer(t, &source, {0, 0, 4, 4})
	testing.expect_value(t, render.push_image(&source, {rect = {2, 0, 2, 4}, uv = {0, 0, 1, 1}, key = 2}), render.Error.None)
	layer(t, &f.list, {0, 0, 4, 4})
	image(t, &f, {0, 0, 2, 4}, 1)
	testing.expect_value(t, render.append_list(&f.list, &source), render.Error.None)
	pixels := render_pixels(t, &f, {0, 0, 0, 1})
	defer delete(pixels)
	expect_pixel(t, pixels, 4, 1, 1, {0, 0, 255, 255})
	expect_pixel(t, pixels, 4, 3, 1, {0, 255, 0, 255})
}

@(test)
unknown_image_key_draws_nothing :: proc(t: ^testing.T) {
	f, ok := fixture_create(t, 2, 2)
	if !ok {return}
	defer fixture_destroy(&f)
	layer(t, &f.list, {0, 0, 2, 2})
	image(t, &f, {0, 0, 2, 2}, 99)
	pixels := render_pixels(t, &f, {0, 0, 0, 1})
	defer delete(pixels)
	expect_pixel(t, pixels, 2, 1, 1, {0, 0, 0, 255})
	testing.expect(t, !render.image_known(f.device, 99))
}

@(test)
undrawn_texture_is_evicted_after_idle_frames_and_drawn_one_is_kept :: proc(t: ^testing.T) {
	f, ok := fixture_create(t, 2, 2)
	if !ok {return}
	defer fixture_destroy(&f)
	upload_corners(&f, 1)
	upload_corners(&f, 2)
	layer(t, &f.list, {0, 0, 2, 2})
	image(t, &f, {0, 0, 2, 2}, 2)
	epoch := render.image_epoch(f.device)
	for _ in 0 ..= render.IMAGE_IDLE_FRAMES + 1 {
		testing.expect_value(t, render.frame_render(f.device, f.surface, &f.list, {}), render.Error.None)
	}
	testing.expect(t, !render.image_known(f.device, 1))
	testing.expect(t, render.image_known(f.device, 2))
	testing.expect(t, render.image_epoch(f.device) != epoch)
}

@(test)
budget_evicts_undrawn_textures_oldest_first_but_never_a_drawn_one :: proc(t: ^testing.T) {
	f, ok := fixture_create(t, 2, 2)
	if !ok {return}
	defer fixture_destroy(&f)
	// A frame between uploads gives each texture its own age.
	empty := render.draw_list_init()
	defer render.draw_list_destroy(&empty)
	upload_corners(&f, 1)
	testing.expect_value(t, render.frame_render(f.device, f.surface, &empty, {}), render.Error.None)
	upload_corners(&f, 2)
	testing.expect_value(t, render.frame_render(f.device, f.surface, &empty, {}), render.Error.None)
	upload_corners(&f, 3)
	// Each 2x2 texture counts as 21 bytes, so this holds two.
	f.device.image_budget = 45
	layer(t, &f.list, {0, 0, 2, 2})
	image(t, &f, {0, 0, 2, 2}, 3)
	testing.expect_value(t, render.frame_render(f.device, f.surface, &f.list, {}), render.Error.None)
	testing.expect(t, !render.image_known(f.device, 1))
	testing.expect(t, render.image_known(f.device, 2))
	testing.expect(t, render.image_known(f.device, 3))
	// A drawn texture survives even when it alone is over budget.
	f.device.image_budget = 1
	testing.expect_value(t, render.frame_render(f.device, f.surface, &f.list, {}), render.Error.None)
	testing.expect(t, !render.image_known(f.device, 2))
	testing.expect(t, render.image_known(f.device, 3))
}

// An image wider than the GPU allows is refused once, so the frame neither retries nor fails.
@(test)
image_too_large_for_a_texture_is_settled_and_draws_nothing :: proc(t: ^testing.T) {
	f, ok := fixture_create(t, 2, 2)
	if !ok {return}
	defer fixture_destroy(&f)
	context.logger = {}
	WIDTH :: 16385
	pixels := make([]u8, WIDTH * 4)
	defer delete(pixels)
	render.image_upload(f.device, 1, WIDTH, 1, pixels)
	testing.expect(t, render.image_known(f.device, 1))
	layer(t, &f.list, {0, 0, 2, 2})
	image(t, &f, {0, 0, 2, 2}, 1)
	out := render_pixels(t, &f, {0, 0, 0, 1})
	defer delete(out)
	expect_pixel(t, out, 2, 1, 1, {0, 0, 0, 255})
}
