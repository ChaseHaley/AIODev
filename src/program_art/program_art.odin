package program_art

import "aio:vector"
import "core:mem"
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
	// The first name is the canonical one; all are matched without case.
	names:  string,
	layers: []Layer,
}

Layer :: struct {
	// The brand colour, when `branded`; otherwise the layer uses the theme text colour.
	colour:  [3]u8,
	branded: bool,
	rule:    vector.Fill_Rule,
	path:    string,
}

// How to colour artwork. Layers without a brand colour, or every layer when `mono` is set, use
// `text`. Comparable, so it can key a cache of drawn artwork.
Paint :: struct {
	text: [3]u8,
	mono: bool,
}

// TABLE parsed once. Names and paths borrow from TABLE; `layers` backs every Art's layers.
Catalogue :: struct {
	arts:   []Art,
	layers: []Layer,
}

// Parses TABLE. A malformed entry is skipped, so it is found like an unsupported program.
@(require_results)
catalogue_make :: proc(allocator := context.allocator) -> (catalogue: Catalogue, err: mem.Allocator_Error) {
	arts, layers := 0, 0
	rest := TABLE
	for line in strings.split_lines_iterator(&rest) {
		count := entry_layers(line)
		if count > 0 {arts, layers = arts + 1, layers + count}
	}
	catalogue.arts = make([]Art, arts, allocator) or_return
	catalogue.layers, err = make([]Layer, layers, allocator)
	if err != nil {
		delete(catalogue.arts, allocator)
		return {}, err
	}
	arts, layers = 0, 0
	rest = TABLE
	for line in strings.split_lines_iterator(&rest) {
		count := entry_layers(line)
		if count == 0 {continue}
		bar := strings.index_byte(line, '|')
		art := &catalogue.arts[arts]
		art.names, art.layers = line[:bar], catalogue.layers[layers:layers + count]
		text := line[bar + 1:]
		for &layer in art.layers {layer, _ = next_layer(&text)}
		arts, layers = arts + 1, layers + count
	}
	return catalogue, nil
}

catalogue_destroy :: proc(catalogue: ^Catalogue, allocator := context.allocator) {
	delete(catalogue.arts, allocator)
	delete(catalogue.layers, allocator)
	catalogue^ = {}
}

// The artwork naming `key`, an executable stem or reported app key; callers strip ".exe".
@(require_results)
find :: proc(catalogue: ^Catalogue, key: string) -> (art: Art, found: bool) {
	if key == "" {return}
	for entry in catalogue.arts {
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

// Draws `art` size x size as premultiplied RGBA, each layer over the ones before it.
@(require_results)
draw :: proc(art: Art, size: int, paint: Paint, pixels: []u8) -> bool {
	if size < 1 || size > vector.MAX_SIZE || len(pixels) < size * size * 4 {return false}
	coverage := make([]u8, size * size)
	defer delete(coverage)
	out := pixels[:size * size * 4]
	for &value in out {value = 0}
	for layer in art.layers {
		if !vector.fill({layer.path}, VIEW, layer.rule, size, coverage) {return false}
		colour := paint.mono || !layer.branded ? paint.text : layer.colour
		for alpha, i in coverage {
			a := u32(alpha)
			p := out[i * 4:i * 4 + 4]
			for c in 0 ..< 3 {p[c] = u8((u32(colour[c]) * a + u32(p[c]) * (255 - a) + 127) / 255)}
			p[3] = u8((255 * a + u32(p[3]) * (255 - a) + 127) / 255)
		}
	}
	return true
}

// The number of layers in one table line, or zero for a comment or malformed entry.
@(private)
entry_layers :: proc(line: string) -> int {
	if line == "" || line[0] == '#' {return 0}
	bar := strings.index_byte(line, '|')
	if bar <= 0 {return 0}
	rest := line[bar + 1:]
	count := 0
	for rest != "" {
		_, ok := next_layer(&rest)
		if !ok {return 0}
		count += 1
	}
	return count
}

// Takes the next `colour:rule:path` layer from `rest`, layers separated by '|'.
@(private, require_results)
next_layer :: proc(rest: ^string) -> (layer: Layer, ok: bool) {
	text := strings.split_iterator(rest, "|") or_return
	colour := strings.split_iterator(&text, ":") or_return
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
	if len(colour) != 0 && len(colour) != 6 {return}
	// Six characters that are not hex digits leave the layer in the theme text colour.
	layer.branded = len(colour) == 6
	for i in 0 ..< 3 {
		if !layer.branded {break}
		value, parsed := strconv.parse_u64_of_base(colour[i * 2:i * 2 + 2], 16)
		layer.colour[i], layer.branded = u8(value), parsed
	}
	if !layer.branded {layer.colour = {}}
	return layer, layer.path != ""
}
