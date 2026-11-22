package term_view

import "cosmos:caret"
import "cosmos:colour"
import "cosmos:font"
import "cosmos:glyphs"
import "aio:neovim"
import "cosmos:render"
import "core:log"
import "core:math"
import "core:time"
import "core:unicode/utf8"

// Draws a Neovim screen (WORK-542) from its grids (ext_multigrid) with the terminal's fonts, glyph cache
// and cluster fitting: the base grid, each window, then floats and messages in Neovim's order, and
// AIODev's cursor over everything. A window's text scrolls smoothly when Neovim scrolls it, a window or
// float Neovim moves slides to its new place, and floats draw their backgrounds translucent where
// Neovim's blend asks it, or AIODev's overlay opacity does for floats that take no input, over a blur of
// what shows through, and cast a shadow (WORK-547). The scratch is reused, so a build allocates only
// while something grows.
Neovim_View :: struct {
	paints:     [dynamic]Neovim_Paint,
	runes:      [dynamic]rune,
	columns:    [dynamic]int,
	shaped:     [dynamic]font.Shaped_Glyph,
	cursor:     Neovim_Cursor,
	contrast:   Contrast_Cache,
	scrolls:    [dynamic]Neovim_Scroll,
	moves:      [dynamic]Neovim_Move,
	// The screen generation the scrolls and moves last took their rows and places from.
	generation: u64,
	// When the scroll animation last advanced.
	animated:   time.Tick,
	// When the window moves last advanced.
	slid:       time.Tick,
	// The screen's size the moves last saw: a resize puts every window in its place at once.
	screen:     [2]int,
}

// AIODev's cursor, not Neovim's: Neovim decides only where it is and its shape in each mode. Its
// colours, text colour and Cursor Animation effects are the ones a terminal pane's cursor has.
Neovim_Style :: struct {
	family:           font.Family,
	// The pane has the keyboard: a solid cursor in the mode's shape rather than a hollow block.
	focused:          bool,
	// The window's blink phase shows a blinking cursor.
	cursor_visible:   bool,
	// A flight carries the cursor, or another surface has it: draw none, but still report where it is.
	cursor_hidden:    bool,
	cursor_color:     render.Color,
	cursor_text:      render.Color,
	minimum_contrast: f32,
	cursor_effects:   caret.Effects,
	// Windows scroll smoothly; off, they jump as in a terminal.
	smooth_scroll:    bool,
	// A window or float Neovim moves slides to its new place; off, it jumps there.
	animate_moves:    bool,
	// How opaque the background of a float that takes no input is, 0..1, on top of Neovim's own blend.
	overlay_opacity:  f32,
	// The shadow floats cast on what is under them; a clear colour casts none.
	float_shadow:     Neovim_Shadow,
	// How much a see-through float blurs what shows through it: the gaussian's standard deviation in
	// pixels, 0 for none.
	float_blur:       f32,
}

// In pixels: how far the shadow falls from its float, and how far its edge fades.
Neovim_Shadow :: struct {
	color:    render.Color,
	offset:   [2]f32,
	softness: f32,
}

Neovim_Frame :: struct {
	background:      render.Color,
	cursor:          Maybe(Cursor_Paint),
	cursor_blinking: bool,
}

// Changing the cursor's shape or the grid's geometry puts the cursor where it is at once, as a
// terminal's does.
@(private)
Neovim_Cursor_Key :: struct {
	shape:   caret.Shape,
	metrics: Metrics,
	origin:  [2]f32,
	grid:    [2]int,
}

@(private)
Neovim_Cursor :: struct {
	key:          Neovim_Cursor_Key,
	cell:         [2]int,
	using motion: caret.Motion,
	// The focused cursor's pose survives idle blinking, so the next move can start from it.
	present:      bool,
}

// One window's smooth scroll, as Neovide does it: a ring of twice the viewport's rows keeps the rows
// that scrolled out, and `position` is how many lines from its place the text is drawn, which a
// critically damped spring takes to zero. Row k of the viewport (negative above it, past its height
// below) is ring row (start + k) mod len.
@(private)
Neovim_Scroll :: struct {
	grid:              int,
	layout:            u64,
	scrolled:          i64,
	columns, rows:     int,
	start:             int,
	ring:              [dynamic]neovim.Cell,
	filled:            [dynamic]bool,
	position, velocity: f32,
	shown:             bool,
}

// One window's or float's place, as Neovide animates it: when Neovim moves the grid, the drawing slides
// from where it was drawn (`from`) to where Neovim has it (`to`), easing out exponentially as `t` goes
// from 0 to 1, while its size and cells are Neovim's at once. `at` is where it is drawn now. A window a
// split makes is `entering`: it slides out of the split line, drawn only inside its own place. Places
// and sizes are in grid 1 cells, x then y.
@(private)
Neovim_Move :: struct {
	grid:         int,
	kind:         neovim.Grid_Kind,
	from, at, to: [2]f32,
	size:         [2]f32,
	// The place and size before the latest screen, which tell a split's new window where it came from.
	was, was_size: [2]f32,
	t:            f32,
	shown:        bool,
	// First shown by the latest screen.
	created:      bool,
	entering:     bool,
}

@(private)
Neovim_Paint :: struct {
	foreground, background, special: render.Color,
	attributes:                      bit_set[neovim.Attribute; u16],
	glyph:                           u32,
	// The cell holds the left half of a double-width character.
	wide:                            bool,
}

// What one grid draws with: where its cells start, and how opaque its backgrounds are.
@(private)
Neovim_Grid_Draw :: struct {
	origin:   [2]f32,
	// Base and Window grids leave Neovim's background to the pane card; floats draw every cell.
	floating: bool,
	opacity:  f32,
}

