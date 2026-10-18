package render_test

import "base:runtime"
import "core:math"
import "core:testing"
import "aio:render"

Fixture :: struct {
	device: ^render.Device,
	surface: ^render.Surface,
	list: render.Draw_List,
}

fixture_create :: proc(t: ^testing.T, width, height: i32) -> (f: Fixture, ok: bool) {
	err: render.Error
	f.device, err = render.device_create()
	if !testing.expect_value(t, err, render.Error.None) {
		return
	}
	f.surface, err = render.surface_create_offscreen(f.device, width, height)
	if !testing.expect_value(t, err, render.Error.None) {
		render.device_destroy(f.device)
		return
	}
	f.list = render.draw_list_init()
	return f, true
}

fixture_destroy :: proc(f: ^Fixture) {
	render.draw_list_destroy(&f.list)
	render.surface_destroy(f.surface)
	render.device_destroy(f.device)
}

render_pixels :: proc(t: ^testing.T, f: ^Fixture, clear: render.Color = {}) -> []u8 {
	testing.expect_value(t, render.frame_render(f.device, f.surface, &f.list, clear), render.Error.None)
	pixels, err := render.surface_read_pixels(f.device, f.surface, context.allocator)
	testing.expect_value(t, err, render.Error.None)
	return pixels
}

layer :: proc(t: ^testing.T, list: ^render.Draw_List, clip: render.Rect) {
	testing.expect_value(t, render.push_layer(list, clip), render.Error.None)
}

rect :: proc(t: ^testing.T, list: ^render.Draw_List, instance: render.Rect_Instance) {
	testing.expect_value(t, render.push_rect(list, instance), render.Error.None)
}

glyph :: proc(t: ^testing.T, list: ^render.Draw_List, instance: render.Glyph_Instance) {
	testing.expect_value(t, render.push_glyph(list, instance), render.Error.None)
}

expect_pixel :: proc(t: ^testing.T, pixels: []u8, width, x, y: int, expected: [4]u8, tolerance := 0) {
	index := (y * width + x) * 4
	if !testing.expect(t, index + 4 <= len(pixels)) {
		return
	}
	for channel in 0 ..< 4 {
		actual := int(pixels[index + channel])
		testing.expectf(
			t, abs(actual - int(expected[channel])) <= tolerance,
			"pixel (%d,%d) channel %d: got %d, expected %d +/- %d",
			x, y, channel, actual, expected[channel], tolerance,
		)
	}
}

failing_allocator :: proc(
	data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	location: runtime.Source_Code_Location,
) -> ([]u8, runtime.Allocator_Error) {
	return nil, .Out_Of_Memory
}

@(test)
draw_list_reuse :: proc(t: ^testing.T) {
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	for frame in 0 ..< 2 {
		for index in 0 ..< 3 {
			layer(t, &list, {f32(index), 0, 32, 32})
			for i in 0 ..< 100 {
				rect(t, &list, {rect = {f32(i), f32(frame), 1, 1}})
				glyph(t, &list, {rect = {f32(i), 0, 1, 1}})
			}
			testing.expect_value(t, list.layers[index].rect_start, index * 100)
			testing.expect_value(t, list.layers[index].glyph_start, index * 100)
			testing.expect_value(t, list.layers[index].rect_count, 100)
			testing.expect_value(t, list.layers[index].glyph_count, 100)
		}
		rects, glyphs := raw_data(list.rects), raw_data(list.glyphs)
		render.draw_list_reset(&list)
		testing.expect_value(t, len(list.layers) + len(list.rects) + len(list.glyphs), 0)
		testing.expect_value(t, raw_data(list.rects), rects)
		testing.expect_value(t, raw_data(list.glyphs), glyphs)
	}
}

@(test)
allocation_errors :: proc(t: ^testing.T) {
	failing := runtime.Allocator{procedure = failing_allocator}
	d, err := render.device_create(failing)
	testing.expect_value(t, err, render.Error.Out_Of_Memory)
	testing.expect_value(t, d, nil)
	list := render.draw_list_init(failing)
	defer render.draw_list_destroy(&list)
	testing.expect_value(t, render.push_layer(&list, {}), render.Error.Out_Of_Memory)
	allocated := render.draw_list_init()
	defer render.draw_list_destroy(&allocated)
	layer(t, &allocated, {})
	allocated.rects.allocator = failing
	allocated.glyphs.allocator = failing
	testing.expect_value(t, render.push_rect(&allocated, {}), render.Error.Out_Of_Memory)
	testing.expect_value(t, render.push_glyph(&allocated, {}), render.Error.Out_Of_Memory)
	testing.expect_value(t, allocated.layers[0].rect_count + allocated.layers[0].glyph_count, 0)
}

