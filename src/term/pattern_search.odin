package term

import "aio:ghostty"
import "core:log"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:text/regex"
import "core:time"
import "core:unicode/utf8"

// libghostty matches literal text with ASCII case folding. Any other mode uses this scanner.
Search_Options :: struct {
	case_sensitive, regex: bool,
}

// Rows read per terminal lock hold, so output ingestion is never blocked for long.
@(private)
PATTERN_CHUNK_ROWS :: 32
// Rows at the top of the screen whose text identifies its history. When pruning or a clear replaces them,
// the scanner starts again from the top instead of reusing stale coordinates.
@(private)
PATTERN_ANCHOR_ROWS :: 8

// A match in screen coordinates: rows count from the top of the scrollback, columns are inclusive.
@(private)
Pattern_Match :: struct {
	first_row, last_row:       i32,
	first_column, last_column: u16,
}

@(private)
Line_Cell :: struct {
	row:         i32,
	first, last: u16,
	blank:       bool,
}

@(private)
Chunk_Row :: struct {
	end:       int,
	continues: bool,
}

@(private)
Pattern_Search :: struct {
	active, invalid:  bool,
	options:          Search_Options,
	needle:           string,
	iterator:         regex.Match_Iterator,
	compiled:         bool,
	// Results oldest first. A refresh builds `found` and swaps it in, so drawn results never go partial.
	matches, found:   [dynamic]Pattern_Match,
	// Index into matches, or -1.
	selected:         int,
	selected_match:   Pattern_Match,
	// A pass has finished since the needle changed.
	complete:         bool,
	scanning:         bool,
	// Bumped when a refresh changes the results, so the window redraws their highlights.
	revision:         int,
	fed:              u64,
	next_row, end_row: int,
	columns, rows:    int,
	anchor:           u64,
	chunk_text:       [dynamic]u8,
	chunk_cells:      [dynamic]Line_Cell,
	chunk_rows:       [dynamic]Chunk_Row,
	line_text:        [dynamic]u8,
	line_cells:       [dynamic]Line_Cell,
}

@(private)
pattern_init :: proc(p: ^Pattern_Search, s: ^Session) {
	p.selected = -1
	p.matches.allocator = s.allocator
	p.found.allocator = s.allocator
	p.chunk_text.allocator = s.allocator
	p.chunk_cells.allocator = s.allocator
	p.chunk_rows.allocator = s.allocator
	p.line_text.allocator = s.allocator
	p.line_cells.allocator = s.allocator
}

@(private)
pattern_destroy :: proc(p: ^Pattern_Search, s: ^Session) {
	pattern_clear(p, s)
	delete(p.matches)
	delete(p.found)
	delete(p.chunk_text)
	delete(p.chunk_cells)
	delete(p.chunk_rows)
	delete(p.line_text)
	delete(p.line_cells)
}

@(private)
pattern_clear :: proc(p: ^Pattern_Search, s: ^Session) {
	if p.compiled {
		regex.destroy_iterator(p.iterator, s.allocator)
	}
	delete(p.needle, s.allocator)
	p.needle, p.iterator, p.compiled = "", {}, false
	p.active, p.invalid, p.complete, p.scanning = false, false, false, false
	p.selected = -1
	clear(&p.matches)
	clear(&p.found)
}

// Starts a scan for `needle`. An invalid expression keeps the search active so the find bar can say so.
@(private)
pattern_set :: proc(s: ^Session, needle: string, options: Search_Options) {
	p := &s.pattern
	pattern_clear(p, s)
	if len(needle) == 0 {
		return
	}
	copied, err := strings.clone(needle, s.allocator)
	if err != nil {
		log.error("term: copying the search text failed")
		return
	}
	p.needle, p.options, p.active = copied, options, true
	if options.regex {
		flags: regex.Flags = {.Unicode}
		if !options.case_sensitive {
			flags += {.Case_Insensitive}
		}
		iterator, compile_error := regex.create_iterator("", needle, flags, s.allocator)
		if compile_error != nil {
			p.invalid = true
			return
		}
		p.iterator, p.compiled = iterator, true
	}
	p.fed = generation(s) - 1
}