neovim_view_destroy :: proc(v: ^Neovim_View) {
	delete(v.paints)
	delete(v.runes)
	delete(v.columns)
	delete(v.shaped)
	for &scroll in v.scrolls {neovim_scroll_destroy(&scroll)}
	delete(v.scrolls)
	delete(v.moves)
	v^ = {}
}

@(private)
neovim_scroll_destroy :: proc(scroll: ^Neovim_Scroll) {
	delete(scroll.ring)
	delete(scroll.filled)
}

// Advances the cursor's motion to `frame`; true when the cursor's pose changed.
neovim_cursor_animate :: proc(v: ^Neovim_View, frame: render.Frame_Time, enabled: bool) -> bool {
	return caret.motion_animate(&v.cursor.motion, frame, enabled)
}

neovim_cursor_animating :: proc(v: ^Neovim_View) -> bool {
	return v.cursor.active
}

// Forgets where the cursor was drawn, so the next build puts it where Neovim has it, with no motion.
neovim_cursor_reset :: proc(v: ^Neovim_View) {
	if v.cursor.present {v.cursor = {}}
}

// Advances every window's scroll toward its place with a critically damped spring that settles in about
// `duration`; true while any text moved. Without `enabled` scrolling lands at once.
neovim_scroll_animate :: proc(
	v: ^Neovim_View,
	frame: render.Frame_Time,
	duration: time.Duration,
	enabled: bool,
) -> bool {
	dt := f32(time.duration_seconds(frame.period))
	if v.animated != {} {
		dt = clamp(f32(time.duration_seconds(time.tick_diff(v.animated, frame.display))), 0, 0.1)
	}
	v.animated = frame.display
	length := f32(time.duration_seconds(duration))
	moved := false
	for &scroll in v.scrolls {
		if scroll.position == 0 {continue}
		moved = true
		if !enabled || frame.display == {} || length <= dt {
			scroll.position, scroll.velocity = 0, 0
			continue
		}
		// x(t) = (x0 + (v0 + ω·x0)·t)·e^(−ωt), stepped by dt; ω = 4 / length settles near `length`.
		omega := 4 / length
		decay := math.exp(-omega * dt)
		push := (scroll.velocity + omega * scroll.position) * dt
		scroll.position = (scroll.position + push) * decay
		scroll.velocity = (scroll.velocity - omega * push) * decay
		if abs(scroll.position) < 0.01 {scroll.position, scroll.velocity = 0, 0}
	}
	if !moved {v.animated = {}}
	return moved
}

neovim_scroll_animating :: proc(v: ^Neovim_View) -> bool {
	for scroll in v.scrolls {if scroll.position != 0 {return true}}
	return false
}

// Advances every window's and float's slide to `frame`, easing out exponentially over `duration` as
// Neovide does; true while any of them moved. Without `enabled` each lands at once.
neovim_moves_animate :: proc(
	v: ^Neovim_View,
	frame: render.Frame_Time,
	duration: time.Duration,
	enabled: bool,
) -> bool {
	dt := f32(time.duration_seconds(frame.period))
	if v.slid != {} {
		dt = clamp(f32(time.duration_seconds(time.tick_diff(v.slid, frame.display))), 0, 0.1)
	}
	v.slid = frame.display
	length := f32(time.duration_seconds(duration))
	moved := false
	for &move in v.moves {
		if move.t >= 1 {continue}
		moved = true
		move.t = !enabled || frame.display == {} || length <= dt ? 1 : min(1, move.t + dt / length)
		ease := move.t >= 1 ? 1 : 1 - math.pow(f32(2), -10 * move.t)
		move.at = move.from + (move.to - move.from) * ease
		if move.t >= 1 {move.entering = false}
	}
	if !moved {v.slid = {}}
	return moved
}

neovim_moves_animating :: proc(v: ^Neovim_View) -> bool {
	for move in v.moves {if move.t < 1 {return true}}
	return false
}

// Takes each window's and float's place from a new screen. A grid Neovim moved slides on from where it
// is drawn, and a window a split makes slides out of the split line. Any other grid shown for the first
// time or again, or turned from a window into a float, sits in its place at once, as does every grid when
// the screen changes size or while moves are off. The message grid never slides: it rises with each line
// of output.
@(private)
neovim_moves_sync :: proc(v: ^Neovim_View, s: ^neovim.Screen, animate: bool) {
	resized := v.screen != {s.columns, s.rows}
	v.screen = {s.columns, s.rows}
	for &move in v.moves {
		move.shown, move.created = false, false
		move.was, move.was_size = move.to, move.size
	}
	for &grid in s.grids {
		if grid.kind != .Window && grid.kind != .Float {continue}
		to := [2]f32{f32(grid.column), f32(grid.row)}
		move := neovim_move_of(v, grid.id)
		if move == nil || move.kind != grid.kind {
			if move == nil {
				if _, err := append(&v.moves, Neovim_Move{grid = grid.id}); err != nil {continue}
				move = &v.moves[len(v.moves) - 1]
			}
			move^ = {grid = grid.id, kind = grid.kind, from = to, at = to, to = to, t = 1, created = true}
		} else if move.to != to {
			move.from, move.to, move.t = move.at, to, 0
			if !animate || resized {move.from, move.at, move.t, move.entering = to, to, 1, false}
		}
		move.size = {f32(grid.columns), f32(grid.rows)}
		move.shown = true
	}
	for i := len(v.moves) - 1; i >= 0; i -= 1 {
		if !v.moves[i].shown {unordered_remove(&v.moves, i)}
	}
	if !animate || resized {return}
	for &move in v.moves {
		if !move.created || move.kind != .Window {continue}
		if offset, ok := neovim_split_entrance(v, &move); ok {
			move.from, move.at, move.t, move.entering = move.to + offset, move.to + offset, 0, true
		}
	}
}

