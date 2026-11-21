package neovim

import "base:runtime"
import "core:log"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"

// Bounds on what a peer can make the client allocate.
@(private)
MAX_GRID_SIDE :: 1 << 14
@(private)
MAX_GRID_CELLS :: 1 << 22
@(private)
MAX_HIGHLIGHTS :: 1 << 20
@(private)
MAX_MODES :: 64
@(private)
MAX_CLUSTERS :: 1 << 20

@(private)
BLANK :: Cell{glyph = ' '}
@(private)
REPLACEMENT :: u32(0xFFFD)

// The state events mutate; `flush` copies it into Client.screen.
@(private)
Back :: struct {
	columns, rows: int,
	cells: [dynamic]Cell,
	cursor_row, cursor_column: int,
	modes: [dynamic]Mode,
	mode_index: int,
	cursor_style_enabled, busy: bool,
	default_foreground, default_background, default_special: Color,
	highlights: [dynamic]Highlight,
	highlights_changed: bool,
}

// An array being read element by element. Elements that are themselves containers are left to the
// caller; close skips whatever it did not read.
@(private)
Tuple :: struct {
	r: ^Msgpack_Reader,
	remaining: int,
}

@(private)
Handler :: proc(c: ^Client, r: ^Msgpack_Reader) -> bool

@(private)
tuple_open :: proc(r: ^Msgpack_Reader) -> (t: Tuple, ok: bool) {
	value, error := msgpack_read(r)
	if error != .None || value.kind != .Array {return {}, false}
	return {r, value.count}, true
}

@(private)
tuple_next :: proc(t: ^Tuple) -> (value: Msgpack_Value, ok: bool) {
	if t.remaining <= 0 {return {}, false}
	error: Msgpack_Error
	value, error = msgpack_read(t.r)
	if error != .None {return {}, false}
	t.remaining -= 1
	return value, true
}

@(private)
tuple_int :: proc(t: ^Tuple) -> (value: int, ok: bool) {
	element := tuple_next(t) or_return
	if element.kind != .Integer {return 0, false}
	return int(element.integer), true
}

@(private)
tuple_bytes :: proc(t: ^Tuple) -> (value: []u8, ok: bool) {
	element := tuple_next(t) or_return
	if element.kind != .String {return nil, false}
	return element.bytes, true
}

@(private)
tuple_close :: proc(t: ^Tuple) -> bool {
	for t.remaining > 0 {
		if msgpack_skip(t.r) != .None {return false}
		t.remaining -= 1
	}
	return true
}

// A scalar-valued map entry. A container value is skipped and reported as nil, so a field a future
// Neovim adds cannot spoil the entries around it.
@(private)
map_next :: proc(r: ^Msgpack_Reader) -> (key: string, value: Msgpack_Value, ok: bool) {
	key_value, key_error := msgpack_read(r)
	if key_error != .None || key_value.kind != .String {return}
	before := r.offset
	read_error: Msgpack_Error
	value, read_error = msgpack_read(r)
	if read_error != .None {return}
	if value.kind == .Array || value.kind == .Map {
		r.offset = before
		if msgpack_skip(r) != .None {return}
		value = {}
	}
	return string(key_value.bytes), value, true
}

@(private)
unsigned_clamped :: proc(value: i64) -> u32 {
	return u32(clamp(value, 0, i64(max(u32))))
}

// Handles the params of one `redraw` notification: an array of [name, args...] events.
@(private)
redraw_handle :: proc(c: ^Client, r: ^Msgpack_Reader) {
	events, ok := tuple_open(r)
	if !ok {return}
	for _ in 0 ..< events.remaining {
		begin := r.offset
		if !redraw_event(c, r) {
			r.offset = begin
			if msgpack_skip(r) != .None {return}
		}
		if c.fault != .None {return}
	}
}

// False when the event is unknown or not shaped as expected: the caller then skips all of it.
@(private)
redraw_event :: proc(c: ^Client, r: ^Msgpack_Reader) -> bool {
	event := tuple_open(r) or_return
	name := tuple_bytes(&event) or_return
	handler: Handler
	switch string(name) {
	case "grid_line": handler = grid_line
	case "grid_scroll": handler = grid_scroll
	case "grid_cursor_goto": handler = grid_cursor_goto
	case "flush": handler = flush
	case "hl_attr_define": handler = hl_attr_define
	case "default_colors_set": handler = default_colors_set
	case "grid_resize": handler = grid_resize
	case "grid_clear": handler = grid_clear
	case "grid_destroy": handler = grid_destroy
	case "mode_info_set": handler = mode_info_set
	case "mode_change": handler = mode_change
	case "busy_start": handler = busy_start
	case "busy_stop": handler = busy_stop
	case "mouse_on": handler = mouse_on
	case "mouse_off": handler = mouse_off
	case "set_title": handler = set_title
	case "chdir": handler = chdir
	case "bell", "visual_bell": handler = bell
	case: return false
	}
	for _ in 0 ..< event.remaining {
		begin := r.offset
		if !handler(c, r) {
			log.warnf("neovim: ignoring a malformed %s event", string(name))
			r.offset = begin
			if msgpack_skip(r) != .None {return false}
		}
		if c.fault != .None {return true}
	}
	return true
}

