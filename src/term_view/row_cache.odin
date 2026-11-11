package term_view

import "aio:font"
import "aio:ghostty"
import "aio:render"
import "aio:term"
import "core:hash/xxhash"
import "core:math"
import "core:mem"

// Rows drawn in an earlier build, by row id. Output that scrolls moves rows without changing them,
// and typing changes only the cursor's row, yet every build used to read, shape and place every
// cell again. A row whose paints match the ones it was drawn with takes its cached draw commands,
// moved to where the row is now. The cursor's rows, the hovered link's rows, rows with grapheme
// clusters and panes with images are always drawn afresh, since their drawing depends on more than
// paints.
//
// Reading those paints means reading every cell, so two cheaper checks come first:
//
// - **Unchanged rows:** libghostty marks a row dirty whenever an update rebuilds it. The view clears
//   the flag once the row's drawing is cached. A row that is still clean replays without reading
//   anything, unless it has a selection or search marks, or had them when it was cached.
// - **Plain rows:** a row without styles, selection or search marks is checked on its raw cells,
//   which one call returns. Its paints follow from those cells and the drawing inputs in the key.
//   A styled row cannot be checked this way: a style id that went out of use can come back meaning
//   another style.
//
// A resize rewraps the history into new rows with new ids, though most lines come out the same. So
// a row whose id is not cached is also looked up by its content, its raw cells or its paints with
// trailing blanks trimmed, and takes over the kept row that drew it. Neither the column count nor
// where the pane starts is part of the key: a row's cells carry its width, blank cells draw nothing,
// and kept draw commands move by whole pixels in both directions.
@(private)
Row_Cache :: struct {
	rows:      map[ghostty.Render_State_Row_Id]Cached_Row,
	// A kept row's id by the hash of its trimmed raw cells, and by that of its trimmed paints.
	by_raw:    map[u64]ghostty.Render_State_Row_Id,
	by_paints: map[u64]ghostty.Render_State_Row_Id,
	// Buffers of evicted rows, reused for new ones.
	spare:     [dynamic]Cached_Row,
	key:       Row_Cache_Key,
	build:     u64,
	evicted:   [dynamic]ghostty.Render_State_Row_Id,
	// Rows replayed so far, for diagnostics.
	replays:   u64,
}

@(private)
Cached_Row :: struct {
	paints:      [dynamic]Cell_Paint,
	// The raw cells, kept when the row had no styles, selection or marks; empty otherwise.
	raw:         [dynamic]ghostty.Cell,
	rects:       [dynamic]render.Rect_Instance,
	glyphs:      [dynamic]render.Glyph_Instance,
	// Where the row's commands were drawn: the pane's left edge and the row's top.
	left, top:   f32,
	raw_hash:    u64,
	paints_hash: u64,
	build:       u64,
	// The row had no selection or search marks when last drawn.
	unmarked:    bool,
}

// What a row's drawing depends on beyond its paints; any change empties the cache.
@(private)
Row_Cache_Key :: struct {
	family:           font.Family,
	metrics:          Metrics,
	// Kept commands move by whole pixels, so only where within a pixel the pane starts matters.
	origin_fraction:  [2]f32,
	colors:           ghostty.Render_State_Colors,
	minimum_contrast: f32,
	atlas:            u64,
}

// The rows this view drew from its row cache rather than afresh.
row_cache_replays :: proc(v: ^View) -> u64 {
	return v.row_cache.replays
}

@(private)
row_cache_destroy :: proc(c: ^Row_Cache) {
	for _, &row in c.rows {cached_row_destroy(&row)}
	for &row in c.spare {cached_row_destroy(&row)}
	delete(c.rows)
	delete(c.by_raw)
	delete(c.by_paints)
	delete(c.spare)
	delete(c.evicted)
}

@(private)
cached_row_destroy :: proc(row: ^Cached_Row) {
	delete(row.paints)
	delete(row.raw)
	delete(row.rects)
	delete(row.glyphs)
}