// Where a split's new window starts, from its place: hidden just past the split line, inside the window it
// was cut from, so it slides out of the line. That window is the one shown before and still shown whose
// old place it covers most; the new window took its left or right part, or its top or bottom part. A new
// window that covers no window of the screen before, as on a new tab page, is no split.
@(private, require_results)
neovim_split_entrance :: proc(v: ^Neovim_View, window: ^Neovim_Move) -> (offset: [2]f32, ok: bool) {
	parent: ^Neovim_Move
	most: f32
	for &other in v.moves {
		if other.created || other.kind != .Window {continue}
		low := [2]f32{max(other.was.x, window.to.x), max(other.was.y, window.to.y)}
		high := [2]f32 {
			min(other.was.x + other.was_size.x, window.to.x + window.size.x),
			min(other.was.y + other.was_size.y, window.to.y + window.size.y),
		}
		if area := max(0, high.x - low.x) * max(0, high.y - low.y); area > most {parent, most = &other, area}
	}
	if parent == nil {return}
	switch {
	case window.size.x < parent.was_size.x:
		return {window.to.x > parent.was.x ? -window.size.x : window.size.x, 0}, true
	case window.size.y < parent.was_size.y:
		return {0, window.to.y > parent.was.y ? -window.size.y : window.size.y}, true
	}
	return
}

@(private)
neovim_move_of :: proc(v: ^Neovim_View, grid: int) -> ^Neovim_Move {
	for &move in v.moves {if move.grid == grid {return &move}}
	return nil
}

// Where a grid's top-left cell is drawn now. A sliding grid is drawn on whole pixels plus the fraction
// its place has, so its box drawing characters stay as sharp as at rest.
@(private)
neovim_grid_origin :: proc(
	v: ^Neovim_View,
	grid: ^neovim.Grid_View,
	origin: [2]f32,
	metrics: Metrics,
) -> [2]f32 {
	cell := [2]f32{metrics.cell_width, metrics.cell_height}
	to := [2]f32{f32(grid.column), f32(grid.row)} * cell
	move := neovim_move_of(v, grid.id)
	if move == nil || move.t >= 1 {return origin + to}
	fraction := to - {math.floor(to.x), math.floor(to.y)}
	at := move.at * cell - fraction
	return origin + {math.round(at.x), math.round(at.y)} + fraction
}

// The place a split's new window is drawn inside while it slides out of the split line.
@(private)
neovim_entering_rect :: proc(
	v: ^Neovim_View,
	grid: ^neovim.Grid_View,
	origin: [2]f32,
	metrics: Metrics,
) -> (
	rect: render.Rect,
	entering: bool,
) {
	move := neovim_move_of(v, grid.id)
	if move == nil || !move.entering || move.t >= 1 {return}
	cell := [2]f32{metrics.cell_width, metrics.cell_height}
	return {
		origin.x + f32(grid.column) * cell.x, origin.y + f32(grid.row) * cell.y, f32(grid.columns) * cell.x,
		f32(grid.rows) * cell.y,
	}, true
}

@(private)
neovim_color :: proc(value: neovim.Color) -> render.Color {
	return colour.rgba({u8(value >> 16), u8(value >> 8), u8(value)})
}

@(private)
neovim_highlight :: proc(s: ^neovim.Screen, id: u32) -> neovim.Highlight {
	if id == 0 || int(id) >= len(s.highlights) {return {}}
	return s.highlights[id]
}

// The viewport of a window or float: its rows between the top and bottom margins (a winbar, a border),
// which scroll while the margins stay.
@(private)
neovim_viewport :: proc(grid: ^neovim.Grid_View) -> (top, rows: int) {
	top = clamp(grid.margins[0], 0, grid.rows)
	rows = max(0, grid.rows - top - max(grid.margins[1], 0))
	return
}

// Takes the rows of a new screen into each window's scroll ring, turning Neovim's scroll into a distance
// the text still has to travel. A grid that was reset, resized or shown again starts at rest; so does
// every grid while smooth scrolling is off, which keeps no ring.
@(private)
neovim_scroll_sync :: proc(v: ^Neovim_View, s: ^neovim.Screen, smooth: bool) {
	for &scroll in v.scrolls {scroll.shown = false}
	for &grid in s.grids {
		if grid.kind != .Window && grid.kind != .Float {continue}
		scroll := neovim_scroll_of(v, grid.id)
		if scroll == nil {
			// A layout one behind the grid's never matches it, so the first sync fills the ring.
			fresh := Neovim_Scroll{grid = grid.id, layout = grid.layout - 1, scrolled = grid.scrolled}
			if _, err := append(&v.scrolls, fresh); err != nil {continue}
			scroll = &v.scrolls[len(v.scrolls) - 1]
		}
		scroll.shown = true
		top, rows := neovim_viewport(&grid)
		delta := int(grid.scrolled - scroll.scrolled)
		scroll.scrolled = grid.scrolled
		if !smooth || rows == 0 {
			scroll.layout, scroll.position, scroll.velocity = grid.layout - 1, 0, 0
			continue
		}
		same := scroll.layout == grid.layout && scroll.rows == rows && scroll.columns == grid.columns &&
			len(scroll.ring) == 2 * rows * grid.columns
		if !same || abs(delta) > rows {
			if !neovim_scroll_reset(scroll, grid.layout, rows, grid.columns) {continue}
			// A jump of more than a viewport animates only its last line, over a blank row.
			if same {scroll.position = delta > 0 ? -1 : 1}
		} else if delta != 0 {
			scroll.start = ((scroll.start + delta) % (2 * rows) + 2 * rows) % (2 * rows)
			scroll.position = clamp(scroll.position - f32(delta), -f32(rows), f32(rows))
		}
		for y in 0 ..< rows {
			slot := (scroll.start + y) % (2 * rows)
			row := grid.cells[(top + y) * grid.columns:][:grid.columns]
			copy(scroll.ring[slot * grid.columns:][:grid.columns], row)
			scroll.filled[slot] = true
		}
	}
	for i := len(v.scrolls) - 1; i >= 0; i -= 1 {
		if v.scrolls[i].shown {continue}
		neovim_scroll_destroy(&v.scrolls[i])
		unordered_remove(&v.scrolls, i)
	}
}