@(private)
pattern_pending :: proc(s: ^Session) -> bool {
	p := &s.pattern
	return p.active && !p.invalid && (p.scanning || generation(s) != p.fed)
}

@(private)
pattern_update :: proc(s: ^Session, budget: time.Duration) {
	p := &s.pattern
	if !pattern_pending(s) {
		return
	}
	start := time.tick_now()
	if !p.scanning && !pattern_begin(s) {
		return
	}
	for time.tick_since(start) < budget {
		done := pattern_read(s)
		pattern_process(p, done)
		if done {
			pattern_finish(p)
			return
		}
	}
}

// Results visible to the find bar: the first pass publishes as it goes, later passes when they finish.
@(private)
pattern_results :: proc(p: ^Pattern_Search) -> []Pattern_Match {
	return p.matches[:]
}

@(private)
pattern_target :: proc(p: ^Pattern_Search) -> ^[dynamic]Pattern_Match {
	return p.complete ? &p.found : &p.matches
}

// Chooses where the pass starts. History above the active area does not change unless it is pruned, cleared
// or reflowed, so a refresh normally rescans only the lines that touch the active area.
@(private, require_results)
pattern_begin :: proc(s: ^Session) -> bool {
	p := &s.pattern
	columns, rows := int(s.geometry.columns), int(s.geometry.rows)
	sync.mutex_lock(&s.mutex)
	defer sync.mutex_unlock(&s.mutex)
	bar: ghostty.Terminal_Scrollbar
	if ghostty.terminal_get(s.terminal, .Scrollbar, &bar) != .Success {
		log.error("term: reading the screen size for search failed")
		return false
	}
	total := int(bar.total)
	anchor := screen_anchor(s.terminal, columns, min(total, PATTERN_ANCHOR_ROWS))
	start := 0
	if p.complete && columns == p.columns && rows == p.rows && anchor == p.anchor && total >= p.end_row {
		start = max(0, p.end_row - p.rows)
		for start > 0 && row_continues(s.terminal, .Screen, u32(start)) {
			start -= 1
		}
	}
	p.fed = generation(s)
	p.columns, p.rows, p.anchor = columns, rows, anchor
	p.next_row, p.end_row = start, total
	p.scanning = true
	clear(&p.line_text)
	clear(&p.line_cells)
	clear(&p.found)
	if !p.complete {
		clear(&p.matches)
		return true
	}
	kept := 0
	for kept < len(p.matches) && int(p.matches[kept].first_row) < start {
		kept += 1
	}
	if _, err := append(&p.found, ..p.matches[:kept]); err != nil {
		p.scanning = false
		return false
	}
	return true
}

@(private)
screen_anchor :: proc(terminal: ghostty.Terminal, columns, rows: int) -> u64 {
	// FNV-1a over the code points; empty cells count, so blank rows still shift the anchor.
	value := u64(0xcbf29ce484222325)
	mix :: proc(value: u64, word: u64) -> u64 { return (value ~ word) * 0x100000001b3 }
	value = mix(mix(value, u64(columns)), u64(rows))
	for y in 0 ..< rows {
		ref, ok := screen_row_ref(terminal, y)
		if !ok {
			continue
		}
		for x in 0 ..< columns {
			ref.x = u16(x)
			cell: ghostty.Cell
			codepoint: u32
			if ghostty.grid_ref_cell(&ref, &cell) != .Success ||
			   ghostty.cell_get(cell, .Codepoint, &codepoint) != .Success {
				continue
			}
			value = mix(value, u64(codepoint))
		}
	}
	return value
}

@(private, require_results)
screen_row_ref :: proc(terminal: ghostty.Terminal, y: int) -> (ghostty.Grid_Ref, bool) {
	point := ghostty.Point{tag = .Screen, value = {coordinate = {x = 0, y = u32(y)}}}
	ref := ghostty.sized(ghostty.Grid_Ref)
	ok := ghostty.terminal_grid_ref(terminal, point, &ref) == .Success
	return ref, ok
}

