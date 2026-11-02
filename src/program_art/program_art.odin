package program_art

import "aio:vector"
import "core:strconv"
import "core:strings"

// Bundled artwork for programs whose executables carry no useful icon, or that run out of reach of
// Windows (WSL, SSH) and are known only by the app key they report (WORK-279). Each entry is one
// or more single-colour layers, drawn in order (WORK-290). tools/program_art.ps1 generates the
// table from pinned icon packages and assets/program_art.

TABLE :: #load("../../assets/program_art.txt", string)

// The artwork is drawn in a square this many units wide.
VIEW :: 24

Art :: struct {
	// The first name is the canonical one; all are matched without case or a trailing ".exe".
	names:  string,
	// Layers separated by '|', each `colour:rule:path`; read them with next_layer.
	layers: string,
}

Layer :: struct {
	// Six hex digits, or empty to use the theme text colour.
	colour: string,
	rule:   vector.Fill_Rule,
	path:   string,
}

// How to colour artwork. Layers without a brand colour, or every layer when `mono` is set, use
// `text`. Comparable, so it can key a cache of drawn artwork.
Paint :: struct {
	text: [3]u8,
	mono: bool,
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

// Takes the next layer from `rest`, which starts as an Art's layers.
@(require_results)
next_layer :: proc(rest: ^string) -> (layer: Layer, ok: bool) {
	text := strings.split_iterator(rest, "|") or_return
	layer.colour = strings.split_iterator(&text, ":") or_return
	rule := strings.split_iterator(&text, ":") or_return
	switch rule {
	case "nonzero":
		layer.rule = .Nonzero
	case "evenodd":
		layer.rule = .Even_Odd
	case:
		return
	}
	layer.path = text
	return layer, (layer.colour == "" || len(layer.colour) == 6) && layer.path != ""
}

// The layer's brand colour, if it has one.
@(require_results)
brand :: proc(layer: Layer) -> (colour: [3]u8, ok: bool) {
	if len(layer.colour) != 6 {return}
	for i in 0 ..< 3 {
		value, parsed := strconv.parse_u64_of_base(layer.colour[i * 2:i * 2 + 2], 16)
		if !parsed {return}
		colour[i] = u8(value)
	}
	return colour, true
}

// Draws `art` size x size as premultiplied RGBA, each layer over the ones before it.
@(require_results)
draw :: proc(art: Art, size: int, paint: Paint, pixels: []u8) -> bool {
	if size < 1 || size > vector.MAX_SIZE || len(pixels) < size * size * 4 {return false}
	coverage := make([]u8, size * size)
	defer delete(coverage)
	out := pixels[:size * size * 4]
	for &value in out {value = 0}
	rest := art.layers
	for rest != "" {
		layer := next_layer(&rest) or_return
		if !vector.fill({layer.path}, VIEW, layer.rule, size, coverage) {return false}
		colour, branded := brand(layer)
		if paint.mono || !branded {colour = paint.text}
		for alpha, i in coverage {
			a := u32(alpha)
			p := out[i * 4:i * 4 + 4]
			for c in 0 ..< 3 {p[c] = u8((u32(colour[c]) * a + u32(p[c]) * (255 - a) + 127) / 255)}
			p[3] = u8((255 * a + u32(p[3]) * (255 - a) + 127) / 255)
		}
	}
	return true
}

@(private)
parse :: proc(line: string) -> (art: Art, ok: bool) {
	bar := strings.index_byte(line, '|')
	if bar <= 0 {return}
	art.names, art.layers = line[:bar], line[bar + 1:]
	rest := art.layers
	for rest != "" {_ = next_layer(&rest) or_return}
	return art, art.layers != ""
}

@(private)
stem :: proc(name: string) -> string {
	text := strings.trim_space(name)
	if len(text) > 4 && strings.equal_fold(text[len(text) - 4:], ".exe") {text = text[:len(text) - 4]}
	return text
}