@(private, require_results)
neovim_scroll_reset :: proc(scroll: ^Neovim_Scroll, layout: u64, rows, columns: int) -> bool {
	scroll.layout, scroll.rows, scroll.columns, scroll.start = layout, rows, columns, 0
	scroll.position, scroll.velocity = 0, 0
	if resize(&scroll.ring, 2 * rows * columns) != nil || resize(&scroll.filled, 2 * rows) != nil {
		scroll.rows = 0
		return false
	}
	for &filled in scroll.filled {filled = false}
	return true
}

@(private)
neovim_scroll_of :: proc(v: ^Neovim_View, grid: int) -> ^Neovim_Scroll {
	for &scroll in v.scrolls {if scroll.grid == grid {return &scroll}}
	return nil
}

// Builds the screen at `origin`, the base grid's top-left cell, into the list's current layer, whose
// clip and radius every later layer of the screen repeats. `frame_time` is when the frame will be on
// screen, which a moving cursor is drawn for.
neovim_build :: proc(
	v: ^Neovim_View,
	client: ^neovim.Client,
	fonts: ^font.System,
	cache: ^glyphs.Cache,
	list: ^render.Draw_List,
	origin: [2]f32,
	metrics: Metrics,
	style: Neovim_Style,
	frame_time: render.Frame_Time,
) -> (
	frame: Neovim_Frame,
	result: render.Build_Status,
) {
	s := &client.screen
	frame.background = neovim_color(s.default_background)
	if list.error != .None || len(s.grids) == 0 || len(list.layers) == 0 {return}
	if v.generation != s.generation {
		neovim_scroll_sync(v, s, style.smooth_scroll)
		neovim_moves_sync(v, s, style.animate_moves)
		v.generation = s.generation
	}
	pane := list.layers[len(list.layers) - 1]
	cursor := neovim_cursor_place(v, s, origin, metrics, style, frame_time, &frame)
	b := Builder{list = list, cache = cache, fonts = fonts, metrics = metrics}
	cursor_text: [2]int
	windows_sliding := false
	for move in v.moves {windows_sliding ||= move.kind == .Window && move.t < 1}
	run_end := 0
	for &grid, index in s.grids {
		draw := Neovim_Grid_Draw {
			origin  = neovim_grid_origin(v, &grid, origin, metrics),
			opacity = neovim_grid_opacity(&grid, style),
		}
		layer := pane
		if grid.kind == .Float || grid.kind == .Message {
			draw.floating = true
			if index >= run_end {
				run_end = neovim_float_run_end(s.grids[:], index)
				if !neovim_float_backdrops(v, s, s.grids[index:run_end], list, origin, metrics, style, pane) {return}
			}
			// A float draws above everything before it: its backgrounds go over the text below it.
			if render.push_layer(list, pane.clip, pane.radius) != .None {return}
		} else if grid.kind == .Window && windows_sliding {
			// While windows slide over each other, each covers the ones before it, as in Neovide, so the
			// text of one sliding out from under another does not show through it. A split's new window
			// shows only inside its place, so it comes out of the split line.
			draw.floating = true
			if place, entering := neovim_entering_rect(v, &grid, origin, metrics); entering {
				layer = {clip = neovim_intersect(pane.clip, place)}
			}
			if render.push_layer(list, layer.clip, layer.radius) != .None {return}
		}
		// A moving cursor's smear goes over its own grid's backgrounds and under its text.
		body: Maybe(Neovim_Cursor_Body)
		if grid.id == s.cursor_grid && cursor.moving {body = Neovim_Cursor_Body{cursor.paint, style.cursor_effects}}
		start := len(list.glyphs)
		result = neovim_grid_draw(v, &b, client, s, &grid, draw, style.family, layer, body)
		if result != .Ok || list.error != .None {return}
		if grid.id == s.cursor_grid {cursor_text = {start, len(list.glyphs)}}
	}
	neovim_cursor_draw(v, list, cursor, style, pane, cursor_text)
	return
}

// How opaque a grid's backgrounds are on top of Neovim's own blend: a float that takes no input takes the
// overlay opacity.
@(private)
neovim_grid_opacity :: proc(grid: ^neovim.Grid_View, style: Neovim_Style) -> f32 {
	if grid.kind == .Float && !grid.focusable {return clamp(style.overlay_opacity, 0, 1)}
	return 1
}

// The end of the run of floats from `first` that share its zindex, as Neovim layers them; a message grid
// is a run of its own.
@(private)
neovim_float_run_end :: proc(grids: []neovim.Grid_View, first: int) -> int {
	end := first + 1
	if grids[first].kind != .Float {return end}
	for end < len(grids) && grids[end].kind == .Float && grids[end].zindex == grids[first].zindex {end += 1}
	return end
}