// Copies the next rows' text under the lock, one entry per byte in chunk_cells. Returns true at the end.
@(private, require_results)
pattern_read :: proc(s: ^Session) -> bool {
	p := &s.pattern
	clear(&p.chunk_text)
	clear(&p.chunk_cells)
	clear(&p.chunk_rows)
	last := min(p.next_row + PATTERN_CHUNK_ROWS, p.end_row)
	sync.mutex_lock(&s.mutex)
	defer sync.mutex_unlock(&s.mutex)
	for p.next_row < last {
		y := p.next_row
		ref, ok := screen_row_ref(s.terminal, y)
		if !ok {
			// The screen shrank during the pass; the next pass reads it again.
			p.end_row = y
			break
		}
		continues := false
		row: ghostty.Row
		if ghostty.grid_ref_row(&ref, &row) == .Success {
			_ = ghostty.row_get(row, .Wrap_Continuation, &continues)
		}
		for x in 0 ..< p.columns {
			ref.x = u16(x)
			if !read_cell(p, &ref, y, x) {
				return true
			}
		}
		if _, err := append(&p.chunk_rows, Chunk_Row{len(p.chunk_text), continues}); err != nil {
			return true
		}
		p.next_row += 1
	}
	return p.next_row >= p.end_row
}

@(private, require_results)
read_cell :: proc(p: ^Pattern_Search, ref: ^ghostty.Grid_Ref, y, x: int) -> bool {
	codepoint: u32
	wide: ghostty.Cell_Wide
	has_text: bool
	cell: ghostty.Cell
	ok := ghostty.grid_ref_cell(ref, &cell) == .Success
	if ok {
		keys := [?]ghostty.Cell_Data{.Codepoint, .Wide, .Has_Text}
		values := [?]rawptr{&codepoint, &wide, &has_text}
		ok = ghostty.cell_get_multi(cell, len(keys), &keys[0], &values[0], nil) == .Success
	}
	if ok && (wide == .Spacer_Tail || wide == .Spacer_Head) {
		return true
	}
	at := Line_Cell{i32(y), u16(x), u16(x), false}
	if !ok || !has_text || codepoint == 0 {
		at.blank = true
		_, err := append(&p.chunk_text, ' ')
		_, cell_err := append(&p.chunk_cells, at)
		return err == nil && cell_err == nil
	}
	if wide == .Wide {
		at.last += 1
	}
	bytes, count := utf8.encode_rune(rune(codepoint))
	for i in 0 ..< count {
		_, err := append(&p.chunk_text, bytes[i])
		_, cell_err := append(&p.chunk_cells, at)
		if err != nil || cell_err != nil {
			return false
		}
	}
	return true
}

// Joins soft-wrapped rows into logical lines and matches each finished line.
@(private)
pattern_process :: proc(p: ^Pattern_Search, done: bool) {
	start := 0
	for row in p.chunk_rows {
		if !row.continues {
			pattern_match_line(p)
		}
		_, err := append(&p.line_text, ..p.chunk_text[start:row.end])
		_, cell_err := append(&p.line_cells, ..p.chunk_cells[start:row.end])
		if err != nil || cell_err != nil {
			clear(&p.line_text)
			clear(&p.line_cells)
		}
		start = row.end
	}
	if done {
		pattern_match_line(p)
	}
}

@(private)
pattern_match_line :: proc(p: ^Pattern_Search) {
	defer {
		clear(&p.line_text)
		clear(&p.line_cells)
	}
	end := len(p.line_text)
	for end > 0 && p.line_cells[end - 1].blank {
		end -= 1
	}
	if end == 0 {
		return
	}
	line := string(p.line_text[:end])
	if !p.options.regex {
		offset := 0
		for {
			found := strings.index(line[offset:], p.needle)
			if found < 0 {
				return
			}
			first := offset + found
			offset = first + len(p.needle)
			if !pattern_add(p, first, offset) {
				return
			}
		}
	}
	it := &p.iterator
	it.vm.memory = line
	regex.reset(it)
	for {
		capture, _, ok := regex.match_iterator(it)
		if !ok {
			return
		}
		if len(capture.pos) > 0 && capture.pos[0][1] > capture.pos[0][0] {
			if !pattern_add(p, capture.pos[0][0], capture.pos[0][1]) {
				return
			}
		}
		if !it.done {
			continue
		}
		// The iterator stops after an empty match; resume one character later so `a*` still finds "aa".
		at := it.vm.string_pointer
		if at >= len(line) {
			return
		}
		previous, size := utf8.decode_rune_in_string(line[at:])
		it.done = false
		it.vm.string_pointer = at + size
		it.vm.last_rune = previous
	}
}

