package font_test

import "base:runtime"

import "core:math"
import "core:mem"
import "core:slice"
import "core:testing"
import "aio:font"

@(test)
load_families_and_metrics :: proc(t: ^testing.T) {
	s, err := font.system_create()
	if !testing.expect_value(t, err, font.Error.None) {
		return
	}
	defer font.system_destroy(s)
	for name in ([]string{"Consolas", "Cascadia Mono", "Segoe UI"}) {
		family, load_err := font.family_load(s, name)
		if !testing.expect_value(t, load_err, font.Error.None) {
			continue
		}
		for style in font.Style {
			m := font.face_metrics(s, family.faces[style], 20)
			testing.expect(t, m.ascent > 0 && m.descent > 0 && m.cap_height > 0)
			testing.expect(t, m.underline_position < 0 && m.underline_thickness > 0)
			testing.expect(t, m.strikethrough_position > 0 && m.strikethrough_thickness > 0)
			double := font.face_metrics(s, family.faces[style], 40)
			testing.expect_value(t, double.ascent, m.ascent * 2)
		}
		again, again_err := font.family_load(s, name)
		testing.expect_value(t, again_err, font.Error.None)
		testing.expect_value(t, again, family)
	}
	gamma := font.text_gamma(s)
	testing.expect(t, gamma.gamma > 0 && gamma.gamma <= 256)
	testing.expect(t, gamma.enhanced_contrast >= 0)
	_, err = font.family_load(s, "AIODev deliberately nonexistent family 7FA83")
	testing.expect_value(t, err, font.Error.Family_Not_Found)
}

@(test)
rasterization_and_bearings :: proc(t: ^testing.T) {
	s, err := font.system_create()
	if !testing.expect_value(t, err, font.Error.None) {
		return
	}
	defer font.system_destroy(s)
	family, load_err := font.family_load(s, "Consolas")
	if !testing.expect_value(t, load_err, font.Error.None) {
		return
	}
	regular, found := font.glyph_lookup(s, family, .Regular, 'A')
	if !testing.expect(t, found) {
		return
	}
	bitmap, raster_err := font.glyph_rasterize(s, regular, 24, context.allocator)
	defer font.bitmap_destroy(&bitmap, context.allocator)
	if !testing.expect_value(t, raster_err, font.Error.None) {
		return
	}
	testing.expect(t, bitmap.width > 0 && bitmap.height > 0 && bitmap.top > 0)
	testing.expect_value(t, len(bitmap.pixels), int(bitmap.width * bitmap.height))
	coverage := 0
	for p in bitmap.pixels {
		coverage += int(p)
	}
	testing.expect(t, coverage > 0)
	testing.expect(t, bitmap.top <= i32(math.ceil(font.face_metrics(s, regular.face, 24).ascent)))
	bold, bold_found := font.glyph_lookup(s, family, .Bold, 'A')
	if !testing.expect(t, bold_found) {
		return
	}
	bold_bitmap, bold_err := font.glyph_rasterize(s, bold, 24, context.allocator)
	defer font.bitmap_destroy(&bold_bitmap, context.allocator)
	testing.expect_value(t, bold_err, font.Error.None)
	testing.expect(t, regular.face != bold.face)
	testing.expect(t, bitmap.width != bold_bitmap.width || bitmap.height != bold_bitmap.height ||
	                  !slice.equal(bitmap.pixels, bold_bitmap.pixels))
	space, space_found := font.glyph_lookup(s, family, .Regular, ' ')
	if !testing.expect(t, space_found) {
		return
	}
	empty, space_err := font.glyph_rasterize(s, space, 24, context.allocator)
	defer font.bitmap_destroy(&empty, context.allocator)
	testing.expect_value(t, space_err, font.Error.None)
	testing.expect_value(t, len(empty.pixels), 0)
	for style in font.Style {
		g, ok := font.glyph_lookup(s, family, style, 'j')
		if !testing.expect(t, ok) {
			continue
		}
		b, e := font.glyph_rasterize(s, g, 24, context.allocator)
		testing.expect_value(t, e, font.Error.None)
		testing.expect(t, b.height > b.top)
		font.bitmap_destroy(&b, context.allocator)
	}
}

@(test)
fallback_cache_and_advances :: proc(t: ^testing.T) {
	s, err := font.system_create()
	if !testing.expect_value(t, err, font.Error.None) {
		return
	}
	defer font.system_destroy(s)
	family, load_err := font.family_load(s, "Consolas")
	if !testing.expect_value(t, load_err, font.Error.None) {
		return
	}
	for style in font.Style {
		for r in ([]rune{'漢', '😀'}) {
			glyph, found := font.glyph_lookup(s, family, style, r)
			if !testing.expect(t, found) {
				continue
			}
			testing.expect(t, glyph.face != family.faces[style])
			bitmap, raster_err := font.glyph_rasterize(s, glyph, 24, context.allocator)
			testing.expect_value(t, raster_err, font.Error.None)
			testing.expect(t, len(bitmap.pixels) > 0)
			font.bitmap_destroy(&bitmap, context.allocator)
			for _ in 0..<8 {
				again, ok := font.glyph_lookup(s, family, style, r)
				testing.expect(t, ok)
				testing.expect_value(t, again, glyph)
			}
		}
		first, found := font.glyph_lookup(s, family, style, 'i')
		if !testing.expect(t, found) {
			continue
		}
		advance := font.glyph_advance(s, first, 19)
		testing.expect(t, advance > 0)
		for r in ([]rune{'W', '0', ' '}) {
			glyph, ok := font.glyph_lookup(s, family, style, r)
			testing.expect(t, ok)
			testing.expect_value(t, font.glyph_advance(s, glyph, 19), advance)
		}
	}
	first, first_ok := font.glyph_lookup(s, family, .Regular, '漢')
	second, second_ok := font.glyph_lookup(s, family, .Regular, '字')
	testing.expect(t, first_ok && second_ok)
	testing.expect_value(t, first.face, second.face)
	for _ in 0..<2 {
		_, found := font.glyph_lookup(s, family, .Regular, rune(0x10ffff))
		testing.expect(t, !found)
	}
}