// Where a grid is drawn this frame, a slide included.
@(private)
neovim_grid_rect :: proc(
	v: ^Neovim_View,
	grid: ^neovim.Grid_View,
	origin: [2]f32,
	metrics: Metrics,
) -> render.Rect {
	at := neovim_grid_origin(v, grid, origin, metrics)
	return {at.x, at.y, f32(grid.columns) * metrics.cell_width, f32(grid.rows) * metrics.cell_height}
}

// Whether any of a float's backgrounds lets what is under it show through.
@(private)
neovim_see_through :: proc(s: ^neovim.Screen, grid: ^neovim.Grid_View, opacity: f32) -> bool {
	if opacity < 1 {return true}
	for cell in grid.cells[:grid.rows * grid.columns] {
		if neovim_highlight(s, cell.highlight).blend > 0 {return true}
	}
	return false
}

// What a run of floats draws over before any of them draws: a blur under each see-through float, of only
// what is below the run, then the run's shadows, each cut out under its own float and none drawn over
// another float of the run. False when the list has no room.
@(private, require_results)
neovim_float_backdrops :: proc(
	v: ^Neovim_View,
	s: ^neovim.Screen,
	run: []neovim.Grid_View,
	list: ^render.Draw_List,
	origin: [2]f32,
	metrics: Metrics,
	style: Neovim_Style,
	pane: render.Layer,
) -> bool {
	if style.float_blur > 0 {
		for &grid in run {
			if !neovim_see_through(s, &grid, neovim_grid_opacity(&grid, style)) {continue}
			area := neovim_intersect(pane.clip, neovim_grid_rect(v, &grid, origin, metrics))
			if area.width <= 0 || area.height <= 0 {continue}
			if render.push_backdrop_blur(list, area, style.float_blur) != .None {return false}
		}
	}
	shadow := style.float_shadow
	if shadow.color.a <= 0 || run[0].kind != .Float {return true}
	if render.push_layer(list, pane.clip, pane.radius) != .None {return false}
	for &grid in run {
		r := neovim_grid_rect(v, &grid, origin, metrics)
		caster := render.Rect_Instance {
			rect     = {r.x + shadow.offset.x, r.y + shadow.offset.y, r.width, r.height},
			color    = shadow.color,
			softness = shadow.softness,
			fill     = render.RECT_FILL_SHADOW,
			sheen    = {-shadow.offset.x, -shadow.offset.y, r.width, r.height},
		}
		if render.push_rect(list, caster) != .None {return false}
	}
	return true
}

// Where the cursor is drawn this frame and what it looks like; `present` is false while it is off its
// grid, busy or on a grid not shown.
@(private)
Neovim_Cursor_Placed :: struct {
	paint:            Cursor_Paint,
	present, moving:  bool,
	shown:            bool,
}

@(private)
Neovim_Cursor_Body :: struct {
	paint:   Cursor_Paint,
	effects: caret.Effects,
}

@(private)
neovim_cursor_place :: proc(
	v: ^Neovim_View,
	s: ^neovim.Screen,
	origin: [2]f32,
	metrics: Metrics,
	style: Neovim_Style,
	frame_time: render.Frame_Time,
	frame: ^Neovim_Frame,
) -> (placed: Neovim_Cursor_Placed) {
	grid: ^neovim.Grid_View
	for &candidate in s.grids {if candidate.id == s.cursor_grid {grid = &candidate}}
	row, column := s.cursor_row, s.cursor_column
	if s.busy || grid == nil || row < 0 || row >= grid.rows || column < 0 || column >= grid.columns {
		neovim_cursor_reset(v)
		return
	}
	cell := neovim_cursor_cell(v, grid, row, column, origin, metrics)
	placed.paint, placed.moving = neovim_cursor_begin(v, s, grid, cell, style, metrics, origin, frame_time)
	placed.present = true
	blinking := s.mode.blink_on > 0 && s.mode.blink_off > 0
	frame.cursor_blinking = blinking && style.focused
	frame.cursor = placed.paint
	placed.shown = !style.cursor_hidden && (placed.moving || !style.focused || !blinking || style.cursor_visible)
	return
}