@(private, require_results)
pattern_add :: proc(p: ^Pattern_Search, first, end: int) -> bool {
	a, b := p.line_cells[first], p.line_cells[end - 1]
	_, err := append(pattern_target(p), Pattern_Match{a.row, b.row, a.first, b.last})
	return err == nil
}

@(private)
pattern_finish :: proc(p: ^Pattern_Search) {
	p.scanning = false
	if !p.complete {
		p.complete = true
		p.revision += 1
		return
	}
	if !slice.equal(p.found[:], p.matches[:]) {
		p.revision += 1
	}
	p.matches, p.found = p.found, p.matches
	clear(&p.found)
	if p.selected < 0 {
		return
	}
	// Keep the selection on the same match, or the next one when it is gone.
	key := p.selected_match
	index, exact := slice.binary_search_by(p.matches[:], key, proc(m, key: Pattern_Match) -> slice.Ordering {
		return slice.cmp(match_order(m), match_order(key))
	})
	if !exact && index >= len(p.matches) {
		index = len(p.matches) - 1
	}
	p.selected = index
	if index >= 0 {
		p.selected_match = p.matches[index]
	}
}

@(private)
match_order :: proc(m: Pattern_Match) -> i64 {
	return i64(m.first_row) << 16 | i64(m.first_column)
}

@(private)
pattern_select :: proc(s: ^Session, older: bool) -> bool {
	p := &s.pattern
	matches := pattern_results(p)
	total := len(matches)
	if !p.active || total == 0 {
		return false
	}
	switch {
	case p.selected < 0 || p.selected >= total:
		p.selected = older ? total - 1 : 0
	case older:
		p.selected = (p.selected - 1 + total) % total
	case:
		p.selected = (p.selected + 1) % total
	}
	match := matches[p.selected]
	p.selected_match = match
	sync.mutex_lock(&s.mutex)
	if top, ok := screen_top(s.terminal); ok {
		rows := int(s.geometry.rows)
		first, last := int(match.first_row), int(match.last_row)
		if first < int(top) || last >= int(top) + rows {
			delta := first - rows / 2 - int(top)
			ghostty.terminal_scroll_viewport(s.terminal, {tag = .Delta, value = {delta = delta}})
		}
	}
	sync.mutex_unlock(&s.mutex)
	mark_changed(s)
	return true
}

// Appends the viewport's matches, the selected match last. The caller holds the mutex.
@(private)
pattern_highlights :: proc(s: ^Session, out: ^[dynamic]Highlight) {
	p := &s.pattern
	matches := pattern_results(p)
	top32, ok := screen_top(s.terminal)
	if !ok || len(matches) == 0 {
		return
	}
	top, rows, columns := int(top32), int(s.geometry.rows), int(s.geometry.columns)
	index, _ := slice.binary_search_by(matches, top, proc(m: Pattern_Match, top: int) -> slice.Ordering {
		return int(m.last_row) < top ? .Less : .Greater
	})
	for match in matches[index:] {
		if int(match.first_row) >= top + rows {
			break
		}
		if !append_pattern_highlight(match, false, top, rows, columns, out) {
			return
		}
	}
	if p.selected >= 0 && p.selected < len(matches) {
		append_pattern_highlight(matches[p.selected], true, top, rows, columns, out)
	}
}

@(private)
append_pattern_highlight :: proc(
	m: Pattern_Match,
	selected: bool,
	top, rows, columns: int,
	out: ^[dynamic]Highlight,
) -> bool {
	first_row, last_row := int(m.first_row), int(m.last_row)
	for row in max(first_row, top) ..= min(last_row, top + rows - 1) {
		first := row == first_row ? int(m.first_column) : 0
		last := row == last_row ? int(m.last_column) : columns - 1
		if _, err := append(out, Highlight{row - top, first, min(last, columns - 1), selected}); err != nil {
			return false
		}
	}
	return true
}