@(test)
solid_rects_and_blending :: proc(t: ^testing.T) {
	f, ok := fixture_create(t, 32, 32)
	if !ok {
		return
	}
	defer fixture_destroy(&f)
	layer(t, &f.list, {0, 0, 32, 32})
	rect(t, &f.list, {rect = {2, 3, 8, 7}, color = {1, 0.5, 0.25, 1}})
	rect(t, &f.list, {rect = {12, 3, 8, 7}, color = {1, 0, 0, 0.5}})
	pixels := render_pixels(t, &f)
	defer delete(pixels)
	for y in 0 ..< 32 {
		for x in 0 ..< 32 {
			expected: [4]u8
			if x >= 2 && x < 10 && y >= 3 && y < 10 { expected = {64, 128, 255, 255} }
			if x >= 12 && x < 20 && y >= 3 && y < 10 { expected = {0, 0, 128, 128} }
			expect_pixel(t, pixels, 32, x, y, expected, 1)
		}
	}
	blended := render_pixels(t, &f, {0, 0, 1, 1})
	defer delete(blended)
	expect_pixel(t, blended, 32, 13, 4, {127, 0, 128, 255}, 1)
}

@(test)
rounded_rect_and_shadow :: proc(t: ^testing.T) {
	f, ok := fixture_create(t, 32, 32)
	if !ok {
		return
	}
	defer fixture_destroy(&f)
	layer(t, &f.list, {0, 0, 32, 32})
	rect(t, &f.list, {rect = {4, 4, 16, 16}, color = {1, 1, 1, 1}, radius = 8})
	rounded := render_pixels(t, &f)
	defer delete(rounded)
	expect_pixel(t, rounded, 32, 4, 4, {})
	expect_pixel(t, rounded, 32, 12, 12, {255, 255, 255, 255})
	expect_pixel(t, rounded, 32, 7, 5, {151, 151, 151, 151}, 2)
	render.draw_list_reset(&f.list)
	layer(t, &f.list, {0, 0, 32, 32})
	rect(t, &f.list, {rect = {8, 8, 8, 8}, color = {1, 1, 1, 1}, softness = 4})
	shadow := render_pixels(t, &f)
	defer delete(shadow)
	expect_pixel(t, shadow, 32, 6, 12, {80, 80, 80, 80}, 1)
	expect_pixel(t, shadow, 32, 8, 12, {143, 143, 143, 143}, 1)
	expect_pixel(t, shadow, 32, 3, 12, {})
}

@(test)
layer_order_and_clipping :: proc(t: ^testing.T) {
	f, ok := fixture_create(t, 16, 16)
	if !ok {
		return
	}
	defer fixture_destroy(&f)
	slot, reserved := render.atlas_reserve(f.device, 1, 1)
	if !testing.expect(t, reserved) {
		return
	}
	render.atlas_upload(f.device, slot, {255}, 1)
	layer(t, &f.list, {0, 0, 16, 16})
	glyph(t, &f.list, {rect = {0, 0, 16, 16}, atlas = {f32(slot.x), f32(slot.y), 0, 0}, color = {0, 1, 0, 1}})
	rect(t, &f.list, {rect = {0, 0, 16, 16}, color = {1, 0, 0, 1}})
	layer(t, &f.list, {4, 4, 8, 8})
	rect(t, &f.list, {rect = {0, 0, 16, 16}, color = {0, 0, 1, 1}})
	layer(t, &f.list, {30, 30, 2, 2})
	rect(t, &f.list, {rect = {0, 0, 16, 16}, color = {1, 1, 1, 1}})
	pixels := render_pixels(t, &f)
	defer delete(pixels)
	for y in 0 ..< 16 {
		for x in 0 ..< 16 {
			expected := [4]u8{0, 255, 0, 255}
			if x >= 4 && x < 12 && y >= 4 && y < 12 { expected = {255, 0, 0, 255} }
			expect_pixel(t, pixels, 16, x, y, expected)
		}
	}
}

