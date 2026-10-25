package term

import "aio:ghostty"
import "aio:links"
import "base:runtime"
import "core:sync"
import "core:unicode/utf8"

// Link_Range names the cells of one target. Rows and columns are viewport coordinates, and the
// last cell is inclusive. A target broken by a soft wrap covers the tail of the first row, whole
// middle rows, and the head of the last row.
Link_Range :: struct {
	first_row, last_row:       int,
	first_column, last_column: int,
}

// Link_Span keeps its target in the map's byte buffer so a scan can grow without invalidating
// earlier spans.
Link_Span :: struct {
	range:                 Link_Range,
	uri_start, uri_length: int,
}

// Link_Map is one viewport's links. OSC 8 spans come first, so a target carried by the terminal
// wins over text that only looks like a URL. A cell with an OSC 8 link of any scheme is occupied
// even when the scheme is refused, which keeps plain detection from reviving a link the terminal
// marked as something else.
Link_Map :: struct {
	spans:                 [dynamic]Link_Span,
	text:                  [dynamic]u8,
	row_text:              [dynamic]u8,
	row_cell:              [dynamic]int,
	row_start, row_length: [dynamic]int,
	row_wrap:              [dynamic]bool,
	occupied:              [dynamic]bool,
	line_text:             [dynamic]u8,
	line_cell:             [dynamic]int,
	uri:                   [dynamic]u8,
	urls:                  [dynamic]links.Range,
	columns, rows:         int,
	generation:            u64,
	valid:                 bool,
}

@(private)
PREFIX_ROW_LIMIT :: 512
@(private)
PREFIX_BYTE_LIMIT :: 64 * 1024

@(require_results)
link_map_create :: proc(m: ^Link_Map, allocator := context.allocator) -> bool {
	err: runtime.Allocator_Error
	m.spans, err = make([dynamic]Link_Span, allocator)
	ok := err == nil
	m.text, err = make([dynamic]u8, allocator)
	ok &&= err == nil
	m.row_text, err = make([dynamic]u8, allocator)
	ok &&= err == nil
	m.row_cell, err = make([dynamic]int, allocator)
	ok &&= err == nil
	m.row_start, err = make([dynamic]int, allocator)
	ok &&= err == nil
	m.row_length, err = make([dynamic]int, allocator)
	ok &&= err == nil
	m.row_wrap, err = make([dynamic]bool, allocator)
	ok &&= err == nil
	m.occupied, err = make([dynamic]bool, allocator)
	ok &&= err == nil
	m.line_text, err = make([dynamic]u8, allocator)
	ok &&= err == nil
	m.line_cell, err = make([dynamic]int, allocator)
	ok &&= err == nil
	m.uri, err = make([dynamic]u8, allocator)
	ok &&= err == nil
	m.urls, err = make([dynamic]links.Range, allocator)
	ok &&= err == nil
	if !ok {
		link_map_destroy(m)
	}
	return ok
}

link_map_destroy :: proc(m: ^Link_Map) {
	delete(m.spans)
	delete(m.text)
	delete(m.row_text)
	delete(m.row_cell)
	delete(m.row_start)
	delete(m.row_length)
	delete(m.row_wrap)
	delete(m.occupied)
	delete(m.line_text)
	delete(m.line_cell)
	delete(m.uri)
	delete(m.urls)
	m^ = {}
}

// link_at returns the first span covering a viewport cell. OSC 8 spans are stored first, so they
// take precedence over a plain URL detected over the same cells.
@(require_results)
link_at :: proc(
	m: ^Link_Map,
	column, row: int,
) -> (
	range: Link_Range,
	uri: string,
	found: bool,
) {
	if !m.valid || column < 0 || column >= m.columns || row < 0 || row >= m.rows {
		return {}, "", false
	}
	for span in m.spans {
		if row < span.range.first_row || row > span.range.last_row {
			continue
		}
		if !range_contains(span.range, column, row) {
			continue
		}
		start := span.uri_start
		return span.range, string(m.text[start:start + span.uri_length]), true
	}
	return {}, "", false
}

@(private, require_results)
range_contains :: proc(r: Link_Range, column, row: int) -> bool {
	if row == r.first_row && row == r.last_row {
		return column >= r.first_column && column <= r.last_column
	}
	if row == r.first_row {
		return column >= r.first_column
	}
	if row == r.last_row {
		return column <= r.last_column
	}
	return row > r.first_row && row < r.last_row
}

