package neovim

import "base:runtime"
import "core:log"
import "core:math"
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

// Grids a peer may create, and the cells all of them may hold together.
@(private)
MAX_GRIDS :: 1 << 10
@(private)
MAX_TOTAL_CELLS :: 1 << 23
// Positions and scroll amounts are clamped to this before they become integers.
@(private)
MAX_COORDINATE :: f64(1 << 20)
// What msg_set_pos sends as zindex from Neovim 0.12; older versions leave it out.
@(private)
MESSAGE_ZINDEX :: 200

@(private)
BLANK :: Cell{glyph = ' '}
@(private)
REPLACEMENT :: u32(0xFFFD)

// One grid's state. Only grid 1 and the grids of shown windows reach the screen.
@(private)
Back_Grid :: struct {
	id: int,
	kind: Grid_Kind,
	// Positioned and not hidden since: a placeholder or a win_hide grid is not drawn.
	shown: bool,
	window: i64,
	row, column: int,
	columns, rows: int,
	cells: []Cell,
	zindex, compindex: int,
	focusable: bool,
	margins: [4]int,
	scrolled: i64,
	layout: u64,
}

// Where a shown grid draws: Window grids by id, then Float and Message grids by (zindex, compindex).
@(private)
Draw_Key :: struct {
	band, zindex, compindex, id, index: int,
}

// The state events mutate; `flush` copies it into Client.screen.
@(private)
Back :: struct {
	// Grid 1: always present, always shown.
	base: Back_Grid,
	// Every other grid, in creation order.
	grids: [dynamic]Back_Grid,
	order: [dynamic]Draw_Key,
	// The last layout value handed out; each grid's layout is unique across all grids.
	layouts: u64,
	cursor_grid, cursor_row, cursor_column: int,
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
	case "win_pos": handler = win_pos
	case "win_float_pos": handler = win_float_pos
	case "msg_set_pos": handler = msg_set_pos
	case "win_hide": handler = win_hide
	case "win_close": handler = win_close
	case "win_external_pos": handler = win_external_pos
	case "win_viewport": handler = win_viewport
	case "win_viewport_margins": handler = win_viewport_margins
	case "mode_info_set": handler = mode_info_set
	case "mode_change": handler = mode_change
	case "busy_start": handler = busy_start
	case "busy_stop": handler = busy_stop
	case "mouse_on": handler = mouse_on
	case "mouse_off": handler = mouse_off
	case "option_set": handler = option_set
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
	id := tuple_int(&line) or_return
	row := tuple_int(&line) or_return
	column := tuple_int(&line) or_return
	cells := tuple_next(&line) or_return
	if cells.kind != .Array {return false}
	grid := grid_find(&c.back, id)
	writable := grid != nil && row >= 0 && row < grid.rows
	highlight: u32
	for _ in 0 ..< cells.count {
		cell := tuple_open(r) or_return
		text := tuple_bytes(&cell) or_return
		if cell.remaining > 0 {highlight = unsigned_clamped(i64(tuple_int(&cell) or_return))}
		repeat := 1
		if cell.remaining > 0 {repeat = tuple_int(&cell) or_return}
		tuple_close(&cell) or_return
		if !writable {continue}
		first, last := max(column, 0), min(column + repeat, grid.columns)
		if first < last {
			line_cells := grid.cells[row * grid.columns:][:grid.columns]
			slice.fill(line_cells[first:last], Cell{cell_glyph(c, text), highlight})
		}
		column += max(repeat, 0)
	}
	return tuple_close(&line)
}

@(private)
grid_scroll :: proc(c: ^Client, r: ^Msgpack_Reader) -> bool {
	t := tuple_open(r) or_return
	id := tuple_int(&t) or_return
	top := tuple_int(&t) or_return
	bottom := tuple_int(&t) or_return
	left := tuple_int(&t) or_return
	right := tuple_int(&t) or_return
	rows := tuple_int(&t) or_return
	tuple_close(&t) or_return
	grid := grid_find(&c.back, id)
	if grid == nil {return true}
	top, left = max(top, 0), max(left, 0)
	bottom, right = min(bottom, grid.rows), min(right, grid.columns)
	if top >= bottom || left >= right || rows == 0 || abs(rows) >= bottom - top {return true}
	if rows > 0 {
		for destination in top ..< bottom - rows {
			row_copy(grid, destination, destination + rows, left, right)
		}
	} else {
		for destination := bottom - 1; destination >= top - rows; destination -= 1 {
			row_copy(grid, destination, destination + rows, left, right)
		}
	}
	return true
}

