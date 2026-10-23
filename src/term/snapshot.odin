package term

import "aio:ghostty"
import "base:runtime"
import "core:log"

Snapshot_Cell :: struct {
	text:                   string,
	width:                  ghostty.Cell_Wide,
	style:                  ghostty.Style,
	foreground, background: Maybe(Color),
	selected:               bool,
}

Snapshot :: struct {
	columns, rows:          u16,
	cells:                  [dynamic]Snapshot_Cell,
	cursor:                 ghostty.Render_State_Cursor,
	foreground, background: Color,
	cursor_color:           Maybe(Color),
	palette:                [256]Color,
	text:                   [dynamic]u8,
}

@(private, require_results)
snapshot_result :: proc(result: ghostty.Result, operation: string) -> Error {
	if result == .Success {return .None}
	log.errorf("term: snapshot %s failed: %v", operation, result)
	return result == .Out_Of_Memory ? .Out_Of_Memory : .Terminal_Failed
}

@(private)
snapshot_color :: proc(rgb: ghostty.Color_Rgb) -> Color {
	return {rgb.r, rgb.g, rgb.b}
}

@(require_results)
snapshot :: proc(
	state: ghostty.Render_State,
	allocator := context.allocator,
) -> (
	Snapshot,
	Error,
) {
	s := Snapshot {
		cells = make([dynamic]Snapshot_Cell, allocator),
		text  = make([dynamic]u8, allocator),
	}
	ok := false
	defer if !ok {snapshot_destroy(&s)}
	rows: ghostty.Render_State_Row_Iterator
	if err := snapshot_result(ghostty.render_state_row_iterator_new(nil, &rows), "creating rows");
	   err != .None {return {}, err}
	defer ghostty.render_state_row_iterator_free(rows)
	cells: ghostty.Render_State_Row_Cells
	if err := snapshot_result(ghostty.render_state_row_cells_new(nil, &cells), "creating cells");
	   err != .None {return {}, err}
	defer ghostty.render_state_row_cells_free(cells)
	s.cursor = ghostty.sized(ghostty.Render_State_Cursor)
	colors := ghostty.sized(ghostty.Render_State_Colors)
	keys := [?]ghostty.Render_State_Data{.Cols, .Rows, .Cursor, .Colors, .Row_Iterator}
	values := [?]rawptr{&s.columns, &s.rows, &s.cursor, &colors, &rows}
	result := ghostty.render_state_get_multi(state, len(keys), &keys[0], &values[0], nil)
	if err := snapshot_result(result, "reading state"); err != .None {return {}, err}
	s.foreground, s.background =
		snapshot_color(colors.foreground), snapshot_color(colors.background)
	if colors.cursor_has_value {s.cursor_color = snapshot_color(colors.cursor)}
	for c, i in colors.palette {s.palette[i] = snapshot_color(c)}
	if runtime.resize(&s.cells, int(s.columns) * int(s.rows)) != nil {return {}, .Out_Of_Memory}
	offsets, allocation_error := make([]int, len(s.cells), allocator)
	if allocation_error != nil {return {}, .Out_Of_Memory}
	defer delete(offsets, allocator)
	for ghostty.render_state_row_iterator_next(rows) {
		y: i32
		if err := snapshot_result(
			ghostty.render_state_row_get(rows, .Viewport_Y, &y),
			"reading row position",
		); err != .None {return {}, err}
		if y < 0 || y >= i32(s.rows) {continue}
		if err := snapshot_result(
			ghostty.render_state_row_get(rows, .Cells, &cells),
			"reading row cells",
		); err != .None {return {}, err}
		for x in 0 ..< int(s.columns) {
			if err := snapshot_result(
				ghostty.render_state_row_cells_select(cells, u16(x)),
				"selecting cell",
			); err != .None {return {}, err}
			index := int(y) * int(s.columns) + x
			offsets[index] = len(s.text)
			c := &s.cells[index]
			if err := snapshot_read_cell(cells, c, &s.text); err != .None {return {}, err}
		}
	}
	// Rebind strings after the shared buffer stops growing; only their lengths survive reallocations.
	for &c, i in s.cells {
		offset := offsets[i]
		n := len(c.text)
		c.text = string(s.text[offset:offset + n])
	}
	ok = true
	return s, .None
}

