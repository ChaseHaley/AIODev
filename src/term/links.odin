package term

import "aio:ghostty"
import "aio:links"
import "aio:localpath"
import "base:runtime"
import "core:strings"
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
	range:                    Link_Range,
	uri_start, uri_length:    int,
	// A detected file keeps its whole line, so a click can check readings the scan could not settle.
	line_start, line_length:  int,
	target_start, target_end: int,
	cuts_start, cuts_length:  int,
}

// Link_Target is what a click needs to open a span. Its strings and cuts borrow the map until the
// next scan. Row breaks in line are newlines; cuts are where a program broke a word.
Link_Target :: struct {
	range:      Link_Range,
	uri, line:  string,
	start, end: int,
	cuts:       []int,
}

// Link_Map is one viewport's links. OSC 8 spans come first, so a target carried by the terminal
// wins over text that only looks like a URL. A cell with an OSC 8 link of any scheme is occupied
// even when the scheme is refused, which keeps plain detection from reviving a link the terminal
// marked as something else. Selected text that can name a target is kept apart, ahead of all spans.
Link_Map :: struct {
	spans:                 [dynamic]Link_Span,
	text:                  [dynamic]u8,
	row_text:              [dynamic]u8,
	row_cell:              [dynamic]int,
	row_start, row_length: [dynamic]int,
	row_wrap:              [dynamic]bool,
	row_join:              [dynamic]links.Row_Join,
	occupied:              [dynamic]bool,
	line_text:             [dynamic]u8,
	line_cell:             [dynamic]int,
	line_cuts:             [dynamic]int,
	cuts:                  [dynamic]int,
	uri:                   [dynamic]u8,
	urls:                  [dynamic]links.Range,
	selection_line:        [dynamic]u8,
	selection_uri:         [dynamic]u8,
	selection_range:       Link_Range,
	selection_target:      links.Range,
	selection_active:      bool,
	columns, rows:         int,
	generation:            u64,
	valid:                 bool,
	relative_files:        bool,
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
	m.row_join, err = make([dynamic]links.Row_Join, allocator)
	ok &&= err == nil
	m.occupied, err = make([dynamic]bool, allocator)
	ok &&= err == nil
	m.line_text, err = make([dynamic]u8, allocator)
	ok &&= err == nil
	m.line_cell, err = make([dynamic]int, allocator)
	ok &&= err == nil
	m.line_cuts, err = make([dynamic]int, allocator)
	ok &&= err == nil
	m.cuts, err = make([dynamic]int, allocator)
	ok &&= err == nil
	m.uri, err = make([dynamic]u8, allocator)
	ok &&= err == nil
	m.urls, err = make([dynamic]links.Range, allocator)
	ok &&= err == nil
	m.selection_line, err = make([dynamic]u8, allocator)
	ok &&= err == nil
	m.selection_uri, err = make([dynamic]u8, allocator)
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
	delete(m.row_join)
	delete(m.occupied)
	delete(m.line_text)
	delete(m.line_cell)
	delete(m.line_cuts)
	delete(m.cuts)
	delete(m.uri)
	delete(m.urls)
	delete(m.selection_line)
	delete(m.selection_uri)
	m^ = {}
}

// link_at returns what a viewport cell opens: selected text that can name a target, then the first
// span covering it. OSC 8 spans are stored first, so they take precedence over a plain URL detected
// over the same cells.
@(require_results)
link_at :: proc(
	m: ^Link_Map,
	column, row: int,
) -> (
	range: Link_Range,
	uri: string,
	found: bool,
) {
	target, hit := link_selection_at(m, column, row)
	if !hit {
		target, hit = link_detected_at(m, column, row)
	}
	return target.range, target.uri, hit
}

// link_selection_at returns the selected text when the cell is inside a selection that can name a
// target. Line is the whole normalized selection, and start and end bound the target within it.
@(require_results)
link_selection_at :: proc(m: ^Link_Map, column, row: int) -> (target: Link_Target, found: bool) {
	if !m.valid || !m.selection_active || !range_contains(m.selection_range, column, row, m.columns) {
		return {}, false
	}
	return {
		range = m.selection_range,
		uri = string(m.selection_uri[:]),
		line = string(m.selection_line[:]),
		start = m.selection_target.start,
		end = m.selection_target.end,
	}, true
}

@(require_results)
link_detected_at :: proc(m: ^Link_Map, column, row: int) -> (target: Link_Target, found: bool) {
	if !m.valid || column < 0 || column >= m.columns || row < 0 || row >= m.rows {
		return {}, false
	}
	for span in m.spans {
		if row < span.range.first_row || row > span.range.last_row {
			continue
		}
		if !range_contains(span.range, column, row, m.columns) {
			continue
		}
		uri := span.uri_start
		line := span.line_start
		cuts := span.cuts_start
		return {
			range = span.range,
			uri = string(m.text[uri:uri + span.uri_length]),
			line = string(m.text[line:line + span.line_length]),
			start = span.target_start,
			end = span.target_end,
			cuts = m.cuts[cuts:cuts + span.cuts_length],
		}, true
	}
	return {}, false
}