// link_map_scan reads the live viewport under the session lock. The pointer never reaches
// libghostty: callers scan after the grid changes, then hit-test the stored spans on hover.
@(require_results)
link_map_scan :: proc(m: ^Link_Map, s: ^Session) -> bool {
	sync.mutex_lock(&s.mutex)
	defer sync.mutex_unlock(&s.mutex)
	ok := link_map_scan_locked(m, s.terminal, int(s.geometry.columns), int(s.geometry.rows))
	if ok {
		m.generation = sync.atomic_load(&s.generation)
	} else {
		m.valid, m.generation = false, 0
	}
	return ok
}

@(private)
Cell_Value :: struct {
	codepoint: u32,
	wide:      ghostty.Cell_Wide,
	has_text:  bool,
	has_link:  bool,
	ok:        bool,
}

@(private, require_results)
cell_value :: proc(
	terminal: ghostty.Terminal,
	tag: ghostty.Point_Tag,
	x: u16,
	y: u32,
) -> (
	value: Cell_Value,
	ref: ghostty.Grid_Ref,
	ok: bool,
) {
	point := ghostty.Point{tag = tag, value = {coordinate = {x = x, y = y}}}
	ref = ghostty.sized(ghostty.Grid_Ref)
	if ghostty.terminal_grid_ref(terminal, point, &ref) != .Success {
		return {}, ref, false
	}
	cell: ghostty.Cell
	if ghostty.grid_ref_cell(&ref, &cell) != .Success {
		return {}, ref, false
	}
	keys := [?]ghostty.Cell_Data{.Codepoint, .Wide, .Has_Text, .Has_Hyperlink}
	values := [?]rawptr{&value.codepoint, &value.wide, &value.has_text, &value.has_link}
	if ghostty.cell_get_multi(cell, len(keys), &keys[0], &values[0], nil) != .Success {
		return {}, ref, false
	}
	value.ok = true
	return value, ref, true
}

@(private, require_results)
row_continues :: proc(terminal: ghostty.Terminal, tag: ghostty.Point_Tag, y: u32) -> bool {
	point := ghostty.Point{tag = tag, value = {coordinate = {x = 0, y = y}}}
	ref := ghostty.sized(ghostty.Grid_Ref)
	if ghostty.terminal_grid_ref(terminal, point, &ref) != .Success {
		return false
	}
	row: ghostty.Row
	if ghostty.grid_ref_row(&ref, &row) != .Success {
		return false
	}
	continuation: bool
	if ghostty.row_get(row, .Wrap_Continuation, &continuation) != .Success {
		return false
	}
	return continuation
}

@(private, require_results)
append_cell :: proc(
	value: Cell_Value,
	column, row, columns: int,
	text: ^[dynamic]u8,
	cells: ^[dynamic]int,
) -> bool {
	index := row < 0 ? -1 : row * columns + column
	if !value.ok || !value.has_text || value.codepoint == 0 {
		if _, err := append(text, ' '); err != nil {
			return false
		}
		if _, err := append(cells, index); err != nil {
			return false
		}
		return true
	}
	if value.wide == .Spacer_Tail || value.wide == .Spacer_Head {
		return true
	}
	bytes, count := utf8.encode_rune(rune(value.codepoint))
	for i in 0 ..< count {
		if _, err := append(text, bytes[i]); err != nil {
			return false
		}
		if _, err := append(cells, index); err != nil {
			return false
		}
	}
	return true
}

@(private, require_results)
append_range :: proc(text: ^[dynamic]u8, cells: ^[dynamic]int, from: []u8, from_cells: []int) -> bool {
	if _, err := append(text, ..from); err != nil {
		return false
	}
	if _, err := append(cells, ..from_cells); err != nil {
		return false
	}
	return true
}

@(private, require_results)
append_screen_row :: proc(
	m: ^Link_Map,
	terminal: ghostty.Terminal,
	y: u32,
	columns: int,
) -> bool {
	for x in 0 ..< columns {
		value, _, _ := cell_value(terminal, .Screen, u16(x), y)
		if !append_cell(value, x, -1, columns, &m.line_text, &m.line_cell) {
			return false
		}
	}
	return true
}

@(private, require_results)
screen_top :: proc(terminal: ghostty.Terminal) -> (u32, bool) {
	top := ghostty.Point_Coordinate{}
	point := ghostty.Point{tag = .Viewport, value = {coordinate = {x = 0, y = 0}}}
	ref := ghostty.sized(ghostty.Grid_Ref)
	if ghostty.terminal_grid_ref(terminal, point, &ref) != .Success ||
	   ghostty.terminal_point_from_grid_ref(terminal, &ref, .Screen, &top) != .Success {
		return 0, false
	}
	return top.y, true
}

