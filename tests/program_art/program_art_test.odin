package program_art_test

import "core:strings"
import "core:testing"
import "aio:program_art"

@(test)
names_match_without_case_or_exe_and_resolve_to_their_canonical_entry :: proc(t: ^testing.T) {
	for test in ([?][2]string {
		{"codex", "codex"},
		{"Codex.EXE", "codex"},
		{"codex-x86_64-pc-windows-msvc.exe", "codex"},
		{"claude-code", "claude"},
		{"nvim", "nvim"},
		{"python3", "python"},
	}) {
		art, found := program_art.find(test[0])
		if testing.expect(t, found, test[0]) {testing.expect_value(t, program_art.canonical(art), test[1])}
	}
	for name in ([?]string{"", "pwsh", "codexx", "#", "names"}) {
		_, found := program_art.find(name)
		testing.expect(t, !found, name)
	}
}

@(test)
brand_colours_parse_and_entries_without_one_use_the_theme :: proc(t: ^testing.T) {
	claude, _ := program_art.find("claude")
	colour, ok := program_art.brand(claude)
	testing.expect(t, ok)
	testing.expect_value(t, colour, [3]u8{0xD9, 0x77, 0x57})
	opencode, _ := program_art.find("opencode")
	_, ok = program_art.brand(opencode)
	testing.expect(t, !ok)
}

// Guards the generated table: every entry parses, names stay unique, and every path draws.
@(test)
every_entry_draws_at_tab_and_header_sizes :: proc(t: ^testing.T) {
	seen: map[string]bool
	defer delete(seen)
	rest := program_art.TABLE
	entries := 0
	for line in strings.split_lines_iterator(&rest) {
		if line == "" || line[0] == '#' {continue}
		names := line[:strings.index_byte(line, '|')]
		first := names
		if comma := strings.index_byte(names, ','); comma >= 0 {first = names[:comma]}
		art, found := program_art.find(first)
		if !testing.expect(t, found, first) {continue}
		entries += 1
		for name in strings.split_iterator(&names, ",") {
			testing.expect(t, !seen[name], name)
			seen[name] = true
		}
		for size in ([?]int{14, 21, 32}) {
			pixels := make([]u8, size * size * 4, context.temp_allocator)
			testing.expect(t, program_art.draw(art, size, {255, 255, 255}, pixels), first)
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
	art, _ := program_art.find("git")
	pixels: [16 * 16 * 4]u8
	testing.expect(t, program_art.draw(art, 16, {200, 100, 50}, pixels[:]))
	for i := 0; i < len(pixels); i += 4 {
		a := u32(pixels[i + 3])
		testing.expect_value(t, u32(pixels[i]), (200 * a + 127) / 255)
		testing.expect_value(t, u32(pixels[i + 2]), (50 * a + 127) / 255)
	}
	testing.expect(t, !program_art.draw(art, 0, {}, pixels[:]))
	testing.expect(t, !program_art.draw(art, 17, {}, pixels[:]))
}