// Draws one grid. A window whose text is still travelling draws its viewport from its scroll ring, offset
// and clipped to the viewport, and its margins in place; the grid after it starts a layer of its own.
@(private, require_results)
neovim_grid_draw :: proc(
	v: ^Neovim_View,
	b: ^Builder,
	client: ^neovim.Client,
	s: ^neovim.Screen,
	grid: ^neovim.Grid_View,
	draw: Neovim_Grid_Draw,
	family: font.Family,
	pane: render.Layer,
	body: Maybe(Neovim_Cursor_Body),
) -> render.Build_Status {
	if reserve(&v.paints, grid.columns) != nil {
		b.list.error = .Out_Of_Memory
		return .Ok
	}
	m := b.metrics
	b.origin = draw.origin
	scroll := neovim_scroll_of(v, grid.id)
	top, rows := neovim_viewport(grid)
	moving := scroll != nil && scroll.position != 0 && scroll.rows == rows && scroll.columns == grid.columns
	for y in 0 ..< grid.rows {
		if moving && y >= top && y < top + rows {continue}
		cells := grid.cells[y * grid.columns:][:grid.columns]
		row_top := draw.origin.y + f32(y) * m.cell_height
		base_row := grid.kind == .Base ? y : -1
		result := neovim_row_draw(v, b, client, s, cells, draw, family, row_top, base_row)
		if result != .Ok {return result}
	}
	if moving {
		viewport := render.Rect {
			draw.origin.x, draw.origin.y + f32(top) * m.cell_height, f32(grid.columns) * m.cell_width,
			f32(rows) * m.cell_height,
		}
		if render.push_layer(b.list, neovim_intersect(pane.clip, viewport), 0) != .None {return .Ok}
		first := int(math.floor(scroll.position))
		for k in first ..= first + rows {
			if k < -rows || k >= 2 * rows {continue}
			slot := ((scroll.start + k) % (2 * rows) + 2 * rows) % (2 * rows)
			if !scroll.filled[slot] {continue}
			cells := scroll.ring[slot * grid.columns:][:grid.columns]
			row_top := viewport.y + math.round((f32(k) - scroll.position) * m.cell_height)
			if result := neovim_row_draw(v, b, client, s, cells, draw, family, row_top); result != .Ok {
				return result
			}
		}
	}
	if smear, ok := body.?; ok {
		corners := caret.motion_corners(&v.cursor.motion)
		caret.paint_body_draw(b.list, smear.paint, corners, smear.effects, v.cursor.progress)
	}
	if moving {_ = render.push_layer(b.list, pane.clip, pane.radius)}
	return .Ok
}

@(private)
neovim_intersect :: proc(a, b: render.Rect) -> render.Rect {
	left, top := max(a.x, b.x), max(a.y, b.y)
	right, bottom := min(a.x + a.width, b.x + b.width), min(a.y + a.height, b.y + b.height)
	return {left, top, max(0, right - left), max(0, bottom - top)}
}

// Draws one row of cells whose top edge is at `top`: backgrounds, decorations, then text. Row `base_row`
// of the base grid leaves out the cells a window covers.
@(private, require_results)
neovim_row_draw :: proc(
	v: ^Neovim_View,
	b: ^Builder,
	client: ^neovim.Client,
	s: ^neovim.Screen,
	cells: []neovim.Cell,
	draw: Neovim_Grid_Draw,
	family: font.Family,
	top: f32,
	base_row := -1,
) -> render.Build_Status {
	neovim_row_paints(v, s, cells)
	if base_row >= 0 {neovim_row_uncover(v, s, base_row)}
	neovim_row_backgrounds(v, b, neovim_color(s.default_background), top, draw)
	for p, x in v.paints {
		if result := neovim_decorate(b, p, draw.origin.x + f32(x) * b.metrics.cell_width, top); result != .Ok {
			return result
		}
	}
	return neovim_row_text(v, b, client, family, top)
}

// Neovim never clears the base grid under a window, so the separators a split drag leaves behind stay
// there; only the windows' own cells are current. Base row y's paints become Neovim's background where a
// window covers them.
@(private)
neovim_row_uncover :: proc(v: ^Neovim_View, s: ^neovim.Screen, y: int) {
	blank := Neovim_Paint {
		foreground = neovim_color(s.default_foreground),
		background = neovim_color(s.default_background),
	}
	for grid in s.grids {
		if grid.kind != .Window || y < grid.row || y >= grid.row + grid.rows {continue}
		first := clamp(grid.column, 0, len(v.paints))
		last := clamp(grid.column + grid.columns, 0, len(v.paints))
		for &p in v.paints[first:last] {p = blank}
	}
}

// Draws the cursor over every grid: a block draws the text of its own grid's cell again in the cursor
// text colour, clipped to itself, so a float over the cursor's window does not hide either.
@(private)
neovim_cursor_draw :: proc(
	v: ^Neovim_View,
	list: ^render.Draw_List,
	placed: Neovim_Cursor_Placed,
	style: Neovim_Style,
	pane: render.Layer,
	text: [2]int,
) {
	defer if v.cursor.present && list.error == .None {caret.motion_drawn(&v.cursor.motion)}
	if !placed.present || !placed.shown || list.error != .None {return}
	if render.push_layer(list, pane.clip, pane.radius) != .None {return}
	paint := placed.paint
	if !style.focused || paint.shape != .Block {
		cursor_outline(list, paint, !style.focused)
		return
	}
	_ = render.push_rect(list, {rect = paint.head, color = paint.color})
	ink := neovim_cursor_text(v, paint)
	for i in text[0] ..< text[1] {
		cursor_replay_glyph(list, list.glyphs[i], {}, paint.head, ink)
		if list.error != .None {break}
	}
}

// The cursor's cell where its grid draws it now, following the grid's scroll and slide and kept inside
// its viewport while the text travels, and inside its place while a split's new window comes out.
@(private)
neovim_cursor_cell :: proc(
	v: ^Neovim_View,
	grid: ^neovim.Grid_View,
	row, column: int,
	origin: [2]f32,
	metrics: Metrics,
) -> render.Rect {
	wide := column + 1 < grid.columns && grid.cells[row * grid.columns + column + 1].glyph == 0
	y := f32(row)
	top, rows := neovim_viewport(grid)
	if scroll := neovim_scroll_of(v, grid.id); scroll != nil && row >= top && row < top + rows {
		y = clamp(y - scroll.position, f32(top), f32(top + rows - 1))
	}
	// How far the grid's slide still has it from its place; nothing at rest.
	slide := neovim_grid_origin(v, grid, origin, metrics) -
		(origin + {f32(grid.column) * metrics.cell_width, f32(grid.row) * metrics.cell_height})
	cell := render.Rect {
		slide.x + origin.x + f32(grid.column + column) * metrics.cell_width,
		slide.y + origin.y + math.round((f32(grid.row) + y) * metrics.cell_height),
		metrics.cell_width * (wide ? 2 : 1),
		metrics.cell_height,
	}
	if place, entering := neovim_entering_rect(v, grid, origin, metrics); entering {
		cell.x = clamp(cell.x, place.x, place.x + place.width - cell.width)
		cell.y = clamp(cell.y, place.y, place.y + place.height - cell.height)
	}
	return cell
}