@(test)
invalid_arguments_and_allocation_failure :: proc(t: ^testing.T) {
	font.system_destroy(nil)
	s, err := font.system_create(mem.nil_allocator())
	testing.expect_value(t, err, font.Error.Out_Of_Memory)
	testing.expect(t, s == nil)
	s, err = font.system_create()
	if !testing.expect_value(t, err, font.Error.None) {
		return
	}
	defer font.system_destroy(s)
	for name in ([]string{"", "Con\x00solas", "\xff"}) {
		_, e := font.family_load(s, name)
		testing.expect_value(t, e, font.Error.Invalid_Argument)
	}
	family, load_err := font.family_load(s, "Consolas")
	if !testing.expect_value(t, load_err, font.Error.None) {
		return
	}
	glyph, found := font.glyph_lookup(s, family, .Regular, 'A')
	if !testing.expect(t, found) {
		return
	}
	for size in ([]f32{0, -1, math.INF_F32, math.nan_f32()}) {
		b, e := font.glyph_rasterize(s, glyph, size, context.allocator)
		font.bitmap_destroy(&b, context.allocator)
		testing.expect_value(t, e, font.Error.Invalid_Argument)
		testing.expect_value(t, font.glyph_advance(s, glyph, size), f32(0))
		testing.expect_value(t, font.face_metrics(s, glyph.face, size), font.Face_Metrics{})
	}
	b, e := font.glyph_rasterize(s, glyph, 20, mem.nil_allocator())
	font.bitmap_destroy(&b, mem.nil_allocator())
	testing.expect_value(t, e, font.Error.Out_Of_Memory)
	_, ok := font.glyph_lookup(s, family, .Regular, rune(-1))
	testing.expect(t, !ok)
	_, ok = font.glyph_lookup(s, family, .Regular, rune(0xd800))
	testing.expect(t, !ok)
}

@(private)
Failing_Allocator :: struct {
	backing: runtime.Allocator,
	remaining: int,
	failed: bool,
}

@(private)
failing_allocator_proc :: proc(
	data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	location: runtime.Source_Code_Location,
) -> ([]u8, runtime.Allocator_Error) {
	state := cast(^Failing_Allocator)data
	if size > 0 &&
	   (mode == .Alloc || mode == .Alloc_Non_Zeroed || mode == .Resize || mode == .Resize_Non_Zeroed) {
		if state.remaining == 0 {
			state.failed = true
			return nil, .Out_Of_Memory
		}
		state.remaining -= 1
	}
	return state.backing.procedure(state.backing.data, mode, size, alignment, old_memory, old_size, location)
}

@(test)
allocation_failure_cleanup :: proc(t: ^testing.T) {
	completed := false
	for fail_after in 0..<64 {
		state := Failing_Allocator{backing = context.allocator, remaining = fail_after}
		allocator := runtime.Allocator{failing_allocator_proc, &state}
		s, err := font.system_create(allocator)
		if err != .None {
			testing.expect_value(t, err, font.Error.Out_Of_Memory)
			testing.expect(t, s == nil)
			continue
		}
		family, load_err := font.family_load(s, "Consolas")
		if load_err != .None {
			testing.expect_value(t, load_err, font.Error.Out_Of_Memory)
		} else {
			_, _ = font.glyph_lookup(s, family, .Regular, '漢')
		}
		if state.failed {
			state.remaining = 1000
			_, retry_err := font.family_load(s, "Consolas")
			testing.expect_value(t, retry_err, font.Error.None)
		} else {
			completed = true
		}
		font.system_destroy(s)
		if completed {
			break
		}
	}
	testing.expect(t, completed)
}

@(test)
warm_lookup_does_not_allocate :: proc(t: ^testing.T) {
	state := Failing_Allocator{backing = context.allocator, remaining = 1000}
	allocator := runtime.Allocator{failing_allocator_proc, &state}
	s, err := font.system_create(allocator)
	if !testing.expect_value(t, err, font.Error.None) {
		return
	}
	defer font.system_destroy(s)
	family, load_err := font.family_load(s, "Consolas")
	if !testing.expect_value(t, load_err, font.Error.None) {
		return
	}
	for r in "A漢😀" {
		_, found := font.glyph_lookup(s, family, .Regular, r)
		testing.expect(t, found)
	}
	_, absent := font.glyph_lookup(s, family, .Regular, rune(0x10ffff))
	testing.expect(t, !absent)
	state.remaining = 0
	for _ in 0..<8 {
		for r in "A漢😀" {
			_, found := font.glyph_lookup(s, family, .Regular, r)
			testing.expect(t, found)
		}
		_, found := font.glyph_lookup(s, family, .Regular, rune(0x10ffff))
		testing.expect(t, !found)
	}
	testing.expect(t, !state.failed)
}