// Starts a build: rows cached under other drawing inputs are dropped.
@(private)
row_cache_begin :: proc(v: ^View, b: ^Builder) {
	c := &v.row_cache
	c.build += 1
	key := Row_Cache_Key {
		family           = b.style.family,
		metrics          = b.metrics,
		origin_fraction  = b.origin - {math.floor(b.origin.x), math.floor(b.origin.y)},
		colors           = b.colors,
		minimum_contrast = b.style.minimum_contrast,
		atlas            = render.atlas_generation(b.cache.device),
	}
	if key == c.key {return}
	c.key = key
	for _, row in c.rows {row_cache_release(c, row)}
	clear(&c.rows)
	clear(&c.by_raw)
	clear(&c.by_paints)
}

// Ends a build: rows it did not show are dropped.
@(private)
row_cache_end :: proc(v: ^View) {
	c := &v.row_cache
	clear(&c.evicted)
	for id, row in c.rows {
		if row.build == c.build {continue}
		// Rows left unlisted stay cached; replay compares, so a stale row is never drawn.
		if _, err := append(&c.evicted, id); err != nil {break}
	}
	for id in c.evicted {
		row := c.rows[id]
		row_cache_unindex(c, id, row)
		row_cache_release(c, row)
		delete_key(&c.rows, id)
	}
}

@(private)
row_cache_release :: proc(c: ^Row_Cache, row: Cached_Row) {
	row := row
	if _, err := append(&c.spare, row); err != nil {cached_row_destroy(&row)}
}

// Drops the content lookups that lead to the row kept under `id`.
@(private)
row_cache_unindex :: proc(c: ^Row_Cache, id: ghostty.Render_State_Row_Id, row: Cached_Row) {
	if len(row.raw) > 0 {
		if mapped, ok := c.by_raw[row.raw_hash]; ok && mapped == id {delete_key(&c.by_raw, row.raw_hash)}
	}
	if len(row.paints) > 0 {
		if mapped, ok := c.by_paints[row.paints_hash]; ok && mapped == id {
			delete_key(&c.by_paints, row.paints_hash)
		}
	}
}

// The row's id when its drawing can come from the cache.
@(private)
row_cache_id :: proc(v: ^View, b: ^Builder, y: int) -> (id: ghostty.Render_State_Row_Id, ok: bool) {
	if !b.row_cache {return}
	c := b.cursor
	if c.viewport_has_value && int(c.viewport_y) == y {return}
	if b.cursor_moving && y >= b.cursor_row && y <= b.cursor_row + 1 {return}
	if hover, has := b.style.hover.?; has {
		first, last, _ := term.link_range_columns(hover, y, b.columns)
		if first <= last {return}
	}
	if ghostty.render_state_row_get(v.rows, .Id, &id) != .Success {return}
	return id, true
}

// Whether the row has a selection or search marks.
@(private)
row_marked :: proc(v: ^View, y: int) -> bool {
	selection := ghostty.sized(ghostty.Render_State_Row_Selection)
	if ghostty.render_state_row_get(v.rows, .Selection, &selection) == .Success {return true}
	for h in v.highlights {if h.row == y {return true}}
	return false
}

// Draws the row from the cache when no update has rebuilt it since it was cached, and it is
// unmarked now and was then.
@(private)
row_cache_replay_clean :: proc(v: ^View, b: ^Builder, id: ghostty.Render_State_Row_Id, top: f32) -> bool {
	dirty := true
	if ghostty.render_state_row_get(v.rows, .Dirty, &dirty) != .Success || dirty {return false}
	row, found := &v.row_cache.rows[id]
	if !found || !row.unmarked {return false}
	row_cache_draw(v, b, row, top)
	return true
}