@(private)
cell_glyph :: proc(c: ^Client, text: []u8) -> u32 {
	if len(text) == 0 {return 0}
	codepoint, width := utf8.decode_rune(text)
	// 0 means the right half of a wide character, so a NUL cell is shown as a blank.
	if width == len(text) {return codepoint == 0 ? ' ' : u32(codepoint)}
	return cluster_intern(c, string(text))
}

@(private)
cluster_intern :: proc(c: ^Client, text: string) -> u32 {
	if index, found := c.cluster_index[text]; found {return GLYPH_CLUSTER | index}
	if len(c.clusters) >= MAX_CLUSTERS {return REPLACEMENT}
	owned, clone_error := strings.clone(text, c.allocator)
	if clone_error != nil {
		c.fault = .Out_Of_Memory
		return REPLACEMENT
	}
	index := u32(len(c.clusters))
	_, slot, _ := map_upsert(&c.cluster_index, owned, index)
	if slot == nil {
		delete(owned, c.allocator)
		c.fault = .Out_Of_Memory
		return REPLACEMENT
	}
	if _, append_error := append(&c.clusters, owned); append_error != nil {
		delete_key(&c.cluster_index, owned)
		delete(owned, c.allocator)
		c.fault = .Out_Of_Memory
		return REPLACEMENT
	}
	return GLYPH_CLUSTER | index
}

@(private)
grid_line :: proc(c: ^Client, r: ^Msgpack_Reader) -> bool {
	line := tuple_open(r) or_return
	grid := tuple_int(&line) or_return
	row := tuple_int(&line) or_return
	column := tuple_int(&line) or_return
	cells := tuple_next(&line) or_return
	if cells.kind != .Array {return false}
	back := &c.back
	writable := grid == 1 && row >= 0 && row < back.rows
	highlight: u32
	for _ in 0 ..< cells.count {
		cell := tuple_open(r) or_return
		text := tuple_bytes(&cell) or_return
		if cell.remaining > 0 {highlight = unsigned_clamped(i64(tuple_int(&cell) or_return))}
		repeat := 1
		if cell.remaining > 0 {repeat = tuple_int(&cell) or_return}
		tuple_close(&cell) or_return
		if !writable {continue}
		first, last := max(column, 0), min(column + repeat, back.columns)
		if first < last {
			line_cells := back.cells[row * back.columns:][:back.columns]
			slice.fill(line_cells[first:last], Cell{cell_glyph(c, text), highlight})
		}
		column += max(repeat, 0)
	}
	return tuple_close(&line)
}

@(private)
grid_scroll :: proc(c: ^Client, r: ^Msgpack_Reader) -> bool {
	t := tuple_open(r) or_return
	grid := tuple_int(&t) or_return
	top := tuple_int(&t) or_return
	bottom := tuple_int(&t) or_return
	left := tuple_int(&t) or_return
	right := tuple_int(&t) or_return
	rows := tuple_int(&t) or_return
	tuple_close(&t) or_return
	back := &c.back
	top, left = max(top, 0), max(left, 0)
	bottom, right = min(bottom, back.rows), min(right, back.columns)
	if grid != 1 || top >= bottom || left >= right || rows == 0 || abs(rows) >= bottom - top {return true}
	if rows > 0 {
		for destination in top ..< bottom - rows {
			row_copy(back, destination, destination + rows, left, right)
		}
	} else {
		for destination := bottom - 1; destination >= top - rows; destination -= 1 {
			row_copy(back, destination, destination + rows, left, right)
		}
	}
	return true
}

@(private)
row_copy :: proc(back: ^Back, destination, source, left, right: int) {
	columns, width := back.columns, right - left
	copy(back.cells[destination * columns + left:][:width], back.cells[source * columns + left:][:width])
}

@(private)
grid_cursor_goto :: proc(c: ^Client, r: ^Msgpack_Reader) -> bool {
	t := tuple_open(r) or_return
	grid := tuple_int(&t) or_return
	row := tuple_int(&t) or_return
	column := tuple_int(&t) or_return
	tuple_close(&t) or_return
	if grid == 1 {c.back.cursor_row, c.back.cursor_column = row, column}
	return true
}