@(private)
row_copy :: proc(grid: ^Back_Grid, destination, source, left, right: int) {
	columns, width := grid.columns, right - left
	copy(grid.cells[destination * columns + left:][:width], grid.cells[source * columns + left:][:width])
}

@(private)
grid_cursor_goto :: proc(c: ^Client, r: ^Msgpack_Reader) -> bool {
	t := tuple_open(r) or_return
	grid := tuple_int(&t) or_return
	row := tuple_int(&t) or_return
	column := tuple_int(&t) or_return
	tuple_close(&t) or_return
	c.back.cursor_grid, c.back.cursor_row, c.back.cursor_column = grid, row, column
	return true
}

// Grid 1 is always present; every other grid exists from its first grid_resize, win_viewport or
// win_viewport_margins on, hidden until a win_pos, win_float_pos or msg_set_pos positions it.
@(private)
grid_find :: proc(back: ^Back, id: int) -> ^Back_Grid {
	if id == 1 {return &back.base}
	for &grid in back.grids {
		if grid.id == id {return &grid}
	}
	return nil
}

// Nil for grid 0, a negative id or a full table, and after an allocation failure.
@(private)
grid_ensure :: proc(c: ^Client, id: int) -> ^Back_Grid {
	back := &c.back
	if grid := grid_find(back, id); grid != nil {return grid}
	if id < 2 || len(back.grids) >= MAX_GRIDS {return nil}
	back.layouts += 1
	created := Back_Grid{id = id, kind = .Window, focusable = true, layout = back.layouts}
	if _, append_error := append(&back.grids, created); append_error != nil {
		c.fault = .Out_Of_Memory
		return nil
	}
	return &back.grids[len(back.grids) - 1]
}

@(private)
layout_bump :: proc(back: ^Back, grid: ^Back_Grid) {
	back.layouts += 1
	grid.layout = back.layouts
}

@(private)
grid_remove :: proc(c: ^Client, id: int) {
	for &grid, index in c.back.grids {
		if grid.id != id {continue}
		delete(grid.cells, c.allocator)
		ordered_remove(&c.back.grids, index)
		return
	}
}

@(private)
back_destroy :: proc(c: ^Client) {
	delete(c.back.base.cells, c.allocator)
	for &grid in c.back.grids {delete(grid.cells, c.allocator)}
	delete(c.back.grids)
	delete(c.back.order)
	delete(c.back.modes)
	delete(c.back.highlights)
}

@(private)
cells_total :: proc(back: ^Back) -> int {
	total := len(back.base.cells)
	for &grid in back.grids {total += len(grid.cells)}
	return total
}

// Keeps the cells both sizes cover; the rest is blank. False for a size a peer may not ask for.
@(private)
grid_size_set :: proc(c: ^Client, grid: ^Back_Grid, columns, rows: int) -> bool {
	if columns < 0 || rows < 0 || columns > MAX_GRID_SIDE || rows > MAX_GRID_SIDE {return false}
	if columns * rows > MAX_GRID_CELLS {return false}
	if columns == grid.columns && rows == grid.rows {return true}
	if cells_total(&c.back) - len(grid.cells) + columns * rows > MAX_TOTAL_CELLS {return false}
	cells, cells_error := make([]Cell, columns * rows, c.allocator)
	if cells_error != nil {
		c.fault = .Out_Of_Memory
		return true
	}
	slice.fill(cells, BLANK)
	kept := min(columns, grid.columns)
	for row in 0 ..< min(rows, grid.rows) {
		copy(cells[row * columns:][:kept], grid.cells[row * grid.columns:][:kept])
	}
	delete(grid.cells, c.allocator)
	grid.cells, grid.columns, grid.rows = cells, columns, rows
	layout_bump(&c.back, grid)
	return true
}

@(private)
grid_resize :: proc(c: ^Client, r: ^Msgpack_Reader) -> bool {
	t := tuple_open(r) or_return
	id := tuple_int(&t) or_return
	columns := tuple_int(&t) or_return
	rows := tuple_int(&t) or_return
	tuple_close(&t) or_return
	grid := grid_ensure(c, id)
	if grid == nil {return true}
	return grid_size_set(c, grid, columns, rows)
}