reference_glyph_alpha :: proc(coverage: f32, foreground: [3]f32, gamma: render.Text_Gamma) -> f32 {
	g := render.gamma_ratios(gamma.gamma)
	luminance := foreground.r * 0.30 + foreground.g * 0.59 + foreground.b * 0.11
	k := gamma.enhanced_contrast * clamp(1 - luminance * 4.0 / 3.0, 0, 1)
	a := coverage * (k + 1) / (coverage * k + 1)
	intensity := foreground.r * 0.25 + foreground.g * 0.5 + foreground.b * 0.25
	return clamp(a + a * (1 - a) * ((g[0] * intensity + g[1]) * a + (g[2] * intensity + g[3])), 0, 1)
}

@(test)
gamma_ratios_match_directwrite :: proc(t: ^testing.T) {
	testing.expect_value(t, render.gamma_ratios(1.0), [4]f32{})
	ratios := render.gamma_ratios(1.8)
	norm13 := f32(f64(0x10000) / (255 * 255))
	norm24 := f32(f64(0x100) / 255)
	expected := [4]f32{norm13 * 0.1469, norm24 * -0.8911, norm13 * 1.4644, norm24 * -0.3234}
	for value, i in ratios {
		testing.expectf(t, abs(value - expected[i]) < 1e-6, "ratio %d: %v vs %v", i, value, expected[i])
	}
	testing.expect_value(t, render.gamma_ratios(9), render.gamma_ratios(2.2))
	testing.expect_value(t, render.gamma_ratios(0), render.gamma_ratios(1))
}

@(test)
glyph_coverage_and_gamma :: proc(t: ^testing.T) {
	f, ok := fixture_create(t, 4, 2)
	if !ok {
		return
	}
	defer fixture_destroy(&f)
	slot, reserved := render.atlas_reserve(f.device, 4, 2)
	if !testing.expect(t, reserved) {
		return
	}
	coverage := [?]u8{0, 64, 128, 255, 99, 99, 255, 128, 64, 0}
	render.atlas_upload(f.device, slot, coverage[:], 6)
	Sample :: struct {
		gamma: render.Text_Gamma,
		foreground: [3]f32,
	}
	samples := [?]Sample{
		{{1, 0}, {1, 1, 1}},
		{{1.8, 1}, {1, 1, 1}},
		{{1.8, 1}, {0, 0, 0}},
		{{2.2, 0.5}, {0.2, 0.4, 0.8}},
	}
	for sample in samples {
		render.draw_list_reset(&f.list)
		layer(t, &f.list, {0, 0, 4, 2})
		fg := sample.foreground
		glyph(t, &f.list, {rect = {0, 0, 4, 2}, atlas = {f32(slot.x), f32(slot.y), 4, 2}, color = {fg.r, fg.g, fg.b, 1}})
		render.set_text_gamma(f.device, sample.gamma)
		pixels := render_pixels(t, &f)
		defer delete(pixels)
		for y in 0 ..< 2 {
			for x in 0 ..< 4 {
				a := reference_glyph_alpha(f32(coverage[y * 6 + x]) / 255, fg, sample.gamma)
				expected := [4]u8{
					u8(math.round(fg.b * a * 255)),
					u8(math.round(fg.g * a * 255)),
					u8(math.round(fg.r * a * 255)),
					u8(math.round(a * 255)),
				}
				expect_pixel(t, pixels, 4, x, y, expected, 1)
			}
		}
	}
}

@(test)
atlas_growth_and_reset :: proc(t: ^testing.T) {
	f, ok := fixture_create(t, 1, 1)
	if !ok {
		return
	}
	defer fixture_destroy(&f)
	d := f.device
	generation := render.atlas_generation(d)
	first, first_ok := render.atlas_reserve(d, 1, 1)
	if !testing.expect(t, first_ok) {
		return
	}
	render.atlas_upload(d, first, {255}, 1)
	large, large_ok := render.atlas_reserve(d, 4096, 2048)
	if !testing.expect(t, large_ok) {
		return
	}
	testing.expect_value(t, large.y, 1)
	last, last_ok := render.atlas_reserve(d, 4096, 2047)
	testing.expect(t, last_ok)
	testing.expect_value(t, last.y, 2049)
	_, full := render.atlas_reserve(d, 1, 1)
	testing.expect(t, !full)
	_, oversized := render.atlas_reserve(d, 4097, 1)
	testing.expect(t, !oversized)
	testing.expect_value(t, render.atlas_generation(d), generation)
	layer(t, &f.list, {0, 0, 1, 1})
	glyph(t, &f.list, {rect = {0, 0, 1, 1}, atlas = {0, 0, 1, 1}, color = {1, 1, 1, 1}})
	render.set_text_gamma(d, {1, 0})
	pixels := render_pixels(t, &f)
	defer delete(pixels)
	expect_pixel(t, pixels, 1, 0, 0, {255, 255, 255, 255})
	render.atlas_reset(d)
	testing.expect_value(t, render.atlas_generation(d), generation + 1)
	whole, whole_ok := render.atlas_reserve(d, 4096, 4096)
	testing.expect(t, whole_ok)
	testing.expect_value(t, whole.x + whole.y, 0)
}