@(private, require_results)
prefix_bytes :: proc(
	m: ^Link_Map,
	terminal: ghostty.Terminal,
	columns: int,
) -> (
	bytes: int,
	ok: bool,
) {
	rows := [PREFIX_ROW_LIMIT]u32{}
	count := 0
	top, found := screen_top(terminal)
	if !found {
		return 0, true
	}
	cursor := top
	for count < len(rows) && cursor > 0 {
		previous := cursor - 1
		rows[count] = previous
		count += 1
		if !row_continues(terminal, .Screen, previous) {
			break
		}
		cursor = previous
	}
	before := len(m.line_text)
	for i := count - 1; i >= 0; i -= 1 {
		if !append_screen_row(m, terminal, rows[i], columns) {
			return 0, false
		}
		if len(m.line_text) - before > PREFIX_BYTE_LIMIT {
			return 0, false
		}
	}
	return len(m.line_text) - before, true
}

@(private, require_results)
suffix_bytes :: proc(
	m: ^Link_Map,
	terminal: ghostty.Terminal,
	columns, rows: int,
) -> (
	bytes: int,
	ok: bool,
) {
	top, found := screen_top(terminal)
	if !found {
		return 0, true
	}
	before := len(m.line_text)
	cursor := top + u32(rows)
	count := 0
	for count < PREFIX_ROW_LIMIT && row_continues(terminal, .Screen, cursor) {
		if !append_screen_row(m, terminal, cursor, columns) {
			return 0, false
		}
		count += 1
		cursor += 1
		if len(m.line_text) - before > PREFIX_BYTE_LIMIT {
			return 0, false
		}
	}
	return len(m.line_text) - before, true
}

@(private, require_results)
same_uri :: proc(m: ^Link_Map, a, b: Link_Span) -> bool {
	if a.uri_length != b.uri_length {
		return false
	}
	for i in 0 ..< a.uri_length {
		if m.text[a.uri_start + i] != m.text[b.uri_start + i] {
			return false
		}
	}
	return true
}

@(private, require_results)
merge_wrapped :: proc(m: ^Link_Map, count, columns: int) -> int {
	kept := 0
	for i in 0 ..< count {
		if kept == 0 {
			m.spans[kept] = m.spans[i]
			kept += 1
			continue
		}
		previous := &m.spans[kept - 1]
		current := m.spans[i]
		wrapped :=
			current.range.first_row == previous.range.last_row + 1 &&
			current.range.first_row < len(m.row_wrap) &&
			m.row_wrap[current.range.first_row] &&
			previous.range.last_column == columns - 1 &&
			current.range.first_column == 0 &&
			same_uri(m, previous^, current)
		if wrapped {
			previous.range.last_row = current.range.last_row
			previous.range.last_column = current.range.last_column
		} else {
			m.spans[kept] = current
			kept += 1
		}
	}
	return kept
}

@(private, require_results)
append_span :: proc(m: ^Link_Map, y, first, last, start, length: int) -> bool {
	if _, err := append(
		&m.spans,
		Link_Span {
			range = {first_row = y, last_row = y, first_column = first, last_column = last},
			uri_start = start,
			uri_length = length,
		},
	); err != nil {
		return false
	}
	return true
}

@(private, require_results)
scan_text :: proc(m: ^Link_Map, terminal: ghostty.Terminal, columns, rows: int) -> bool {
	for y in 0 ..< rows {
		m.row_start[y] = len(m.row_text)
		point := ghostty.Point{tag = .Viewport, value = {coordinate = {x = 0, y = u32(y)}}}
		ref := ghostty.sized(ghostty.Grid_Ref)
		if ghostty.terminal_grid_ref(terminal, point, &ref) != .Success {
			return false
		}
		row: ghostty.Row
		if ghostty.grid_ref_row(&ref, &row) != .Success {
			return false
		}
		wrap, has_links := false, false
		row_keys := [?]ghostty.Row_Data{.Wrap_Continuation, .Hyperlink}
		row_values := [?]rawptr{&wrap, &has_links}
		if ghostty.row_get_multi(row, len(row_keys), &row_keys[0], &row_values[0], nil) != .Success {
			return false
		}
		m.row_wrap[y] = wrap
		run_active := false
		run_first, run_last := 0, 0
		run_start, run_length := 0, 0
		for x in 0 ..< columns {
			value, cell_ref, ok := cell_value(terminal, .Viewport, u16(x), u32(y))
			if !append_cell(value, x, y, columns, &m.row_text, &m.row_cell) {
				return false
			}
			index := y * columns + x
			linked := ok && value.has_link
			if linked {
				m.occupied[index] = true
			}
			uri := ""
			if linked && has_links {
				needed: uint
				query := ghostty.grid_ref_hyperlink_uri(&cell_ref, nil, 0, &needed)
				if (query == .Success || query == .Out_Of_Space) &&
				   needed > 0 &&
				   runtime.resize(&m.uri, int(needed)) == nil {
					written := needed
					if ghostty.grid_ref_hyperlink_uri(
						   &cell_ref,
						   raw_data(m.uri),
						   needed,
						   &written,
					   ) == .Success {
						uri = string(m.uri[:written])
					}
				}
			}
			usable := uri != "" && links.allowed(uri)
			if usable &&
			   run_active &&
			   x == run_last + 1 &&
			   len(uri) == run_length &&
			   string(m.text[run_start:run_start + run_length]) == uri {
				run_last = x
				continue
			}
			if run_active {
				if !append_span(m, y, run_first, run_last, run_start, run_length) {
					return false
				}
				run_active = false
			}
			if !usable {
				continue
			}
			run_start, run_length = len(m.text), len(uri)
			if _, err := append(&m.text, uri); err != nil {
				return false
			}
			run_first, run_last, run_active = x, x, true
		}
		if run_active {
			if !append_span(m, y, run_first, run_last, run_start, run_length) {
				return false
			}
		}
		m.row_length[y] = len(m.row_text) - m.row_start[y]
	}
	return true
}

