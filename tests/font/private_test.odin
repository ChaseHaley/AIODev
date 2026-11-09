package font_test

import "core:testing"
import "aio:font"
import test_fonts "../fixtures/fonts"

// The bundled families load by name, and an installed font is invisible, so nothing a test draws
// depends on what the machine has installed.
@(test)
private_fonts_load_only_the_given_files :: proc(t: ^testing.T) {
	s, err := font.system_create_private(test_fonts.files())
	if !testing.expect_value(t, err, font.Error.None) {return}
	defer font.system_destroy(s)
	for name in ([]string{test_fonts.MONO, test_fonts.CODE, test_fonts.UI, test_fonts.EMOJI}) {
		_, load_err := font.family_load(s, name)
		testing.expectf(t, load_err == .None, "%s: %v", name, load_err)
	}
	_, installed := font.family_load(s, "Consolas")
	testing.expect_value(t, installed, font.Error.Family_Not_Found)
	families, list_err := font.installed_families(s)
	testing.expect_value(t, list_err, font.Error.None)
	testing.expect_value(t, len(families), 4)

	// Selawik is not installed on Windows, so only the private source can resolve it.
	system, system_err := font.system_create()
	if !testing.expect_value(t, system_err, font.Error.None) {return}
	defer font.system_destroy(system)
	_, absent := font.family_load(system, test_fonts.UI)
	testing.expect_value(t, absent, font.Error.Family_Not_Found)
}

// A character the monospace font lacks falls back to a bundled family, and one no bundled
// family has stays missing rather than reaching an installed font.
@(test)
private_fallback_stays_inside_the_given_files :: proc(t: ^testing.T) {
	s, err := font.system_create_private(test_fonts.files())
	if !testing.expect_value(t, err, font.Error.None) {return}
	defer font.system_destroy(s)
	mono, mono_err := font.family_load(s, test_fonts.MONO)
	if !testing.expect_value(t, mono_err, font.Error.None) {return}
	emoji, emoji_err := font.family_load(s, test_fonts.EMOJI)
	if !testing.expect_value(t, emoji_err, font.Error.None) {return}
	smile, found := font.glyph_lookup(s, mono, .Regular, 0x1f600)
	if testing.expect(t, found, "the emoji did not resolve") {
		testing.expect_value(t, smile.face, emoji.faces[.Regular])
	}
	// CJK, which no bundled font covers and Windows always installs a font for.
	_, cjk := font.glyph_lookup(s, mono, .Regular, 0x4e2d)
	testing.expect(t, !cjk, "fallback reached an installed font")

	// Emoji presentation maps from the bundled emoji family, as it does from Segoe UI Emoji, even
	// for a character the monospace font draws as text.
	out := make([dynamic]font.Shaped_Glyph)
	defer delete(out)
	run := [2]rune{0x263a, 0xfe0f}
	clusters := [2]int{0, 0}
	if !testing.expect_value(t, font.shape(s, mono, .Regular, run[:], 20, &out, clusters[:]), font.Error.None) {
		return
	}
	text_face, _ := font.glyph_lookup(s, mono, .Regular, 0x263a)
	testing.expect_value(t, text_face.face, mono.faces[.Regular])
	if testing.expect(t, len(out) > 0) {
		testing.expect_value(t, out[0].glyph.face, emoji.faces[.Regular])
	}
}

// Twemoji is COLR version 0, which DirectWrite's colour translation draws in colour.
@(test)
private_emoji_rasterizes_in_colour :: proc(t: ^testing.T) {
	s, err := font.system_create_private(test_fonts.files())
	if !testing.expect_value(t, err, font.Error.None) {return}
	defer font.system_destroy(s)
	emoji, emoji_err := font.family_load(s, test_fonts.EMOJI)
	if !testing.expect_value(t, emoji_err, font.Error.None) {return}
	glyph, found := font.glyph_lookup(s, emoji, .Regular, 0x1f600)
	if !testing.expect(t, found) {return}
	bitmap, raster_err := font.glyph_rasterize(s, glyph, 32, context.allocator, color = true)
	defer font.bitmap_destroy(&bitmap, context.allocator)
	testing.expect_value(t, raster_err, font.Error.None)
	testing.expect(t, bitmap.color && len(bitmap.pixels) > 0)
}
