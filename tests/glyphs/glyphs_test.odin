package glyphs_test

import "core:testing"
import "aio:font"
import "aio:glyphs"
import "aio:render"

Fixture :: struct {
	fonts: ^font.System,
	device: ^render.Device,
	cache: glyphs.Cache,
	family: font.Family,
}

fixture_create :: proc(t: ^testing.T) -> (f: Fixture, ok: bool) {
	err: font.Error
	f.fonts, err = font.system_create()
	if !testing.expect_value(t, err, font.Error.None) {
		return
	}
	f.family, err = font.family_load(f.fonts, "Consolas")
	device_error: render.Error
	f.device, device_error = render.device_create()
	font_ok := testing.expect_value(t, err, font.Error.None)
	if !testing.expect_value(t, device_error, render.Error.None) || !font_ok {
		fixture_destroy(&f)
		return
	}
	glyphs.init(&f.cache, f.fonts, f.device)
	return f, true
}

fixture_destroy :: proc(f: ^Fixture) {
	glyphs.destroy(&f.cache)
	if f.device != nil {
		render.device_destroy(f.device)
	}
	if f.fonts != nil {
		font.system_destroy(f.fonts)
	}
}

@(test)
glyph_entries_are_cached :: proc(t: ^testing.T) {
	f, ok := fixture_create(t)
	if !ok {
		return
	}
	defer fixture_destroy(&f)
	g, found := font.glyph_lookup(f.fonts, f.family, .Regular, 'A')
	if !testing.expect(t, found) {
		return
	}
	first, result := glyphs.glyph(&f.cache, g, 20)
	testing.expect_value(t, result, glyphs.Result.Ok)
	testing.expect(t, first.size.x > 0 && first.size.y > 0)
	testing.expect(t, first.offset.y < 0)
	again, _ := glyphs.glyph(&f.cache, g, 20)
	testing.expect_value(t, again, first)
	larger, _ := glyphs.glyph(&f.cache, g, 40)
	testing.expect(t, larger.size.y > first.size.y)
	space, _ := font.glyph_lookup(f.fonts, f.family, .Regular, ' ')
	empty, empty_result := glyphs.glyph(&f.cache, space, 20)
	testing.expect_value(t, empty_result, glyphs.Result.Ok)
	testing.expect_value(t, empty.size, [2]f32{})
}

@(test)
sprites_cover_the_cell_width :: proc(t: ^testing.T) {
	f, ok := fixture_create(t)
	if !ok {
		return
	}
	defer fixture_destroy(&f)
	for kind in glyphs.Sprite {
		entry, result := glyphs.sprite(&f.cache, kind, 9, 2)
		testing.expect_value(t, result, glyphs.Result.Ok)
		testing.expect_value(t, entry.size, [2]f32{9, 8})
		testing.expect_value(t, entry.offset, [2]f32{0, -4})
		again, _ := glyphs.sprite(&f.cache, kind, 9, 2)
		testing.expect_value(t, again, entry)
	}
}

@(test)
atlas_reset_invalidates_entries :: proc(t: ^testing.T) {
	f, ok := fixture_create(t)
	if !ok {
		return
	}
	defer fixture_destroy(&f)
	g, _ := font.glyph_lookup(f.fonts, f.family, .Regular, 'B')
	before, _ := glyphs.glyph(&f.cache, g, 24)
	for height in ([?]i32{256, 1}) {
		for {
			if _, reserved := render.atlas_reserve(f.device, 4096, height); !reserved {
				break
			}
		}
	}
	next, _ := font.glyph_lookup(f.fonts, f.family, .Regular, 'C')
	_, overflow := glyphs.glyph(&f.cache, next, 24)
	testing.expect_value(t, overflow, glyphs.Result.Atlas_Reset)
	after, result := glyphs.glyph(&f.cache, g, 24)
	testing.expect_value(t, result, glyphs.Result.Ok)
	testing.expect_value(t, after.size, before.size)
	testing.expect_value(t, after.atlas.x + after.atlas.y, 0)
}