@(private)
grid_size_set :: proc(c: ^Client, columns, rows: int) -> bool {
	back := &c.back
	if columns < 0 || rows < 0 || columns > MAX_GRID_SIDE || rows > MAX_GRID_SIDE {return false}
	if columns * rows > MAX_GRID_CELLS {return false}
	if runtime.resize_dynamic_array(&back.cells, columns * rows) != nil {
		c.fault = .Out_Of_Memory
		return true
	}
	back.columns, back.rows = columns, rows
	slice.fill(back.cells[:], BLANK)
	return true
}

@(private)
grid_resize :: proc(c: ^Client, r: ^Msgpack_Reader) -> bool {
	t := tuple_open(r) or_return
	grid := tuple_int(&t) or_return
	columns := tuple_int(&t) or_return
	rows := tuple_int(&t) or_return
	tuple_close(&t) or_return
	if grid != 1 {return true}
	return grid_size_set(c, columns, rows)
}

@(private)
grid_clear :: proc(c: ^Client, r: ^Msgpack_Reader) -> bool {
	t := tuple_open(r) or_return
	grid := tuple_int(&t) or_return
	tuple_close(&t) or_return
	if grid == 1 {slice.fill(c.back.cells[:], BLANK)}
	return true
}

@(private)
grid_destroy :: proc(c: ^Client, r: ^Msgpack_Reader) -> bool {
	t := tuple_open(r) or_return
	grid := tuple_int(&t) or_return
	tuple_close(&t) or_return
	if grid == 1 {return grid_size_set(c, 0, 0)}
	return true
}

@(private)
color_set :: proc(color: ^Color, value: int) {
	if value >= 0 {color^ = Color(value & 0xFFFFFF)}
}

@(private)
default_colors_set :: proc(c: ^Client, r: ^Msgpack_Reader) -> bool {
	t := tuple_open(r) or_return
	foreground := tuple_int(&t) or_return
	background := tuple_int(&t) or_return
	special := tuple_int(&t) or_return
	tuple_close(&t) or_return
	color_set(&c.back.default_foreground, foreground)
	color_set(&c.back.default_background, background)
	color_set(&c.back.default_special, special)
	return true
}

@(private)
hl_attr_define :: proc(c: ^Client, r: ^Msgpack_Reader) -> bool {
	t := tuple_open(r) or_return
	id := tuple_int(&t) or_return
	attributes := tuple_next(&t) or_return
	if attributes.kind != .Map {return false}
	highlight: Highlight
	for _ in 0 ..< attributes.count {
		key, value := map_next(r) or_return
		switch key {
		case "foreground": if value.kind == .Integer {highlight.foreground = Color(value.integer & 0xFFFFFF)}
		case "background": if value.kind == .Integer {highlight.background = Color(value.integer & 0xFFFFFF)}
		case "special": if value.kind == .Integer {highlight.special = Color(value.integer & 0xFFFFFF)}
		case "blend": if value.kind == .Integer {highlight.blend = u8(clamp(value.integer, 0, 255))}
		case "bold": if value.boolean {highlight.attributes += {.Bold}}
		case "italic": if value.boolean {highlight.attributes += {.Italic}}
		case "reverse": if value.boolean {highlight.attributes += {.Reverse}}
		case "strikethrough": if value.boolean {highlight.attributes += {.Strikethrough}}
		case "underline": if value.boolean {highlight.attributes += {.Underline}}
		case "undercurl": if value.boolean {highlight.attributes += {.Undercurl}}
		case "underdouble": if value.boolean {highlight.attributes += {.Underdouble}}
		case "underdotted": if value.boolean {highlight.attributes += {.Underdotted}}
		case "underdashed": if value.boolean {highlight.attributes += {.Underdashed}}
		}
	}
	tuple_close(&t) or_return
	if id < 0 || id >= MAX_HIGHLIGHTS {return true}
	back := &c.back
	if id >= len(back.highlights) && runtime.resize_dynamic_array(&back.highlights, id + 1) != nil {
		c.fault = .Out_Of_Memory
		return true
	}
	back.highlights[id] = highlight
	back.highlights_changed = true
	return true
}

@(private)
mode_info_set :: proc(c: ^Client, r: ^Msgpack_Reader) -> bool {
	t := tuple_open(r) or_return
	enabled := tuple_next(&t) or_return
	list := tuple_next(&t) or_return
	if enabled.kind != .Boolean || list.kind != .Array {return false}
	back := &c.back
	back.cursor_style_enabled = enabled.boolean
	clear(&back.modes)
	for _ in 0 ..< list.count {
		info, info_error := msgpack_read(r)
		if info_error != .None || info.kind != .Map {return false}
		mode: Mode
		for _ in 0 ..< info.count {
			key, value := map_next(r) or_return
			switch key {
			case "cursor_shape":
				switch string(value.bytes) {
				case "horizontal": mode.shape = .Horizontal
				case "vertical": mode.shape = .Vertical
				case: mode.shape = .Block
				}
			case "cell_percentage": mode.percentage = u8(clamp(value.integer, 0, 100))
			case "blinkwait": mode.blink_wait = unsigned_clamped(value.integer)
			case "blinkon": mode.blink_on = unsigned_clamped(value.integer)
			case "blinkoff": mode.blink_off = unsigned_clamped(value.integer)
			case "attr_id": mode.highlight = unsigned_clamped(value.integer)
			}
		}
		if len(back.modes) >= MAX_MODES {continue}
		if _, append_error := append(&back.modes, mode); append_error != nil {
			c.fault = .Out_Of_Memory
			return true
		}
	}
	return tuple_close(&t)
}

