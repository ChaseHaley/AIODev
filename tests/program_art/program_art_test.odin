package program_art_test

import "core:strings"
import "core:testing"
import "aio:program_art"
import "aio:settings"

// The table parsed once for a test; callers destroy it.
@(private)
catalogue :: proc(t: ^testing.T) -> (program_art.Catalogue, bool) {
	c, err := program_art.catalogue_make()
	return c, testing.expect_value(t, err, nil)
}

// Names arrive as executable stems, so ".exe" is stripped by settings.executable_stem first.
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
		{"nvim", "nvim"},
		{"python3", "python"},
	}) {
		art, found := program_art.find(&c, settings.executable_stem(test[0]))
		if testing.expect(t, found, test[0]) {testing.expect_value(t, program_art.canonical(art), test[1])}
	}
	for name in ([?]string{"", "pwsh", "codexx", "#", "names"}) {
		_, found := program_art.find(&c, settings.executable_stem(name))
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
}

// Neovim's flat mark: a blue left stroke under green right and diagonal strokes (WORK-290).
@(test)
layers_keep_their_own_colours_unless_painted_mono :: proc(t: ^testing.T) {
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
	testing.expect(t, program_art.draw(art, size, {text = {200, 200, 200}, mono = true}, pixels[:]))
	testing.expect_value(t, pixel(pixels[:], left), [4]u8{200, 200, 200, 255})
	testing.expect_value(t, pixel(pixels[:], right), [4]u8{200, 200, 200, 255})
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
	testing.expect(t, program_art.draw(art, 4, {}, pixels[:]))
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
	testing.expect(t, program_art.draw(art, 16, {text = {200, 100, 50}, mono = true}, pixels[:]))
	for i := 0; i < len(pixels); i += 4 {
		a := u32(pixels[i + 3])
		testing.expect_value(t, u32(pixels[i]), (200 * a + 127) / 255)
		testing.expect_value(t, u32(pixels[i + 2]), (50 * a + 127) / 255)
	}
	testing.expect(t, !program_art.draw(art, 0, {}, pixels[:]))
	testing.expect(t, !program_art.draw(art, 17, {}, pixels[:]))
}

@(private)
pixel :: proc(pixels: []u8, at: int) -> [4]u8 {
	return {pixels[at], pixels[at + 1], pixels[at + 2], pixels[at + 3]}
}
