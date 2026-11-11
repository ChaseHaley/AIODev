package term_view

import "aio:font"
import "aio:ghostty"
import "aio:render"
import "aio:term"
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
@(private)
Row_Cache :: struct {
	rows:    map[ghostty.Render_State_Row_Id]Cached_Row,
	// Buffers of evicted rows, reused for new ones.
	spare:   [dynamic]Cached_Row,
	key:     Row_Cache_Key,
	build:   u64,
	evicted: [dynamic]ghostty.Render_State_Row_Id,
	// Rows replayed so far, for diagnostics.
	replays: u64,
}

@(private)
Cached_Row :: struct {
	paints: [dynamic]Cell_Paint,
	// The raw cells, kept when the row had no styles, selection or marks; empty otherwise.
	raw:      [dynamic]ghostty.Cell,
	rects:    [dynamic]render.Rect_Instance,
	glyphs:   [dynamic]render.Glyph_Instance,
	top:      f32,
	build:    u64,
	// The row had no selection or search marks when last drawn.
	unmarked: bool,
}

// What a row's drawing depends on beyond its paints; any change empties the cache.
@(private)
Row_Cache_Key :: struct {
	family:           font.Family,
	metrics:          Metrics,
	origin:           [2]f32,
	columns:          int,
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
		origin           = b.origin,
		columns          = b.columns,
		colors           = b.colors,
		minimum_contrast = b.style.minimum_contrast,
		atlas            = render.atlas_generation(b.cache.device),
	}
	if key == c.key {return}
	c.key = key
	for _, row in c.rows {row_cache_release(c, row)}
	clear(&c.rows)
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
		row_cache_release(c, c.rows[id])
		delete_key(&c.rows, id)
	}
}

@(private)
row_cache_release :: proc(c: ^Row_Cache, row: Cached_Row) {
	row := row
	if _, err := append(&c.spare, row); err != nil {cached_row_destroy(&row)}
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

// Draws the row from the cache when its raw cells are the ones it was drawn from.
@(private)
row_cache_replay_raw :: proc(
	v: ^View,
	b: ^Builder,
	id: ghostty.Render_State_Row_Id,
	raw: []ghostty.Cell,
	top: f32,
	marked: bool,
) -> bool {
	row, found := &v.row_cache.rows[id]
	if !found || len(row.raw) == 0 || len(row.raw) != len(raw) {return false}
	if mem.compare_ptrs(raw_data(row.raw), raw_data(raw), len(raw) * size_of(ghostty.Cell)) != 0 {return false}
	row_cache_draw(v, b, row, top)
	row_cache_drawn(v, row, marked)
	return true
}

// Draws the row from the cache when it was drawn with the same paints.
@(private)
row_cache_replay :: proc(
	v: ^View,
	b: ^Builder,
	id: ghostty.Render_State_Row_Id,
	top: f32,
	marked: bool,
) -> bool {
	row, found := &v.row_cache.rows[id]
	if !found || !paints_equal(row.paints[:], v.paints[:]) {return false}
	row_cache_draw(v, b, row, top)
	row_cache_drawn(v, row, marked)
	return true
}

@(private)
row_cache_draw :: proc(v: ^View, b: ^Builder, row: ^Cached_Row, top: f32) {
	row.build = v.row_cache.build
	v.row_cache.replays += 1
	// Cell heights are whole pixels, so rows move by whole pixels and glyphs stay on the pixel grid.
	_ = render.push_instances(b.list, row.rects[:], row.glyphs[:], math.round(top - row.top))
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
	if !found {
		_, value, _, err := map_entry(&c.rows, id)
		if err != nil {return}
		if len(c.spare) > 0 {value^ = pop(&c.spare)}
		row = value
	}
	clear(&row.paints)
	clear(&row.raw)
	clear(&row.rects)
	clear(&row.glyphs)
	row.top, row.build = top, c.build
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
	row_cache_drawn(v, row, marked)
}

@(private)
paints_equal :: proc(a, b: []Cell_Paint) -> bool {
	return len(a) == len(b) && mem.compare_ptrs(raw_data(a), raw_data(b), len(a) * size_of(Cell_Paint)) == 0
}