// Color glyphs sample the RGBA atlas as premultiplied color: the instance tint is ignored and its
// alpha only fades the glyph. The two atlases allocate independently and reset together.
@(test)
color_atlas_glyphs :: proc(t: ^testing.T) {
	f, ok := fixture_create(t, 2, 2)
	if !ok {
		return
	}
	defer fixture_destroy(&f)
	d := f.device
	coverage, coverage_ok := render.atlas_reserve(d, 3, 1)
	color, color_ok := render.atlas_reserve(d, 2, 1, true)
	if !testing.expect(t, coverage_ok && color_ok) {
		return
	}
	testing.expect(t, color.color && !coverage.color)
	testing.expect_value(t, color.x, 0)
	render.atlas_upload(d, color, {255, 0, 0, 255, 0, 128, 0, 128}, 2)
	atlas := render.Rect{f32(color.x), f32(color.y), 2, 1}
	layer(t, &f.list, {0, 0, 2, 2})
	glyph(t, &f.list, {rect = {0, 0, 2, 1}, atlas = atlas, color = {0, 0, 1, 1}, flags = render.GLYPH_COLOR})
	glyph(t, &f.list, {rect = {0, 1, 2, 1}, atlas = atlas, color = {0, 0, 1, 0.5}, flags = render.GLYPH_COLOR})
	// Surfaces read back as BGRA.
	pixels := render_pixels(t, &f, {0, 0, 0, 1})
	defer delete(pixels)
	expect_pixel(t, pixels, 2, 0, 0, {0, 0, 255, 255}, 1)
	expect_pixel(t, pixels, 2, 1, 0, {0, 128, 0, 255}, 1)
	expect_pixel(t, pixels, 2, 0, 1, {0, 0, 128, 255}, 1)
	expect_pixel(t, pixels, 2, 1, 1, {0, 64, 0, 255}, 1)
	generation := render.atlas_generation(d)
	render.atlas_reset(d)
	testing.expect_value(t, render.atlas_generation(d), generation + 1)
	again, again_ok := render.atlas_reserve(d, 1, 1, true)
	testing.expect(t, again_ok)
	testing.expect_value(t, again.x + again.y, 0)
}

@(test)
surface_resize_and_errors :: proc(t: ^testing.T) {
	f, ok := fixture_create(t, 3, 2)
	if !ok {
		return
	}
	defer fixture_destroy(&f)
	for size in ([?][2]i32{{0, 1}, {1, -1}, {16385, 1}}) {
		s, err := render.surface_create_offscreen(f.device, size[0], size[1])
		testing.expect_value(t, err, render.Error.Invalid_Argument)
		testing.expect_value(t, s, nil)
	}
	testing.expect_value(t, render.frame_wait(f.surface, 0), render.Error.None)
	testing.expect_value(t, render.surface_resize(f.device, f.surface, 0, 1), render.Error.Invalid_Argument)
	testing.expect_value(t, render.surface_resize(f.device, f.surface, 7, 5), render.Error.None)
	pixels := render_pixels(t, &f, {0, 0.5, 0, 0.5})
	defer delete(pixels)
	testing.expect_value(t, len(pixels), 7 * 5 * 4)
	expect_pixel(t, pixels, 7, 6, 4, {0, 64, 0, 128}, 1)
	failing := runtime.Allocator{procedure = failing_allocator}
	_, allocation_error := render.surface_read_pixels(f.device, f.surface, failing)
	testing.expect_value(t, allocation_error, render.Error.Out_Of_Memory)
}