@(private)
grid_clear :: proc(c: ^Client, r: ^Msgpack_Reader) -> bool {
	t := tuple_open(r) or_return
	id := tuple_int(&t) or_return
	tuple_close(&t) or_return
	grid := grid_find(&c.back, id)
	if grid == nil {return true}
	slice.fill(grid.cells, BLANK)
	layout_bump(&c.back, grid)
	return true
}

@(private)
grid_destroy :: proc(c: ^Client, r: ^Msgpack_Reader) -> bool {
	t := tuple_open(r) or_return
	id := tuple_int(&t) or_return
	tuple_close(&t) or_return
	if id == 1 {return grid_size_set(c, &c.back.base, 0, 0)}
	grid_remove(c, id)
	return true
}

// A window handle is an ext value holding a msgpack integer; a plain integer is accepted too.
@(private)
tuple_window :: proc(t: ^Tuple) -> (handle: i64, ok: bool) {
	element := tuple_next(t) or_return
	#partial switch element.kind {
	case .Integer: return element.integer, true
	case .Ext:
		inner := Msgpack_Reader{data = element.bytes}
		value, error := msgpack_read(&inner)
		if error != .None || value.kind != .Integer {return 0, false}
		return value.integer, true
	}
	return 0, false
}

// An integer or a float; anything else is no number.
@(private)
tuple_number :: proc(t: ^Tuple) -> (value: f64, ok: bool) {
	element := tuple_next(t) or_return
	#partial switch element.kind {
	case .Integer: return f64(element.integer), true
	case .Float: return element.real, true
	}
	return 0, false
}

// Whole cells for a position a peer sent as a number.
@(private)
cells_from :: proc(value: f64) -> int {
	return int(math.floor(clamp(value, -MAX_COORDINATE, MAX_COORDINATE)))
}

// Shows the grid at an origin; a change of kind, origin or visibility restarts the drawer's
// animations, a repeat of the same placement does not.
@(private)
grid_place :: proc(back: ^Back, grid: ^Back_Grid, kind: Grid_Kind, row, column: int) {
	if !grid.shown || grid.kind != kind || grid.row != row || grid.column != column {
		layout_bump(back, grid)
	}
	grid.shown, grid.kind, grid.row, grid.column = true, kind, row, column
	if kind != .Float {grid.focusable = true}
	if kind == .Window {grid.zindex, grid.compindex = 0, 0}
}

// Only the origin counts: the size in the event may precede the grid's own grid_resize.
@(private)
win_pos :: proc(c: ^Client, r: ^Msgpack_Reader) -> bool {
	t := tuple_open(r) or_return
	id := tuple_int(&t) or_return
	window := tuple_window(&t) or_return
	row := tuple_int(&t) or_return
	column := tuple_int(&t) or_return
	tuple_close(&t) or_return
	if id < 2 {return true}
	grid := grid_ensure(c, id)
	if grid == nil {return true}
	grid_place(&c.back, grid, .Window, row, column)
	grid.window = window
	return true
}

// Neovim 0.12 sends the screen position and the compositor index; older versions leave them out and
// the position is the anchor grid's origin plus the anchor, moved by the float's size to its corner.
@(private)
win_float_pos :: proc(c: ^Client, r: ^Msgpack_Reader) -> bool {
	t := tuple_open(r) or_return
	id := tuple_int(&t) or_return
	window := tuple_window(&t) or_return
	anchor := tuple_bytes(&t) or_return
	anchor_grid := tuple_int(&t) or_return
	anchor_row := tuple_number(&t) or_return
	anchor_column := tuple_number(&t) or_return
	enabled := tuple_next(&t) or_return
	if enabled.kind != .Boolean {return false}
	zindex := tuple_int(&t) or_return
	compindex: int
	screen_row, screen_column: f64
	positioned := t.remaining >= 3
	if positioned {
		compindex = tuple_int(&t) or_return
		screen_row = tuple_number(&t) or_return
		screen_column = tuple_number(&t) or_return
	}
	tuple_close(&t) or_return
	if id < 2 {return true}
	grid := grid_ensure(c, id)
	if grid == nil {return true}
	row, column := cells_from(screen_row), cells_from(screen_column)
	if !positioned {
		row, column = cells_from(anchor_row), cells_from(anchor_column)
		if origin := grid_find(&c.back, anchor_grid); origin != nil {
			row, column = row + origin.row, column + origin.column
		}
		if string(anchor) == "NE" || string(anchor) == "SE" {column -= grid.columns}
		if string(anchor) == "SW" || string(anchor) == "SE" {row -= grid.rows}
	}
	grid_place(&c.back, grid, .Float, row, column)
	grid.window, grid.zindex, grid.compindex, grid.focusable = window, zindex, compindex, enabled.boolean
	return true
}

