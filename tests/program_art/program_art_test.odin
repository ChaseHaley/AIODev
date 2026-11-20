package program_art_test

import "core:strings"
import "core:testing"
import "aio:colour"
import "aio:program_art"
import "aio:procinfo"

// The table parsed once for a test; callers destroy it.
@(private)
catalogue :: proc(t: ^testing.T) -> (program_art.Catalogue, bool) {
	c, err := program_art.catalogue_make()
	return c, testing.expect_value(t, err, nil)
}

// Names arrive as executable stems, so ".exe" is stripped by procinfo.executable_stem first.
@(test)
names_match_without_case_or_exe_and_resolve_to_their_canonical_entry :: proc(t: ^testing.T) {
	c, ok := catalogue(t)
	if !ok {return}
	defer program_art.catalogue_destroy(&c)
	for test in ([?][2]string {
		{"codex", "codex"},
		{"Codex.EXE", "codex"},
		{"codex-x86_64-pc-windows-msvc.exe", "codex"},
		{"claude-code", "claude"},
		{"agy.exe", "antigravity"},
		{"Antigravity.EXE", "antigravity"},
		{"agy-ide", "antigravity"},
		{"nvim", "nvim"},
		{"python3", "python"},
	}) {
		art, found := program_art.find(&c, procinfo.executable_stem(test[0]))
		if testing.expect(t, found, test[0]) {testing.expect_value(t, program_art.canonical(art), test[1])}
	}
	for name in ([?]string{"", "pwsh", "codexx", "#", "names"}) {
		_, found := program_art.find(&c, procinfo.executable_stem(name))
		testing.expect(t, !found, name)
	}
}

@(test)
brand_colours_parse_and_entries_without_one_use_the_theme :: proc(t: ^testing.T) {
	c, ok := catalogue(t)
	if !ok {return}
	defer program_art.catalogue_destroy(&c)
	claude, _ := program_art.find(&c, "claude")
	testing.expect(t, claude.layers[0].branded)
	testing.expect_value(t, claude.layers[0].colour, [3]u8{0xD9, 0x77, 0x57})
	opencode, _ := program_art.find(&c, "opencode")
	testing.expect(t, !opencode.layers[0].branded)
	antigravity, _ := program_art.find(&c, "agy")
	testing.expect_value(t, antigravity.layers[0].colour, [3]u8{0x31, 0x86, 0xFF})
}

// Neovim's flat mark: a blue left stroke under green right and diagonal strokes (WORK-290).
@(test)
layers_keep_their_own_colours :: proc(t: ^testing.T) {
	c, ok := catalogue(t)
	if !ok {return}
	defer program_art.catalogue_destroy(&c)
	art, found := program_art.find(&c, "nvim")
	if !testing.expect(t, found) {return}
	size :: 24
	pixels: [size * size * 4]u8
	// A pixel inside the left stroke only, and one inside the right stroke only.
	left, right := (16 * size + 4) * 4, (8 * size + 19) * 4
	testing.expect(t, program_art.draw(art, size, {text = {200, 200, 200}}, pixels[:]))
	testing.expect_value(t, pixel(pixels[:], left), [4]u8{0x3C, 0x92, 0xD2, 255})
	testing.expect_value(t, pixel(pixels[:], right), [4]u8{0x57, 0xA1, 0x43, 255})
}

// Studio Light's and Studio Dark's tab bar and tab text (WORK-509).
@(private)
LIGHT :: program_art.Paint{text = {0x52, 0x52, 0x5C}, background = {0xEF, 0xEF, 0xF2}}
@(private)
DARK :: program_art.Paint{text = {0xA1, 0xA1, 0xAA}, background = {0x0C, 0x0C, 0x0E}}

@(private)
Ink_Case :: struct {
	paint: program_art.Paint,
	brand: [3]u8,
}

@(test)
faint_hues_are_fitted_and_faint_neutrals_take_the_text_colour :: proc(t: ^testing.T) {
	unbranded := program_art.Layer{colour = {0xFF, 0, 0}}
	testing.expect_value(t, program_art.ink(unbranded, LIGHT), LIGHT.text)
	for test in ([?]Ink_Case {
		{LIGHT, {0x1D, 0x5F, 0xC4}},
		{LIGHT, {0x00, 0x00, 0x00}},
		{DARK, {0xF7, 0xA4, 0x1D}},
		{DARK, {0xFF, 0xFF, 0xFF}},
	}) {
		testing.expect_value(t, program_art.ink({colour = test.brand, branded = true}, test.paint), test.brand)
	}
	// Zig's orange, Junie's green and Gleam's pink darken on a light bar; Lua's navy, .NET's violet
	// and Helix's dark purple lighten on a dark one.
	for test in ([?]Ink_Case {
		{LIGHT, {0xF7, 0xA4, 0x1D}},
		{LIGHT, {0x47, 0xE0, 0x54}},
		{LIGHT, {0xFF, 0xAF, 0xF3}},
		{DARK, {0x00, 0x00, 0x80}},
		{DARK, {0x51, 0x2B, 0xD4}},
		{DARK, {0x28, 0x17, 0x33}},
	}) {
		fitted := program_art.ink({colour = test.brand, branded = true}, test.paint)
		ratio := colour.contrast_ratio(colour.rgba(fitted), colour.rgba(test.paint.background))
		testing.expectf(t, ratio >= program_art.CONTRAST, "%v fitted to %v: %v", test.brand, fitted, ratio)
		darker := test.paint == LIGHT
		for i in 0 ..< 3 {
			moved := darker ? fitted[i] <= test.brand[i] : fitted[i] >= test.brand[i]
			testing.expectf(t, moved, "%v fitted to %v", test.brand, fitted)
		}
	}
	// Black, GitHub's near-black and a near-white spread under NEUTRAL_CHROMA: ink, not a hue.
	for test in ([?]Ink_Case{{DARK, {0x00, 0x00, 0x00}}, {DARK, {0x18, 0x17, 0x17}}, {LIGHT, {0xF0, 0xF0, 0xF0}}}) {
		testing.expect_value(t, program_art.ink({colour = test.brand, branded = true}, test.paint), test.paint.text)
	}
}