@(private, require_results)
snapshot_read_cell :: proc(
	cells: ghostty.Render_State_Row_Cells,
	c: ^Snapshot_Cell,
	text: ^[dynamic]u8,
) -> Error {
	raw: ghostty.Cell
	c.style = ghostty.sized(ghostty.Style)
	keys := [?]ghostty.Render_State_Row_Cells_Data{.Raw, .Style, .Selected}
	values := [?]rawptr{&raw, &c.style, &c.selected}
	result := ghostty.render_state_row_cells_get_multi(cells, len(keys), &keys[0], &values[0], nil)
	if err := snapshot_result(result, "reading cell"); err != .None {return err}
	if err := snapshot_result(ghostty.cell_get(raw, .Wide, &c.width), "reading cell width");
	   err != .None {return err}
	color_keys := [?]ghostty.Render_State_Row_Cells_Data{.Fg_Color, .Bg_Color}
	for key, i in color_keys {
		rgb: ghostty.Color_Rgb
		result = ghostty.render_state_row_cells_get(cells, key, &rgb)
		if result == .Invalid_Value {continue}
		if err := snapshot_result(result, "reading cell color"); err != .None {return err}
		if i == 0 {c.foreground = snapshot_color(rgb)} else {c.background = snapshot_color(rgb)}
	}
	if c.width == .Spacer_Tail || c.width == .Spacer_Head {return .None}
	buffer: ghostty.Buffer
	result = ghostty.render_state_row_cells_get(cells, .Graphemes_Utf8, &buffer)
	if result == .Success {return .None}
	if result != .Out_Of_Space {
		return snapshot_result(result, "measuring cell text")
	}
	start := len(text)
	if buffer.len > uint(max(int) - start) {return .Out_Of_Memory}
	if runtime.resize(text, start + int(buffer.len)) != nil {return .Out_Of_Memory}
	buffer.ptr, buffer.cap = raw_data(text^[start:]), buffer.len
	result = ghostty.render_state_row_cells_get(cells, .Graphemes_Utf8, &buffer)
	if err := snapshot_result(result, "reading cell text"); err != .None {return err}
	c.text = string(text^[start:start + int(buffer.len)])
	return .None
}

snapshot_destroy :: proc(s: ^Snapshot) {
	delete(s.cells)
	delete(s.text)
	s^ = {}
}

snapshot_cell :: proc(s: ^Snapshot, column, row: int) -> ^Snapshot_Cell {
	if column < 0 || row < 0 || column >= int(s.columns) || row >= int(s.rows) {return nil}
	return &s.cells[row * int(s.columns) + column]
}

// One row's displayed text laid out by column: a wide glyph's text sits at its first
// column, the columns it covers are empty, and spacer halves are empty. The strings
// refer to the snapshot's cell text.
Row_Map :: struct {
	columns: []string,
	text:    string,
}

@(require_results)
row_map :: proc(
	s: ^Snapshot,
	row: int,
	allocator := context.allocator,
) -> (
	Row_Map,
	Error,
) {
	if row < 0 || row >= int(s.rows) {return {}, .None}
	m: Row_Map
	ok := false
	defer if !ok {row_map_destroy(&m, allocator)}
	cells := s.cells[row * int(s.columns):(row + 1) * int(s.columns)]
	columns, columns_error := make([]string, len(cells), allocator)
	if columns_error != nil {return {}, .Out_Of_Memory}
	m.columns = columns
	count := 0
	for c, x in cells {
		if c.width == .Spacer_Tail || c.width == .Spacer_Head {continue}
		text := c.text
		if text == "" {text = " "}
		m.columns[x] = text
		count += len(text)
	}
	buffer, buffer_error := make([]u8, count, allocator)
	if buffer_error != nil {return {}, .Out_Of_Memory}
	at := 0
	for text in m.columns {at += copy(buffer[at:], text)}
	for at > 0 && buffer[at - 1] == ' ' {at -= 1}
	m.text = string(buffer[:at])
	ok = true
	return m, .None
}

row_map_destroy :: proc(m: ^Row_Map, allocator := context.allocator) {
	delete(m.columns, allocator)
	delete(m.text, allocator)
	m^ = {}
}

@(require_results)
row_text :: proc(s: ^Snapshot, row: int, allocator := context.allocator) -> (string, Error) {
	m, err := row_map(s, row, allocator)
	if err != .None {return "", err}
	delete(m.columns, allocator)
	return m.text, .None
}
