package program_art

import "aio:vector"
import "core:strconv"
import "core:strings"

// Bundled single-colour artwork for programs whose executables carry no useful icon, or that run
// out of reach of Windows (WSL, SSH) and are known only by the app key they report (WORK-279).
// tools/program_art.ps1 generates the table from pinned icon packages.

TABLE :: #load("../../assets/program_art.txt", string)

// The artwork is drawn in a square this many units wide.
VIEW :: 24

Art :: struct {
	// The first name is the canonical one; all are matched without case or a trailing ".exe".
	names:  string,
	// Six hex digits, or empty to use the theme text colour.
	colour: string,
	rule:   vector.Fill_Rule,
	// Path data, separated by '|'.
	paths:  string,
}

// The artwork naming `name`, an executable stem or reported app key.
@(require_results)
find :: proc(name: string) -> (art: Art, found: bool) {
	key := stem(name)
	if key == "" {return}
	rest := TABLE
	for line in strings.split_lines_iterator(&rest) {
		if line == "" || line[0] == '#' {continue}
		entry, ok := parse(line)
		if !ok {continue}
		names := entry.names
		for candidate in strings.split_iterator(&names, ",") {
			if strings.equal_fold(candidate, key) {return entry, true}
		}
	}
	return
}

// The canonical name of `art`, the stable key for caches and verification.
canonical :: proc(art: Art) -> string {
	comma := strings.index_byte(art.names, ',')
	return comma < 0 ? art.names : art.names[:comma]
}

// The brand colour, if the artwork has one.
@(require_results)
brand :: proc(art: Art) -> (colour: [3]u8, ok: bool) {
	if len(art.colour) != 6 {return}
	for i in 0 ..< 3 {
		value, parsed := strconv.parse_u64_of_base(art.colour[i * 2:i * 2 + 2], 16)
		if !parsed {return}
		colour[i] = u8(value)
	}
	return colour, true
}

// Draws `art` size x size in `colour` as premultiplied RGBA.
@(require_results)
draw :: proc(art: Art, size: int, colour: [3]u8, pixels: []u8) -> bool {
	if size < 1 || size > vector.MAX_SIZE || len(pixels) < size * size * 4 {return false}
	paths := strings.split(art.paths, "|")
	defer delete(paths)
	coverage := make([]u8, size * size)
	defer delete(coverage)
	if !vector.fill(paths, VIEW, art.rule, size, coverage) {return false}
	for alpha, i in coverage {
		a := u32(alpha)
		pixels[i * 4] = u8((u32(colour.r) * a + 127) / 255)
		pixels[i * 4 + 1] = u8((u32(colour.g) * a + 127) / 255)
		pixels[i * 4 + 2] = u8((u32(colour.b) * a + 127) / 255)
		pixels[i * 4 + 3] = alpha
	}
	return true
}

@(private)
parse :: proc(line: string) -> (art: Art, ok: bool) {
	fields := line
	art.names = strings.split_iterator(&fields, "|") or_return
	art.colour = strings.split_iterator(&fields, "|") or_return
	rule := strings.split_iterator(&fields, "|") or_return
	switch rule {
	case "nonzero":
		art.rule = .Nonzero
	case "evenodd":
		art.rule = .Even_Odd
	case:
		return
	}
	art.paths = fields
	return art, art.names != "" && art.paths != ""
}

@(private)
stem :: proc(name: string) -> string {
	text := strings.trim_space(name)
	if len(text) > 4 && strings.equal_fold(text[len(text) - 4:], ".exe") {text = text[:len(text) - 4]}
	return text
}