// The cursor in its mode's shape and AIODev's colours, and whether it is moving to `cell`: with Cursor
// Animation on, a focused cursor glides, smears or trails to each new cell. Text scrolling under it
// carries it along without a motion of its own.
@(private)
neovim_cursor_begin :: proc(
	v: ^Neovim_View,
	s: ^neovim.Screen,
	grid: ^neovim.Grid_View,
	cell: render.Rect,
	style: Neovim_Style,
	metrics: Metrics,
	origin: [2]f32,
	frame_time: render.Frame_Time,
) -> (
	paint: Cursor_Paint,
	moving: bool,
) {
	paint = {
		head = cell, tail = cell, target = cell, shape = .Block,
		stroke = max(1, metrics.underline_thickness), color = style.cursor_color,
		text_color = style.cursor_text, minimum_contrast = style.minimum_contrast,
	}
	share := f32(s.mode.percentage > 0 ? s.mode.percentage : 25) / 100
	#partial switch s.mode.shape {
	case .Vertical:
		paint.shape, paint.stroke = .Bar, max(1, math.round(cell.width * share / 2))
	case .Horizontal:
		paint.shape, paint.stroke = .Underline, max(1, math.round(cell.height * share / 2))
	}
	e := style.cursor_effects
	if !style.focused || style.cursor_hidden || e.preset == .Off {
		neovim_cursor_reset(v)
		return
	}
	c := &v.cursor
	key := Neovim_Cursor_Key{paint.shape, metrics, origin, {s.columns, s.rows}}
	at := [2]int{grid.column + s.cursor_column, grid.row + s.cursor_row}
	if !c.present || c.key != key || c.effects != e || !caret.effects_active(e) || frame_time.display == {} {
		c^ = {key = key, cell = at, present = true}
		c.motion = {effects = e, target = cell, head = cell, tail = cell}
		return
	}
	if at != c.cell {
		c.cell = at
		caret.motion_retarget(&c.motion, cell)
	} else if !c.active {
		c.target, c.head, c.tail = cell, cell, cell
	}
	paint.head, paint.tail = c.head, c.tail
	if !c.active {return}
	c.target = cell
	t := caret.motion_progress(&c.motion, frame_time)
	if t >= 1 {
		c.active = false
		caret.motion_place(&c.motion, 1)
	} else {
		moving = true
		caret.motion_place(&c.motion, t)
	}
	paint.head, paint.tail = c.head, c.tail
	return
}

// The cursor's text colour, lifted to the minimum contrast against the cursor as a terminal's is.
@(private)
neovim_cursor_text :: proc(v: ^Neovim_View, paint: Cursor_Paint) -> render.Color {
	if paint.minimum_contrast <= 1 {return paint.text_color}
	return minimum_contrast_cached(&v.contrast, paint.text_color, paint.color, paint.minimum_contrast)
}

// Fills v.paints, whose capacity holds the row, with the cells' colours, attributes and glyphs. An
// underline without a special colour takes the text's.
@(private)
neovim_row_paints :: proc(v: ^Neovim_View, s: ^neovim.Screen, cells: []neovim.Cell) {
	foreground := neovim_color(s.default_foreground)
	background := neovim_color(s.default_background)
	clear(&v.paints)
	for cell, x in cells {
		h := neovim_highlight(s, cell.highlight)
		p := Neovim_Paint {
			foreground = foreground,
			background = background,
			attributes = h.attributes,
			glyph      = cell.glyph,
			wide       = cell.glyph != 0 && x + 1 < len(cells) && cells[x + 1].glyph == 0,
		}
		if fg, ok := h.foreground.?; ok {p.foreground = neovim_color(fg)}
		if bg, ok := h.background.?; ok {p.background = neovim_color(bg)}
		if .Reverse in h.attributes {p.foreground, p.background = p.background, p.foreground}
		p.special = p.foreground
		if sp, ok := h.special.?; ok {p.special = neovim_color(sp)}
		// Neovim's blend (winblend, pumblend, a highlight's blend) makes only the background see-through.
		p.background.a = 1 - f32(min(h.blend, 100)) / 100
		_, _ = append(&v.paints, p)
	}
}

// Fills runs of one background. A base or window grid leaves Neovim's own background to the pane card;
// a float fills every cell, at its opacity.
@(private)
neovim_row_backgrounds :: proc(
	v: ^Neovim_View,
	b: ^Builder,
	base: render.Color,
	top: f32,
	draw: Neovim_Grid_Draw,
) {
	m := b.metrics
	start := 0
	for x in 1 ..= len(v.paints) {
		if x < len(v.paints) && v.paints[x].background == v.paints[start].background {continue}
		color := v.paints[start].background
		if draw.floating || color != base {
			color.a *= draw.opacity
			left := draw.origin.x + f32(start) * m.cell_width
			rect(b, {left, top, f32(x - start) * m.cell_width, m.cell_height}, color)
		}
		start = x
	}
}