@(private)
mode_change :: proc(c: ^Client, r: ^Msgpack_Reader) -> bool {
	t := tuple_open(r) or_return
	tuple_bytes(&t) or_return
	index := tuple_int(&t) or_return
	tuple_close(&t) or_return
	c.back.mode_index = index
	return true
}

@(private)
empty_args :: proc(r: ^Msgpack_Reader) -> bool {
	t := tuple_open(r) or_return
	return tuple_close(&t)
}

@(private)
busy_start :: proc(c: ^Client, r: ^Msgpack_Reader) -> bool {
	empty_args(r) or_return
	c.back.busy = true
	return true
}

@(private)
busy_stop :: proc(c: ^Client, r: ^Msgpack_Reader) -> bool {
	empty_args(r) or_return
	c.back.busy = false
	return true
}

@(private)
mouse_on :: proc(c: ^Client, r: ^Msgpack_Reader) -> bool {
	empty_args(r) or_return
	c.mouse = true
	return true
}

@(private)
mouse_off :: proc(c: ^Client, r: ^Msgpack_Reader) -> bool {
	empty_args(r) or_return
	c.mouse = false
	return true
}

@(private)
bell :: proc(c: ^Client, r: ^Msgpack_Reader) -> bool {
	empty_args(r) or_return
	c.events.bell = true
	return true
}

@(private)
string_replace :: proc(c: ^Client, destination: ^string, text: []u8) {
	owned, clone_error := strings.clone(string(text), c.allocator)
	if clone_error != nil {
		c.fault = .Out_Of_Memory
		return
	}
	delete(destination^, c.allocator)
	destination^ = owned
}

@(private)
set_title :: proc(c: ^Client, r: ^Msgpack_Reader) -> bool {
	t := tuple_open(r) or_return
	text := tuple_bytes(&t) or_return
	tuple_close(&t) or_return
	string_replace(c, &c.title, text)
	c.events.title_changed = true
	return true
}

@(private)
chdir :: proc(c: ^Client, r: ^Msgpack_Reader) -> bool {
	t := tuple_open(r) or_return
	text := tuple_bytes(&t) or_return
	tuple_close(&t) or_return
	string_replace(c, &c.directory, text)
	c.events.directory_changed = true
	return true
}

@(private)
flush :: proc(c: ^Client, r: ^Msgpack_Reader) -> bool {
	empty_args(r) or_return
	publish(c)
	return true
}

// Copies the back state into the screen. Everything that can fail is allocated first, so a failure
// leaves the previous picture whole.
@(private)
publish :: proc(c: ^Client) {
	back, screen := &c.back, &c.screen
	cells := screen.cells
	if len(cells) != len(back.cells) {
		made, cells_error := make([]Cell, len(back.cells), c.allocator)
		if cells_error != nil {
			c.fault = .Out_Of_Memory
			return
		}
		cells = made
	}
	highlights := screen.highlights
	if back.highlights_changed {
		cloned, clone_error := slice.clone(back.highlights[:], c.allocator)
		if clone_error != nil {
			if raw_data(cells) != raw_data(screen.cells) {delete(cells, c.allocator)}
			c.fault = .Out_Of_Memory
			return
		}
		highlights = cloned
		delete(screen.highlights, c.allocator)
		back.highlights_changed = false
	}
	if raw_data(cells) != raw_data(screen.cells) {delete(screen.cells, c.allocator)}
	copy(cells, back.cells[:])
	screen.cells, screen.highlights = cells, highlights
	screen.columns, screen.rows = back.columns, back.rows
	screen.cursor_row, screen.cursor_column = back.cursor_row, back.cursor_column
	screen.mode = {}
	if back.mode_index >= 0 && back.mode_index < len(back.modes) {screen.mode = back.modes[back.mode_index]}
	screen.cursor_style_enabled, screen.busy = back.cursor_style_enabled, back.busy
	screen.default_foreground = back.default_foreground
	screen.default_background = back.default_background
	screen.default_special = back.default_special
	screen.generation += 1
	c.events.flushed = true
}