@(test)
instance_buffer_growth_and_reuse :: proc(t: ^testing.T) {
	WIDTH :: 700
	f, ok := fixture_create(t, WIDTH, 2)
	if !ok {
		return
	}
	defer fixture_destroy(&f)
	slot, reserved := render.atlas_reserve(f.device, 1, 1)
	if !testing.expect(t, reserved) {
		return
	}
	render.atlas_upload(f.device, slot, {255}, 1)
	render.set_text_gamma(f.device, {1, 0})
	for count in ([?]int{1, 300, WIDTH, 1}) {
		render.draw_list_reset(&f.list)
		layer(t, &f.list, {0, 0, WIDTH, 2})
		for i in 0 ..< count {
			color := i % 2 == 0 ? render.Color{1, 0, 0, 1} : render.Color{0, 0, 1, 1}
			rect(t, &f.list, {rect = {f32(i), 0, 1, 1}, color = color})
			glyph(t, &f.list, {rect = {f32(i), 1, 1, 1}, atlas = {f32(slot.x), f32(slot.y), 0, 0}, color = color})
		}
		pixels := render_pixels(t, &f)
		defer delete(pixels)
		for x in 0 ..< WIDTH {
			expected: [4]u8
			if x < count {
				expected = x % 2 == 0 ? {0, 0, 255, 255} : {255, 0, 0, 255}
			}
			expect_pixel(t, pixels, WIDTH, x, 0, expected)
			expect_pixel(t, pixels, WIDTH, x, 1, expected)
		}
	}
}

@(test)
appended_lists_preserve_layers_and_rebase_instances :: proc(t: ^testing.T) {
	source := render.draw_list_init()
	defer render.draw_list_destroy(&source)
	out := render.draw_list_init()
	defer render.draw_list_destroy(&out)
	testing.expect_value(t, render.push_layer(&source, {1, 2, 3, 4}), render.Error.None)
	testing.expect_value(t, render.push_rect(&source, {rect = {1, 2, 1, 1}}), render.Error.None)
	testing.expect_value(t, render.push_glyph(&source, {rect = {2, 3, 1, 1}}), render.Error.None)
	testing.expect_value(t, render.push_layer(&source, {5, 6, 7, 8}), render.Error.None)
	testing.expect_value(t, render.push_glyph(&source, {rect = {5, 6, 1, 1}}), render.Error.None)
	testing.expect_value(t, render.append_list(&out, &source), render.Error.None)
	testing.expect_value(t, render.append_list(&out, &source), render.Error.None)
	testing.expect_value(t, len(out.layers), 4)
	testing.expect_value(t, len(out.rects), 2)
	testing.expect_value(t, len(out.glyphs), 4)
	testing.expect_value(t, out.layers[2].rect_start, 1)
	testing.expect_value(t, out.layers[2].glyph_start, 2)
	testing.expect_value(t, out.layers[3].glyph_start, 3)
	testing.expect_value(t, out.layers[2].clip, source.layers[0].clip)
	testing.expect_value(t, source.layers[0].glyph_start, 0)
	testing.expect_value(t, out.glyphs[3], source.glyphs[1])
}

@(test)
rounded_layers_clip_content_and_outline_has_no_fill :: proc(t: ^testing.T) {
	f, ok := fixture_create(t, 32, 32)
	if !ok { return }
	defer fixture_destroy(&f)
	testing.expect_value(t, render.push_layer(&f.list, {0, 0, 32, 32}, 7), render.Error.None)
	rect(t, &f.list, {rect = {0, 0, 32, 32}, color = {1, 0, 0, 1}})
	pixels := render_pixels(t, &f)
	defer delete(pixels)
	expect_pixel(t, pixels, 32, 0, 0, {0, 0, 0, 0})
	expect_pixel(t, pixels, 32, 16, 16, {0, 0, 255, 255})
	render.draw_list_reset(&f.list)
	layer(t, &f.list, {0, 0, 32, 32})
	rect(t, &f.list, {rect = {2, 2, 28, 28}, radius = 7, stroke = 2, color = {0, 1, 0, 1}})
	outline := render_pixels(t, &f)
	defer delete(outline)
	expect_pixel(t, outline, 32, 16, 16, {0, 0, 0, 0})
	expect_pixel(t, outline, 32, 16, 3, {0, 255, 0, 255})
}