@(private, require_results)
range_contains :: proc(r: Link_Range, column, row, columns: int) -> bool {
	first, last, present := link_range_columns(r, row, columns)
	return present && column >= first && column <= last
}

// The columns of `row` that `r` covers, both inclusive, within a grid `columns` wide: the tail of its
// first row, whole middle rows and the head of its last row. Hit-testing and the drawn underline both
// read a range through this. Not present when the row is outside the range.
@(require_results)
link_range_columns :: proc(r: Link_Range, row, columns: int) -> (first, last: int, present: bool) {
	if row < r.first_row || row > r.last_row {return 0, -1, false}
	first, last = 0, columns - 1
	if row == r.first_row {first = max(r.first_column, 0)}
	if row == r.last_row {last = min(r.last_column, columns - 1)}
	return first, last, first <= last
}

// How many links the map holds: what verification reports as the pane's spans.
link_span_count :: proc(m: ^Link_Map) -> int {
	return len(m.spans)
}

// Rescans the live viewport only when the terminal changed since the last scan, so hover hit-tests
// read the stored spans without touching libghostty. False leaves the map invalid.
@(require_results)
link_map_refresh :: proc(m: ^Link_Map, s: ^Session) -> bool {
	if m.valid && m.generation == generation(s) {
		return true
	}
	return link_map_scan(m, s)
}

// link_map_scan reads the live viewport under the session lock. The pointer never reaches
// libghostty: callers scan after the grid changes, then hit-test the stored spans on hover.
@(private, require_results)
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
	ref: ghostty.Grid_Ref
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
	if value.ok && (value.wide == .Spacer_Tail || value.wide == .Spacer_Head) {
		return true
	}
	if !value.ok || !value.has_text || value.codepoint == 0 {
		if _, err := append(text, ' '); err != nil {
			return false
		}
		if _, err := append(cells, index); err != nil {
			return false
		}
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
	ref: ghostty.Grid_Ref
	if ghostty.terminal_grid_ref(terminal, point, &ref) != .Success ||
	   ghostty.terminal_point_from_grid_ref(terminal, &ref, .Screen, &top) != .Success {
		return 0, false
	}
	return top.y, true
}