// The message grid's row 0 is on the screen at `row`; grid 0 stands for the screen itself and is
// not a layer.
@(private)
msg_set_pos :: proc(c: ^Client, r: ^Msgpack_Reader) -> bool {
	t := tuple_open(r) or_return
	id := tuple_int(&t) or_return
	row := tuple_int(&t) or_return
	tuple_next(&t) or_return
	tuple_next(&t) or_return
	zindex, compindex := MESSAGE_ZINDEX, 0
	if t.remaining > 0 {zindex = tuple_int(&t) or_return}
	if t.remaining > 0 {compindex = tuple_int(&t) or_return}
	tuple_close(&t) or_return
	if id < 2 {return true}
	grid := grid_ensure(c, id)
	if grid == nil {return true}
	grid_place(&c.back, grid, .Message, max(row, 0), 0)
	grid.window, grid.zindex, grid.compindex = 0, zindex, compindex
	return true
}

@(private)
win_hide :: proc(c: ^Client, r: ^Msgpack_Reader) -> bool {
	t := tuple_open(r) or_return
	id := tuple_int(&t) or_return
	tuple_close(&t) or_return
	if grid := grid_find(&c.back, id); grid != nil && id != 1 {grid.shown = false}
	return true
}

@(private)
win_close :: proc(c: ^Client, r: ^Msgpack_Reader) -> bool {
	t := tuple_open(r) or_return
	id := tuple_int(&t) or_return
	tuple_close(&t) or_return
	if id != 1 {grid_remove(c, id)}
	return true
}

// An external window is the client's to draw; this one draws none.
@(private)
win_external_pos :: proc(c: ^Client, r: ^Msgpack_Reader) -> bool {
	t := tuple_open(r) or_return
	id := tuple_int(&t) or_return
	tuple_close(&t) or_return
	if grid := grid_find(&c.back, id); grid != nil && id != 1 {grid.shown = false}
	return true
}

@(private)
win_viewport :: proc(c: ^Client, r: ^Msgpack_Reader) -> bool {
	t := tuple_open(r) or_return
	id := tuple_int(&t) or_return
	tuple_window(&t) or_return
	for _ in 0 ..< 4 {tuple_next(&t) or_return}
	delta: f64
	if t.remaining >= 2 {
		tuple_next(&t) or_return
		delta = tuple_number(&t) or_return
	}
	tuple_close(&t) or_return
	grid := grid_ensure(c, id)
	if grid == nil {return true}
	grid.scrolled += i64(math.round(clamp(delta, -MAX_COORDINATE, MAX_COORDINATE)))
	return true
}