// The row's raw cells, when it has no styles, grapheme clusters, selection or search marks.
@(private)
row_cache_plain_raw :: proc(v: ^View, marked: bool) -> (cells: []ghostty.Cell, ok: bool) {
	if marked {return}
	row: ghostty.Row
	if ghostty.render_state_row_get(v.rows, .Raw, &row) != .Success {return}
	styled, grapheme := true, true
	if ghostty.row_get(row, .Styled, &styled) != .Success || styled {return}
	if ghostty.row_get(row, .Grapheme, &grapheme) != .Success || grapheme {return}
	view: ghostty.Cells_View
	if ghostty.render_state_row_get(v.rows, .Cells_Raw, &view) != .Success || view.ptr == nil {return}
	return ([^]ghostty.Cell)(view.ptr)[:view.len], true
}

// Draws the row from the cache when it was drawn from the same raw cells, under its own id or, by
// content, another.
@(private)
row_cache_replay_raw :: proc(
	v: ^View,
	b: ^Builder,
	id: ghostty.Render_State_Row_Id,
	raw: []ghostty.Cell,
	top: f32,
	marked: bool,
) -> bool {
	c := &v.row_cache
	trimmed := raw_trimmed(raw)
	if row, found := &c.rows[id]; found && len(row.raw) > 0 && raw_equal(raw_trimmed(row.raw[:]), trimmed) {
		row_cache_draw(v, b, row, top)
		row_cache_drawn(v, row, marked)
		return true
	}
	from, indexed := c.by_raw[raw_hash(trimmed)]
	if !indexed || from == id {return false}
	row, found := &c.rows[from]
	if !found || len(row.raw) == 0 || !raw_equal(raw_trimmed(row.raw[:]), trimmed) {return false}
	row_cache_adopt(v, b, from, id, top, marked)
	return true
}

// Draws the row from the cache when it was drawn with the same paints, under its own id or, by
// content, another.
@(private)
row_cache_replay :: proc(
	v: ^View,
	b: ^Builder,
	id: ghostty.Render_State_Row_Id,
	top: f32,
	marked: bool,
) -> bool {
	c := &v.row_cache
	trimmed := paints_trimmed(v.paints[:])
	// A failed store leaves its row without paints, and a blank row's trimmed paints are empty too.
	row, found := &c.rows[id]
	if found && len(row.paints) > 0 && paints_equal(paints_trimmed(row.paints[:]), trimmed) {
		row_cache_draw(v, b, row, top)
		row_cache_drawn(v, row, marked)
		return true
	}
	from, indexed := c.by_paints[paints_hash(trimmed)]
	if !indexed || from == id {return false}
	row, found = &c.rows[from]
	if !found || len(row.paints) == 0 || !paints_equal(paints_trimmed(row.paints[:]), trimmed) {return false}
	row_cache_adopt(v, b, from, id, top, marked)
	return true
}

// Draws the row from the row kept under `from`, which drew the same content, and keeps it under the
// row's own id from then on, unless an earlier row of this build already took it.
@(private)
row_cache_adopt :: proc(
	v: ^View,
	b: ^Builder,
	from, id: ghostty.Render_State_Row_Id,
	top: f32,
	marked: bool,
) {
	c := &v.row_cache
	kept := &c.rows[from]
	taken := kept.build == c.build
	row_cache_draw(v, b, kept, top)
	if taken {return}
	moved := kept^
	delete_key(&c.rows, from)
	if stale, found := c.rows[id]; found {
		row_cache_unindex(c, id, stale)
		row_cache_release(c, stale)
	}
	_, value, _, err := map_entry(&c.rows, id)
	if err != nil {
		row_cache_unindex(c, from, moved)
		row_cache_release(c, moved)
		return
	}
	value^ = moved
	if len(moved.raw) > 0 {c.by_raw[moved.raw_hash] = id}
	if len(moved.paints) > 0 {c.by_paints[moved.paints_hash] = id}
	row_cache_drawn(v, value, marked)
}

@(private)
row_cache_draw :: proc(v: ^View, b: ^Builder, row: ^Cached_Row, top: f32) {
	row.build = v.row_cache.build
	v.row_cache.replays += 1
	// The key holds where within a pixel the pane starts, and cell heights are whole pixels, so rows
	// move by whole pixels and glyphs stay on the pixel grid.
	offset := [2]f32{math.round(b.origin.x - row.left), math.round(top - row.top)}
	_ = render.push_instances(b.list, row.rects[:], row.glyphs[:], offset)
}