@(private, require_results)
has_space :: proc(bytes: []u8) -> bool {
	for c in bytes {
		if c == ' ' || c == '\t' {
			return true
		}
	}
	return false
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
		row_start := len(m.line_text)
		if !append_screen_row(m, terminal, rows[i], columns) {
			return 0, false
		}
		if len(m.line_text) - before > PREFIX_BYTE_LIMIT {
			return 0, false
		}
		if has_space(m.line_text[row_start:]) {
			break
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
		row_start := len(m.line_text)
		if !append_screen_row(m, terminal, cursor, columns) {
			return 0, false
		}
		count += 1
		cursor += 1
		if len(m.line_text) - before > PREFIX_BYTE_LIMIT {
			return 0, false
		}
		if has_space(m.line_text[row_start:]) {
			break
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
	hosts := localpath.local_hosts()
	for y in 0 ..< rows {
		m.row_start[y] = len(m.row_text)
		point := ghostty.Point{tag = .Viewport, value = {coordinate = {x = 0, y = u32(y)}}}
		ref: ghostty.Grid_Ref
		if ghostty.terminal_grid_ref(terminal, point, &ref) != .Success {
			return false
		}
		row: ghostty.Row
		if ghostty.grid_ref_row(&ref, &row) != .Success {
			return false
		}
		wrap := false
		row_keys := [?]ghostty.Row_Data{.Wrap_Continuation}
		row_values := [?]rawptr{&wrap}
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
			if linked {
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
			// A run only holds a usable target, so its continuation needs no second classification.
			if uri != "" &&
			   run_active &&
			   x == run_last + 1 &&
			   len(uri) == run_length &&
			   string(m.text[run_start:run_start + run_length]) == uri {
				run_last = x
				continue
			}
			usable := uri != "" && links.allowed(uri)
			if uri != "" && !usable {
				file_buffer: [links.TARGET_BYTES]u8 = ---
				_, usable = links.resolve_file(uri, "", hosts, file_buffer[:])
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
is_blank :: proc(c: u8) -> bool {
	return c == ' ' || c == '\t'
}

// row_edge_of measures where a row stops and the row below starts. Blanks carry a cell each, so a row
// with none trailing fills its width.
@(private, require_results)
row_edge_of :: proc(m: ^Link_Map, row, columns: int) -> links.Row_Edge {
	above := m.row_text[m.row_start[row]:m.row_start[row] + m.row_length[row]]
	above_cell := m.row_cell[m.row_start[row]:m.row_start[row] + m.row_length[row]]
	below := m.row_text[m.row_start[row + 1]:m.row_start[row + 1] + m.row_length[row + 1]]
	below_cell := m.row_cell[m.row_start[row + 1]:m.row_start[row + 1] + m.row_length[row + 1]]
	end := len(above)
	for end > 0 && is_blank(above[end - 1]) {
		end -= 1
	}
	if end == 0 {
		return {columns = columns}
	}
	used := end == len(above) ? columns : above_cell[end] % columns
	tail := end
	for tail > 0 && !is_blank(above[tail - 1]) {
		tail -= 1
	}
	first := 0
	for first < len(below) && is_blank(below[first]) {
		first += 1
	}
	if first == len(below) {
		return {columns = columns, used = used}
	}
	stop := first
	for stop < len(below) && !is_blank(below[stop]) {
		stop += 1
	}
	indent := below_cell[first] % columns
	head_end := stop < len(below) ? below_cell[stop] % columns : columns
	return {
		above = string(above),
		below = string(below),
		tail = string(above[tail:end]),
		head = string(below[first:stop]),
		tail_cells = used - above_cell[tail] % columns,
		head_cells = head_end - indent,
		used = used,
		indent = indent,
		columns = columns,
	}
}

// append_joined adds a row a program wrapped itself. Neither the blanks ending the row above nor this
// row's indentation are part of the text. A word break becomes one newline, and a broken word records
// a cut.
@(private, require_results)
append_joined :: proc(m: ^Link_Map, row: int) -> bool {
	start := m.row_start[row]
	length := m.row_length[row]
	first := 0
	for first < length && is_blank(m.row_text[start + first]) {
		first += 1
	}
	kept := len(m.line_text)
	for kept > 0 && is_blank(m.line_text[kept - 1]) {
		kept -= 1
	}
	if runtime.resize(&m.line_text, kept) != nil || runtime.resize(&m.line_cell, kept) != nil {
		return false
	}
	if m.row_join[row] == .Word {
		if _, err := append(&m.line_text, '\n'); err != nil {
			return false
		}
		if _, err := append(&m.line_cell, -1); err != nil {
			return false
		}
	} else if _, err := append(&m.line_cuts, len(m.line_text)); err != nil {
		return false
	}
	return append_range(
		&m.line_text,
		&m.line_cell,
		m.row_text[start + first:start + length],
		m.row_cell[start + first:start + length],
	)
}

@(private, require_results)
scan_lines :: proc(m: ^Link_Map, terminal: ghostty.Terminal, columns, rows: int) -> bool {
	y := 0
	for y < rows {
		clear(&m.line_text)
		clear(&m.line_cell)
		clear(&m.line_cuts)
		end := y
		for end + 1 < rows && m.row_wrap[end + 1] {
			end += 1
		}
		if y == 0 && m.row_wrap[0] {
			if _, ok := prefix_bytes(m, terminal, columns); !ok {
				y = end + 1
				continue
			}
		}
		for end + 1 < rows {
			m.row_join[end + 1] = .None
			if !m.row_wrap[end + 1] {
				m.row_join[end + 1] = links.row_join(row_edge_of(m, end, columns))
				if m.row_join[end + 1] == .None {
					break
				}
			}
			end += 1
		}
		for row := y; row <= end; row += 1 {
			if row > y && !m.row_wrap[row] {
				if !append_joined(m, row) {
					return false
				}
				continue
			}
			start := m.row_start[row]
			length := m.row_length[row]
			if !append_range(
				&m.line_text,
				&m.line_cell,
				m.row_text[start:start + length],
				m.row_cell[start:start + length],
			) {
				return false
			}
		}
		if end == rows - 1 {
			if _, ok := suffix_bytes(m, terminal, columns, rows); !ok {
				y = end + 1
				continue
			}
		}
		clear(&m.urls)
		line := string(m.line_text[:])
		if !links.find(line, &m.urls) {
			return false
		}
		// Only lines with a dot or a separator can hold a file target, and this lock is held.
		if strings.contains_any(line, "./\\") && !links.find_files(line, m.relative_files, &m.urls) {
			return false
		}
		line_start, line_length, cuts_start := -1, 0, 0
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
			for &c in m.text[uri_start:] {
				if c == '\n' {c = ' '}
			}
			span := Link_Span {
				range = {
					first_row    = first / columns,
					first_column = first % columns,
					last_row     = last / columns,
					last_column  = last % columns,
				},
				uri_start  = uri_start,
				uri_length = url.end - url.start,
			}
			if !links.allowed(string(m.text[uri_start:])) {
				if line_start < 0 {
					line_start, line_length = len(m.text), len(m.line_text)
					cuts_start = len(m.cuts)
					if _, err := append(&m.text, ..m.line_text[:]); err != nil {
						return false
					}
					if _, err := append(&m.cuts, ..m.line_cuts[:]); err != nil {
						return false
					}
				}
				span.line_start, span.line_length = line_start, line_length
				span.target_start, span.target_end = url.start, url.end
				span.cuts_start, span.cuts_length = cuts_start, len(m.line_cuts)
			}
			if _, err := append(&m.spans, span); err != nil {
				return false
			}
		}
		y = end + 1
	}
	return true
}

// A selection names a target only when it is linear, in view and a few rows long. Those checks come
// first because formatting a select-all would hold the session lock for the whole scrollback. It is
// read here rather than on every pointer move: changing the selection already triggers this scan.
@(private, require_results)
scan_selection :: proc(m: ^Link_Map, terminal: ghostty.Terminal) -> bool {
	m.selection_active = false
	selection: ghostty.Selection
	if ghostty.terminal_get(terminal, .Selection, &selection) != .Success || selection.rectangle {
		return true
	}
	ordered: ghostty.Selection
	if ghostty.terminal_selection_ordered(terminal, &selection, .Forward, &ordered) != .Success {
		return true
	}
	first, last := ghostty.Point_Coordinate{}, ghostty.Point_Coordinate{}
	if ghostty.terminal_point_from_grid_ref(terminal, &ordered.start, .Viewport, &first) != .Success ||
	   ghostty.terminal_point_from_grid_ref(terminal, &ordered.end, .Viewport, &last) != .Success ||
	   int(last.y - first.y) >= links.SELECTION_ROWS {
		return true
	}
	text, length, result := format_selection(terminal, &selection, true)
	if result != .Success {
		return true
	}
	defer ghostty.free(nil, text, length)
	if !links.selection_line(string(text[:length]), &m.selection_line) {
		return true
	}
	line := string(m.selection_line[:])
	target, named := links.selection_target(line, m.relative_files)
	if !named {
		return true
	}
	if runtime.resize(&m.selection_uri, target.end - target.start) != nil {
		return false
	}
	copy(m.selection_uri[:], line[target.start:target.end])
	for &c in m.selection_uri {
		if c == '\n' {c = ' '}
	}
	m.selection_target = target
	m.selection_range = {
		first_row    = int(first.y),
		first_column = int(first.x),
		last_row     = int(last.y),
		last_column  = int(last.x),
	}
	m.selection_active = true
	return true
}

@(private, require_results)
link_map_scan_locked :: proc(
	m: ^Link_Map,
	terminal: ghostty.Terminal,
	columns, rows: int,
) -> bool {
	m.valid = false
	pwd: ghostty.String
	m.relative_files = false
	if ghostty.terminal_get(terminal, .Pwd, &pwd) == .Success && pwd.len > 0 {
		buffer: [links.TARGET_BYTES]u8 = ---
		_, m.relative_files = links.resolve_file(
			string(pwd.ptr[:pwd.len]), "", localpath.local_hosts(), buffer[:])
	}
	clear(&m.spans)
	clear(&m.text)
	clear(&m.row_text)
	clear(&m.row_cell)
	clear(&m.urls)
	clear(&m.cuts)
	m.selection_active = false
	m.columns, m.rows = max(columns, 0), max(rows, 0)
	if columns <= 0 || rows <= 0 {
		m.valid = true
		return true
	}
	if runtime.resize(&m.row_start, rows) != nil ||
	   runtime.resize(&m.row_length, rows) != nil ||
	   runtime.resize(&m.row_wrap, rows) != nil ||
	   runtime.resize(&m.row_join, rows) != nil {
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
	if !scan_selection(m, terminal) {
		return false
	}
	m.valid = true
	return true
}

when ODIN_TEST {
	@(require_results)
	link_test_select :: proc(terminal: ghostty.Terminal, first_x, first_y, last_x, last_y: int) -> bool {
		selection: ghostty.Selection
		start := ghostty.Point{tag = .Viewport, value = {coordinate = {x = u16(first_x), y = u32(first_y)}}}
		end := ghostty.Point{tag = .Viewport, value = {coordinate = {x = u16(last_x), y = u32(last_y)}}}
		if ghostty.terminal_grid_ref(terminal, start, &selection.start) != .Success ||
		   ghostty.terminal_grid_ref(terminal, end, &selection.end) != .Success {
			return false
		}
		return ghostty.terminal_set(terminal, .Selection, &selection) == .Success
	}

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