@(private)
neovim_decorate :: proc(b: ^Builder, p: Neovim_Paint, left, top: f32) -> render.Build_Status {
	m := b.metrics
	baseline := top + m.baseline
	if .Strikethrough in p.attributes {
		rect(b, {left, baseline - m.strikethrough_offset, m.cell_width, m.strikethrough_thickness}, p.foreground)
	}
	t := m.underline_thickness
	line := baseline + m.underline_offset
	switch {
	case .Underline in p.attributes:
		rect(b, {left, line, m.cell_width, t}, p.special)
	case .Underdouble in p.attributes:
		rect(b, {left, line - t, m.cell_width, t}, p.special)
		rect(b, {left, line + t, m.cell_width, t}, p.special)
	case p.attributes & {.Undercurl, .Underdotted, .Underdashed} != {}:
		sprite: glyphs.Sprite = .Dashed_Underline
		if .Undercurl in p.attributes {
			sprite = .Curly_Underline
		} else if .Underdotted in p.attributes {
			sprite = .Dotted_Underline
		}
		entry, result := glyphs.sprite(b.cache, sprite, m.cell_width, t)
		if result != .Ok {return result}
		place(b, entry, {left, line + t / 2}, p.special)
	}
	return .Ok
}

@(private)
neovim_face :: proc(p: Neovim_Paint) -> font.Style {
	bold, italic := .Bold in p.attributes, .Italic in p.attributes
	if bold && italic {return .Bold_Italic}
	if bold {return .Bold}
	if italic {return .Italic}
	return .Regular
}

// Shapes the row's text in runs of one face, so programming ligatures form as they do in a terminal.
// The right half of a double-width character holds no glyph and leaves the run whole.
@(private, require_results)
neovim_row_text :: proc(
	v: ^Neovim_View,
	b: ^Builder,
	client: ^neovim.Client,
	family: font.Family,
	top: f32,
) -> render.Build_Status {
	clear(&v.runes)
	clear(&v.columns)
	face: font.Style
	for p, x in v.paints {
		if p.glyph == 0 {continue}
		next_face := neovim_face(p)
		if next_face != face {
			if result := neovim_run(v, b, family, face, top); result != .Ok {return result}
		}
		appended := false
		if p.glyph & neovim.GLYPH_CLUSTER == 0 {
			appended = neovim_append_rune(v, rune(p.glyph), x)
		} else {
			appended = neovim_append_cluster(v, neovim.cluster(client, p.glyph), x)
		}
		if !appended {
			b.list.error = .Out_Of_Memory
			return .Ok
		}
		face = next_face
	}
	return neovim_run(v, b, family, face, top)
}

@(private, require_results)
neovim_append_rune :: proc(v: ^Neovim_View, r: rune, x: int) -> bool {
	_, rune_error := append(&v.runes, r)
	_, column_error := append(&v.columns, x)
	return rune_error == nil && column_error == nil
}

// The runes of a cluster, each standing in column x.
@(private, require_results)
neovim_append_cluster :: proc(v: ^Neovim_View, text: string, x: int) -> bool {
	for r in text {
		if r == utf8.RUNE_ERROR {continue}
		if !neovim_append_rune(v, r, x) {return false}
	}
	return true
}

// Draws the pending run, then empties it. Text is opaque even over a see-through background.
@(private, require_results)
neovim_run :: proc(
	v: ^Neovim_View,
	b: ^Builder,
	family: font.Family,
	face: font.Style,
	top: f32,
) -> render.Build_Status {
	defer {
		clear(&v.runes)
		clear(&v.columns)
	}
	if len(v.runes) == 0 {return .Ok}
	clear(&v.shaped)
	m := b.metrics
	if err := font.shape(b.fonts, family, face, v.runes[:], m.size_px, &v.shaped, v.columns[:]); err != .None {
		log.errorf("term_view: shaping Neovim text failed: %v", err)
		for r, i in v.runes {
			g, found := font.glyph_lookup(b.fonts, family, face, r)
			if !found {continue}
			entry, result := glyphs.glyph(b.cache, g, m.size_px)
			if result != .Ok {return result}
			x := v.columns[i]
			place(b, entry, {b.origin.x + f32(x) * m.cell_width, top + m.baseline}, neovim_ink(v.paints[x]))
		}
		return .Ok
	}
	for start := 0; start < len(v.shaped); {
		cluster := v.shaped[start].cluster
		end := start + 1
		advance := v.shaped[start].advance
		for end < len(v.shaped) && v.shaped[end].cluster == cluster {
			advance += v.shaped[end].advance
			end += 1
		}
		last := max(cluster, (end < len(v.shaped) ? v.shaped[end].cluster : len(v.runes)) - 1)
		x := v.columns[cluster]
		p := v.paints[x]
		span := f32(v.columns[last] - x + (v.paints[v.columns[last]].wide ? 2 : 1)) * m.cell_width
		// D-042, as term_view draws: a cluster wider than its cells shrinks to fit around their centre.
		scale: f32 = 1
		if advance > span + 0.5 {scale = span / advance}
		left := b.origin.x + f32(x) * m.cell_width
		if scale < 1 || p.wide {left += (span - advance * scale) / 2}
		baseline := top + m.cell_height / 2 + (m.baseline - m.cell_height / 2) * scale
		pen: f32
		for g in v.shaped[start:end] {
			entry, result := glyphs.glyph(b.cache, g.glyph, m.size_px * scale, p.wide)
			if result != .Ok {return result}
			place(b, entry, {left + pen + g.offset.x * scale, baseline - g.offset.y * scale}, neovim_ink(p))
			pen += g.advance * scale
		}
		start = end
	}
	return .Ok
}

@(private)
neovim_ink :: proc(p: Neovim_Paint) -> render.Color {
	ink := p.foreground
	ink.a = 1
	return ink
}