@(private, require_results)
scan_lines :: proc(m: ^Link_Map, terminal: ghostty.Terminal, columns, rows: int) -> bool {
	y := 0
	for y < rows {
		clear(&m.line_text)
		clear(&m.line_cell)
		if y == 0 && m.row_wrap[0] {
			if _, ok := prefix_bytes(m, terminal, columns); !ok {
				return false
			}
		}
		end := y
		for {
			start := m.row_start[end]
			length := m.row_length[end]
			if !append_range(
				&m.line_text,
				&m.line_cell,
				m.row_text[start:start + length],
				m.row_cell[start:start + length],
			) {
				return false
			}
			if end + 1 >= rows || !m.row_wrap[end + 1] {
				break
			}
			end += 1
		}
		if end == rows - 1 {
			if _, ok := suffix_bytes(m, terminal, columns, rows); !ok {
				return false
			}
		}
		clear(&m.urls)
		if !links.find(string(m.line_text[:]), &m.urls) {
			return false
		}
		for url in m.urls {
			first, last := -1, -1
			blocked := false
			for i in url.start ..< url.end {
				cell := m.line_cell[i]
				if cell < 0 {
					continue
				}
				if first < 0 {
					first = cell
				}
				last = cell
				if cell < len(m.occupied) && m.occupied[cell] {
					blocked = true
					break
				}
			}
			if blocked || first < 0 || last < first {
				continue
			}
			uri_start := len(m.text)
			if _, err := append(&m.text, ..m.line_text[url.start:url.end]); err != nil {
				return false
			}
			if _, err := append(
				&m.spans,
				Link_Span {
					range = {
						first_row    = first / columns,
						first_column = first % columns,
						last_row     = last / columns,
						last_column  = last % columns,
					},
					uri_start  = uri_start,
					uri_length = url.end - url.start,
				},
			); err != nil {
				return false
			}
		}
		y = end + 1
	}
	return true
}

@(private, require_results)
link_map_scan_locked :: proc(
	m: ^Link_Map,
	terminal: ghostty.Terminal,
	columns, rows: int,
) -> bool {
	m.valid = false
	clear(&m.spans)
	clear(&m.text)
	clear(&m.row_text)
	clear(&m.row_cell)
	clear(&m.urls)
	m.columns, m.rows = max(columns, 0), max(rows, 0)
	if columns <= 0 || rows <= 0 {
		m.valid = true
		return true
	}
	if runtime.resize(&m.row_start, rows) != nil ||
	   runtime.resize(&m.row_length, rows) != nil ||
	   runtime.resize(&m.row_wrap, rows) != nil {
		return false
	}
	for &value in m.row_wrap {
		value = false
	}
	if runtime.resize(&m.occupied, columns * rows) != nil {
		return false
	}
	for &value in m.occupied {
		value = false
	}
	if !scan_text(m, terminal, columns, rows) {
		return false
	}
	count := merge_wrapped(m, len(m.spans), columns)
	if runtime.resize(&m.spans, count) != nil {
		return false
	}
	if !scan_lines(m, terminal, columns, rows) {
		return false
	}
	m.valid = true
	return true
}

when ODIN_TEST {
	// The production entry point takes the session lock; tests that own a bare terminal call this
	// one so they can drive libghostty without a PTY.
	@(require_results)
	link_map_scan_terminal :: proc(
		m: ^Link_Map,
		terminal: ghostty.Terminal,
		columns, rows: int,
	) -> bool {
		return link_map_scan_locked(m, terminal, columns, rows)
	}
}