// Each layer of a multi-colour logo is decided alone: one keeps its colour, a faint hue is fitted
// and a faint neutral takes the text colour.
@(test)
a_multi_colour_logo_decides_each_layer :: proc(t: ^testing.T) {
	layers := [3]program_art.Layer {
		{colour = {0x1D, 0x5F, 0xC4}, branded = true, rule = .Nonzero, path = "M0 0H8V24H0Z"},
		{colour = {0xF7, 0xA4, 0x1D}, branded = true, rule = .Nonzero, path = "M8 0H16V24H8Z"},
		{colour = {0xF0, 0xF0, 0xF0}, branded = true, rule = .Nonzero, path = "M16 0H24V24H16Z"},
	}
	art := program_art.Art{names = "test", layers = layers[:]}
	pixels: [3 * 3 * 4]u8
	testing.expect(t, program_art.draw(art, 3, LIGHT, pixels[:]))
	fitted := program_art.ink(layers[1], LIGHT)
	testing.expect(t, fitted != layers[1].colour && fitted != LIGHT.text)
	testing.expect_value(t, pixel(pixels[:], 0), [4]u8{0x1D, 0x5F, 0xC4, 255})
	testing.expect_value(t, pixel(pixels[:], 4), [4]u8{fitted[0], fitted[1], fitted[2], 255})
	testing.expect_value(t, pixel(pixels[:], 8), [4]u8{LIGHT.text[0], LIGHT.text[1], LIGHT.text[2], 255})
}

// A later layer covers an earlier one where they overlap, as SVG paints them.
@(test)
later_layers_paint_over_earlier_ones :: proc(t: ^testing.T) {
	layers := [2]program_art.Layer {
		{colour = {0xFF, 0, 0}, branded = true, rule = .Nonzero, path = "M0 0H24V24H0Z"},
		{colour = {0, 0, 0xFF}, branded = true, rule = .Nonzero, path = "M0 0H12V24H0Z"},
	}
	art := program_art.Art{names = "test", layers = layers[:]}
	pixels: [4 * 4 * 4]u8
	testing.expect(t, program_art.draw(art, 4, LIGHT, pixels[:]))
	testing.expect_value(t, pixel(pixels[:], 0), [4]u8{0, 0, 255, 255})
	testing.expect_value(t, pixel(pixels[:], 12), [4]u8{255, 0, 0, 255})
	layers[1].path = "bad"
	testing.expect(t, !program_art.draw(art, 4, {}, pixels[:]))
}

// Guards the generated table: every entry parses, names stay unique, and every path draws.
@(test)
every_entry_draws_at_tab_and_header_sizes :: proc(t: ^testing.T) {
	c, ok := catalogue(t)
	if !ok {return}
	defer program_art.catalogue_destroy(&c)
	seen: map[string]bool
	defer delete(seen)
	rest := program_art.TABLE
	entries := 0
	for line in strings.split_lines_iterator(&rest) {
		if line == "" || line[0] == '#' {continue}
		names := line[:strings.index_byte(line, '|')]
		first := names
		if comma := strings.index_byte(names, ','); comma >= 0 {first = names[:comma]}
		art, found := program_art.find(&c, first)
		if !testing.expect(t, found, first) {continue}
		entries += 1
		for name in strings.split_iterator(&names, ",") {
			testing.expect(t, !seen[name], name)
			seen[name] = true
		}
		for size in ([?]int{14, 21, 32}) {
			pixels := make([]u8, size * size * 4, context.temp_allocator)
			testing.expect(t, program_art.draw(art, size, {text = {255, 255, 255}}, pixels), first)
			covered, solid := 0, 0
			for i := 3; i < len(pixels); i += 4 {
				if pixels[i] > 0 {covered += 1}
				if pixels[i] == 255 {solid += 1}
			}
			// Real artwork neither vanishes nor fills its whole square solid.
			testing.expect(t, covered > size && solid < size * size, first)
		}
	}
	testing.expect(t, entries >= 60)
}

@(test)
drawing_premultiplies_the_colour :: proc(t: ^testing.T) {
	c, ok := catalogue(t)
	if !ok {return}
	defer program_art.catalogue_destroy(&c)
	art, _ := program_art.find(&c, "git")
	pixels: [16 * 16 * 4]u8
	testing.expect(t, program_art.draw(art, 16, {text = {200, 100, 50}}, pixels[:]))
	for i := 0; i < len(pixels); i += 4 {
		a := u32(pixels[i + 3])
		testing.expect_value(t, u32(pixels[i]), (0xF0 * a + 127) / 255)
		testing.expect_value(t, u32(pixels[i + 2]), (0x2E * a + 127) / 255)
	}
	testing.expect(t, !program_art.draw(art, 0, {}, pixels[:]))
	testing.expect(t, !program_art.draw(art, 17, {}, pixels[:]))
}

@(private)
pixel :: proc(pixels: []u8, at: int) -> [4]u8 {
	return {pixels[at], pixels[at + 1], pixels[at + 2], pixels[at + 3]}
}