// The cached row now draws the row as it is: clearing the row's dirty flag lets later builds
// replay it unread until an update rebuilds it.
@(private)
row_cache_drawn :: proc(v: ^View, row: ^Cached_Row, marked: bool) {
	row.unmarked = !marked
	clean := false
	_ = ghostty.render_state_row_set(v.rows, .Dirty, &clean)
}

// Keeps the draw commands the row just added, from `rects` and `glyphs` on, and its raw cells when
// row_cache_plain_raw gave them.
@(private)
row_cache_store :: proc(
	v: ^View,
	b: ^Builder,
	id: ghostty.Render_State_Row_Id,
	top: f32,
	rects, glyphs: int,
	raw: []ghostty.Cell,
	marked: bool,
) {
	c := &v.row_cache
	row, found := &c.rows[id]
	if found {
		row_cache_unindex(c, id, row^)
	} else {
		_, value, _, err := map_entry(&c.rows, id)
		if err != nil {return}
		if len(c.spare) > 0 {value^ = pop(&c.spare)}
		row = value
	}
	clear(&row.paints)
	clear(&row.raw)
	clear(&row.rects)
	clear(&row.glyphs)
	row.left, row.top, row.build = b.origin.x, top, c.build
	_, paints_err := append(&row.paints, ..v.paints[:])
	_, raw_err := append(&row.raw, ..raw)
	_, rects_err := append(&row.rects, ..b.list.rects[rects:])
	_, glyphs_err := append(&row.glyphs, ..b.list.glyphs[glyphs:])
	if paints_err != nil || raw_err != nil || rects_err != nil || glyphs_err != nil {
		// A partial copy must never be replayed: empty paints and cells match no row, and the row
		// stays dirty.
		clear(&row.paints)
		clear(&row.raw)
		row.unmarked = false
		return
	}
	// Lookups that cannot be recorded only miss later.
	if len(raw) > 0 {
		row.raw_hash = raw_hash(raw_trimmed(raw))
		c.by_raw[row.raw_hash] = id
	}
	row.paints_hash = paints_hash(paints_trimmed(v.paints[:]))
	c.by_paints[row.paints_hash] = id
	row_cache_drawn(v, row, marked)
}

// The cells up to the last that is not blank; a blank cell is all zero and draws nothing.
@(private)
raw_trimmed :: proc(raw: []ghostty.Cell) -> []ghostty.Cell {
	n := len(raw)
	for n > 0 && raw[n - 1] == 0 {n -= 1}
	return raw[:n]
}

@(private)
raw_equal :: proc(a, b: []ghostty.Cell) -> bool {
	return len(a) == len(b) && mem.compare_ptrs(raw_data(a), raw_data(b), len(a) * size_of(ghostty.Cell)) == 0
}

@(private)
raw_hash :: proc(raw: []ghostty.Cell) -> u64 {
	return xxhash.XXH3_64_default(mem.slice_to_bytes(raw))
}

// The paints up to the last that draws something: a cell with no text, background or style draws
// nothing, whatever its foreground.
@(private)
paints_trimmed :: proc(paints: []Cell_Paint) -> []Cell_Paint {
	n := len(paints)
	for n > 0 {
		p := paints[n - 1]
		if p.codepoint != 0 || !p.plain || p.has_background || p.style != {} || p.width != .Narrow {break}
		n -= 1
	}
	return paints[:n]
}

@(private)
paints_equal :: proc(a, b: []Cell_Paint) -> bool {
	return len(a) == len(b) && mem.compare_ptrs(raw_data(a), raw_data(b), len(a) * size_of(Cell_Paint)) == 0
}

@(private)
paints_hash :: proc(paints: []Cell_Paint) -> u64 {
	return xxhash.XXH3_64_default(mem.slice_to_bytes(paints))
}