@(private)
win_viewport_margins :: proc(c: ^Client, r: ^Msgpack_Reader) -> bool {
	t := tuple_open(r) or_return
	id := tuple_int(&t) or_return
	tuple_window(&t) or_return
	margins: [4]int
	for &margin in margins {margin = max(tuple_int(&t) or_return, 0)}
	tuple_close(&t) or_return
	grid := grid_ensure(c, id)
	if grid == nil || grid.margins == margins {return true}
	grid.margins = margins
	layout_bump(&c.back, grid)
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

// Only 'mousehide' matters to AIODev: off, the pointer stays visible while typing.
@(private)
option_set :: proc(c: ^Client, r: ^Msgpack_Reader) -> bool {
	t := tuple_open(r) or_return
	name := tuple_bytes(&t) or_return
	if string(name) == "mousehide" {
		value := tuple_next(&t) or_return
		if value.kind == .Boolean {c.pointer_kept = !value.boolean}
	}
	return tuple_close(&t)
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
	clear(&back.order)
	for &grid, index in back.grids {
		if !grid.shown {continue}
		key := Draw_Key{id = grid.id, index = index}
		if grid.kind != .Window {key.band, key.zindex, key.compindex = 1, grid.zindex, grid.compindex}
		if _, append_error := append(&back.order, key); append_error != nil {
			c.fault = .Out_Of_Memory
			return
		}
	}
	slice.sort_by(back.order[:], draw_before)
	total := len(back.base.cells)
	for key in back.order {total += len(shown_cells(back, &back.grids[key.index]))}

	pool, views := c.pool, c.views
	if len(pool) < total {
		made, pool_error := make([]Cell, total, c.allocator)
		if pool_error != nil {
			c.fault = .Out_Of_Memory
			return
		}
		pool = made
	}
	if len(views) < len(back.order) + 1 {
		made, views_error := make([]Grid_View, len(back.order) + 1, c.allocator)
		if views_error != nil {
			if raw_data(pool) != raw_data(c.pool) {delete(pool, c.allocator)}
			c.fault = .Out_Of_Memory
			return
		}
		views = made
	}
	highlights := screen.highlights
	if back.highlights_changed {
		cloned, clone_error := slice.clone(back.highlights[:], c.allocator)
		if clone_error != nil {
			if raw_data(pool) != raw_data(c.pool) {delete(pool, c.allocator)}
			if raw_data(views) != raw_data(c.views) {delete(views, c.allocator)}
			c.fault = .Out_Of_Memory
			return
		}
		highlights = cloned
		delete(screen.highlights, c.allocator)
		back.highlights_changed = false
	}
	if raw_data(pool) != raw_data(c.pool) {delete(c.pool, c.allocator)}
	if raw_data(views) != raw_data(c.views) {delete(c.views, c.allocator)}
	c.pool, c.views = pool, views

	base := &back.base
	views[0] = Grid_View{
		id = 1, kind = .Base, columns = base.columns, rows = base.rows, focusable = true,
		margins = base.margins, scrolled = base.scrolled, layout = base.layout,
	}
	views[0].cells = pool[:len(base.cells)]
	copy(views[0].cells, base.cells)
	offset := len(base.cells)
	for key, index in back.order {
		grid := &back.grids[key.index]
		source := shown_cells(back, grid)
		view := Grid_View{
			id = grid.id, kind = grid.kind, window = grid.window, row = grid.row, column = grid.column,
			columns = grid.columns, rows = len(source) / max(grid.columns, 1),
			zindex = grid.zindex, compindex = grid.compindex, focusable = grid.focusable,
			margins = grid.margins, scrolled = grid.scrolled, layout = grid.layout,
		}
		view.cells = pool[offset:][:len(source)]
		copy(view.cells, source)
		offset += len(source)
		views[index + 1] = view
	}
	screen.grids = views[:len(back.order) + 1]
	screen.columns, screen.rows = base.columns, base.rows
	screen.cursor_grid = back.cursor_grid
	screen.cursor_row, screen.cursor_column = back.cursor_row, back.cursor_column
	screen.cursor_screen_row, screen.cursor_screen_column = -1, -1
	for view in screen.grids {
		if view.id != back.cursor_grid {continue}
		screen.cursor_screen_row = view.row + back.cursor_row
		screen.cursor_screen_column = view.column + back.cursor_column
		break
	}
	screen.highlights = highlights
	screen.mode = {}
	if back.mode_index >= 0 && back.mode_index < len(back.modes) {screen.mode = back.modes[back.mode_index]}
	screen.cursor_style_enabled, screen.busy = back.cursor_style_enabled, back.busy
	screen.default_foreground = back.default_foreground
	screen.default_background = back.default_background
	screen.default_special = back.default_special
	screen.generation += 1
	c.events.flushed = true
}

// The cells a grid shows: all of them, except that the message grid ends at the screen's bottom.
@(private)
shown_cells :: proc(back: ^Back, grid: ^Back_Grid) -> []Cell {
	if grid.kind != .Message {return grid.cells}
	return grid.cells[:clamp(back.base.rows - grid.row, 0, grid.rows) * grid.columns]
}

@(private)
draw_before :: proc(a, b: Draw_Key) -> bool {
	if a.band != b.band {return a.band < b.band}
	if a.zindex != b.zindex {return a.zindex < b.zindex}
	if a.compindex != b.compindex {return a.compindex < b.compindex}
	return a.id < b.id
}
